import CloudKit
import Foundation
import os.log

/// Describes sync events for observer callbacks.
public enum SyncEvent: Sendable {
    case syncStarted
    case syncCompleted(recordCount: Int, deleteCount: Int)
    case syncFailed(error: Error)
    case recordSaved(recordName: String)
    case recordDeleted(recordName: String)
}

/// CloudKit sync coordinator — handles sync operations with conflict resolution and retry.
@MainActor
public final class CloudKitSyncCoordinator: ObservableObject {

    // MARK: - Singleton

    public static let shared = CloudKitSyncCoordinator()

    // MARK: - Constants

    /// CloudKit maximum records per single modify operation.
    static let cloudKitBatchLimit = 400
    /// Maximum retries when server change token expires during fetch.
    static let maxTokenRefreshDepth = 2

    // MARK: - Configuration

    public var maxRetryCount: Int = 3 {
        didSet { retryPolicy = CloudKitSyncRetryPolicy(maxRetryCount: maxRetryCount, baseDelay: retryBaseDelay) }
    }
    public var retryBaseDelay: TimeInterval = 1.0 {
        didSet { retryPolicy = CloudKitSyncRetryPolicy(maxRetryCount: maxRetryCount, baseDelay: retryBaseDelay) }
    }

    // MARK: - State

    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncError: Error?
    @Published public private(set) var lastSyncDate: Date?

    let manager = CloudKitManager.shared
    let localStore = CloudKitLocalStore.shared
    let logger = Logger(subsystem: "SwiftCloudKit", category: "Sync")
    var retryPolicy = CloudKitSyncRetryPolicy(maxRetryCount: 3, baseDelay: 1.0)

    var recordHandlers: [String: (CKRecord) -> Void] = [:]
    var deleteHandlers: [String: (CKRecord.ID) -> Void] = [:]
    var deletePrefixMap: [(prefix: String, recordType: String)] = []

    /// Optional observer for sync lifecycle events.
    public var onSyncEvent: ((SyncEvent) -> Void)?

    /// Optional custom conflict resolver. When set, this is called instead of
    /// the default merge strategy. Return the resolved CKRecord to save.
    public var conflictResolver: ((CKRecord, CKRecord) -> CKRecord)?

    private init() {}

    // MARK: - Handler Registration

    public func registerRecordHandler(
        recordType: String,
        namePrefix: String? = nil,
        onUpdate: @escaping (CKRecord) -> Void,
        onDelete: @escaping (CKRecord.ID) -> Void
    ) {
        let prefix = namePrefix ?? recordType.lowercased()
        deletePrefixMap.removeAll { $0.recordType == recordType }

        recordHandlers[recordType] = onUpdate
        deleteHandlers[recordType] = onDelete
        deletePrefixMap.append((prefix: prefix, recordType: recordType))
        deletePrefixMap.sort { $0.prefix.count > $1.prefix.count }
    }

    public func unregisterRecordHandler(recordType: String) {
        recordHandlers.removeValue(forKey: recordType)
        deleteHandlers.removeValue(forKey: recordType)
        deletePrefixMap.removeAll { $0.recordType == recordType }
    }

    public func unregisterAllHandlers() {
        recordHandlers.removeAll()
        deleteHandlers.removeAll()
        deletePrefixMap.removeAll()
    }

    // MARK: - Save

    public func saveRecord(_ record: CKRecord) async throws {
        guard manager.isCloudAvailable else { throw CloudKitError.notConfigured }
        beginSync()

        do {
            let database = try manager.privateDB
            _ = try await database.save(record)
            localStore.cacheRecord(record)
            endSync(recordName: record.recordID.recordName)
        } catch let error as CKError {
            try await handleSaveError(error, record: record)
        } catch {
            failSync(error)
            throw error
        }
    }

    // MARK: - Delete

    public func deleteRecord(_ recordID: CKRecord.ID) async throws {
        guard manager.isCloudAvailable else { throw CloudKitError.notConfigured }
        beginSync()

        do {
            let database = try manager.privateDB
            _ = try await database.deleteRecord(withID: recordID)
            completeDelete(recordID)
        } catch let error as CKError where error.code == .unknownItem {
            localStore.removeCachedRecord(recordName: recordID.recordName)
            isSyncing = false
        } catch let error as CKError where retryPolicy.isRetryable(error) {
            try await retryPolicy.executeWithRetry { [self] in
                let database = try manager.privateDB
                _ = try await database.deleteRecord(withID: recordID)
            }
            completeDelete(recordID)
        } catch {
            failSync(error)
            throw error
        }
    }

    private func completeDelete(_ recordID: CKRecord.ID) {
        localStore.removeCachedRecord(recordName: recordID.recordName)
        lastSyncDate = Date()
        isSyncing = false
        onSyncEvent?(.recordDeleted(recordName: recordID.recordName))
    }

    // MARK: - Fetch

    public func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord {
        guard manager.isCloudAvailable else { throw CloudKitError.notConfigured }
        beginSync()

        do {
            let database = try manager.privateDB
            let record = try await database.record(for: recordID)
            localStore.cacheRecord(record)
            lastSyncDate = Date()
            isSyncing = false
            return record
        } catch {
            failSync(error)
            throw error
        }
    }

    // MARK: - Query

    /// Query records by type with optional predicate, sort descriptors, and result limit.
    /// Supports cursor-based pagination for large result sets.
    public func queryRecords(
        recordType: String,
        predicate: NSPredicate = NSPredicate(value: true),
        sortDescriptors: [NSSortDescriptor]? = nil,
        resultsLimit: Int = 100
    ) async throws -> [CKRecord] {
        guard manager.isCloudAvailable else { throw CloudKitError.notConfigured }
        beginSync()

        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors
        let database = try manager.privateDB

        var allRecords: [CKRecord] = []
        let (firstResults, cursor) = try await database.records(
            matching: query, resultsLimit: resultsLimit
        )
        for (_, result) in firstResults {
            if case .success(let record) = result { allRecords.append(record) }
        }

        var nextCursor = cursor
        while let current = nextCursor {
            let (page, pageCursor) = try await database.records(
                continuingMatchFrom: current, resultsLimit: resultsLimit
            )
            for (_, result) in page {
                if case .success(let record) = result { allRecords.append(record) }
            }
            nextCursor = pageCursor
        }

        for record in allRecords { localStore.cacheRecord(record) }
        lastSyncDate = Date()
        isSyncing = false
        logger.info("Query returned \(allRecords.count) records")
        return allRecords
    }

    // MARK: - Remote Changes

    public func fetchRemoteChanges() async {
        await fetchRemoteChanges(depth: 0)
    }

    func fetchRemoteChanges(depth: Int) async {
        guard manager.isCloudAvailable, !isSyncing else { return }
        beginSync()
        onSyncEvent?(.syncStarted)

        do {
            let database = try manager.privateDB
            let zone = try manager.zoneID

            let fetchResult = try await performZoneFetch(
                database: database,
                zone: zone,
                previousToken: localStore.serverChangeToken
            )

            processFetchedRecords(fetchResult)

            lastSyncDate = Date()
            isSyncing = false
            let modCount = fetchResult.modifiedRecords.count
            let delCount = fetchResult.deletedRecordIDs.count
            onSyncEvent?(.syncCompleted(recordCount: modCount, deleteCount: delCount))
            logger.info("Fetched \(modCount) modified, \(delCount) deleted")
        } catch let error as CKError where error.code == .changeTokenExpired {
            isSyncing = false
            guard depth < Self.maxTokenRefreshDepth else {
                lastSyncError = CloudKitError.syncFailed("Token expired repeatedly")
                logger.error("Token expired \(depth + 1) times")
                return
            }
            logger.warning("Token expired, re-fetching (attempt \(depth + 1))")
            localStore.serverChangeToken = nil
            await fetchRemoteChanges(depth: depth + 1)
        } catch {
            failSync(error)
            onSyncEvent?(.syncFailed(error: error))
        }
    }

    func dispatchDeletedRecord(_ recordID: CKRecord.ID) {
        let name = recordID.recordName
        for entry in deletePrefixMap where name.hasPrefix(entry.prefix + "_") {
            deleteHandlers[entry.recordType]?(recordID)
            break
        }
    }

    // MARK: - Conflict Resolution

    private func resolveConflict(local: CKRecord, server: CKRecord) async throws {
        let resolved: CKRecord

        if let resolver = conflictResolver {
            resolved = resolver(local, server)
        } else {
            resolved = defaultMerge(local: local, server: server)
        }

        resolved["updated_at"] = Date()

        let database = try manager.privateDB
        _ = try await database.save(resolved)
        localStore.cacheRecord(resolved)
        lastSyncDate = Date()
        logger.info("Conflict resolved for \(local.recordID.recordName)")
    }

    private func defaultMerge(local: CKRecord, server: CKRecord) -> CKRecord {
        for key in local.allKeys() {
            if let localDate = local[key] as? Date,
               let serverDate = server[key] as? Date {
                server[key] = localDate > serverDate ? localDate : serverDate
            } else if let value = local[key] {
                server[key] = value
            }
        }
        return server
    }

    // MARK: - Sync State Helpers

    func beginSync() {
        isSyncing = true
        lastSyncError = nil
    }

    func endSync(recordName: String) {
        lastSyncDate = Date()
        isSyncing = false
        onSyncEvent?(.recordSaved(recordName: recordName))
    }

    func completeSync() {
        lastSyncDate = Date()
        isSyncing = false
    }

    func failSync(_ error: Error) {
        lastSyncError = error
        isSyncing = false
        logger.error("Sync failed: \(error.localizedDescription)")
    }

    // MARK: - Save Error Handling

    private func handleSaveError(_ error: CKError, record: CKRecord) async throws {
        if error.code == .serverRecordChanged, let server = error.serverRecord {
            try await resolveConflict(local: record, server: server)
            isSyncing = false
        } else if error.code == .unknownItem {
            let database = try manager.privateDB
            _ = try await database.save(record)
            localStore.cacheRecord(record)
            endSync(recordName: record.recordID.recordName)
        } else if error.code == .quotaExceeded {
            isSyncing = false
            lastSyncError = CloudKitError.quotaExceeded
            throw CloudKitError.quotaExceeded
        } else if retryPolicy.isRetryable(error) {
            try await retryPolicy.executeWithRetry { [self] in
                let database = try manager.privateDB
                _ = try await database.save(record)
                localStore.cacheRecord(record)
                lastSyncDate = Date()
                onSyncEvent?(.recordSaved(recordName: record.recordID.recordName))
            }
            isSyncing = false
        } else {
            failSync(error)
            throw error
        }
    }
}
