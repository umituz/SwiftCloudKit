//
//  CloudKitSyncCoordinator.swift
//  SwiftCloudKit
//
//  Handles conflict resolution, remote change fetching, and batch operations.
//

import CloudKit
import Foundation

/// CloudKit sync coordinator - handles conflict resolution, remote fetching, and change tracking.
@MainActor
public final class CloudKitSyncCoordinator: ObservableObject {

    // MARK: - Singleton

    public static let shared = CloudKitSyncCoordinator()

    // MARK: - Properties

    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncError: Error?
    @Published public private(set) var lastSyncDate: Date?

    private let cloudKit = CloudKitManager.shared
    private let localStore = CloudKitLocalStore.shared

    // Record handlers keyed by record type
    private var recordHandlers: [String: (CKRecord) -> Void] = [:]
    private var deleteHandlers: [String: (CKRecord.ID) -> Void] = [:]
    // Maps record name prefix → record type for reliable delete dispatch
    private var deletePrefixMap: [String: String] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Handler Registration

    /// Register handler for incoming remote record changes.
    /// - Parameters:
    ///   - recordType: The CloudKit record type (e.g. "UserProfile", "Prediction")
    ///   - namePrefix: The prefix used in record IDs for this type (e.g. "userprofile", "prediction")
    ///   - onUpdate: Called when a record of this type is modified remotely
    ///   - onDelete: Called when a record of this type is deleted remotely
    public func registerRecordHandler(
        recordType: String,
        namePrefix: String? = nil,
        onUpdate: @escaping (CKRecord) -> Void,
        onDelete: @escaping (CKRecord.ID) -> Void
    ) {
        recordHandlers[recordType] = onUpdate
        deleteHandlers[recordType] = onDelete
        // Use explicit prefix or lowercase of record type
        deletePrefixMap[namePrefix ?? recordType.lowercased()] = recordType
    }

    // MARK: - Save / Update / Delete

    /// Save a record with conflict resolution (handles both create and update).
    public func saveRecord(_ record: CKRecord) async throws {
        guard cloudKit.isCloudAvailable else { return }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            _ = try await cloudKit.privateDB.save(record)
            localStore.cacheRecord(record)
            lastSyncDate = Date()
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let serverRecord = error.serverRecord else {
                lastSyncError = error
                throw error
            }
            try await resolveConflictAndSave(localRecord: record, serverRecord: serverRecord)
        } catch let error as CKError where error.code == .unknownItem {
            // Record was deleted on server - nothing to do
        } catch {
            lastSyncError = error
            throw error
        }
    }

    /// Delete a record by ID.
    public func deleteRecord(_ recordID: CKRecord.ID) async throws {
        guard cloudKit.isCloudAvailable else { return }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            _ = try await cloudKit.privateDB.deleteRecord(withID: recordID)
            localStore.removeCachedRecord(recordName: recordID.recordName)
            lastSyncDate = Date()
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted - clean local cache
            localStore.removeCachedRecord(recordName: recordID.recordName)
        } catch {
            lastSyncError = error
            throw error
        }
    }

    // MARK: - Fetch

    /// Fetch a single record by its ID.
    public func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord {
        guard cloudKit.isCloudAvailable else {
            throw CloudKitError.notConfigured
        }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            let record = try await cloudKit.privateDB.record(for: recordID)
            localStore.cacheRecord(record)
            lastSyncDate = Date()
            return record
        } catch {
            lastSyncError = error
            throw error
        }
    }

    // MARK: - Remote Change Fetching

    /// Fetch remote changes using CKFetchRecordZoneChangesOperation with change token tracking.
    public func fetchRemoteChanges() async {
        guard cloudKit.isCloudAvailable, !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            let previousToken = localStore.serverChangeToken
            var modifiedRecords: [CKRecord] = []
            var deletedRecordIDs: [CKRecord.ID] = []
            var newToken: CKServerChangeToken?

            let zoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            zoneConfig.previousServerChangeToken = previousToken

            let fetchOperation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [cloudKit.zoneID],
                configurationsByRecordZoneID: [cloudKit.zoneID: zoneConfig]
            )
            fetchOperation.fetchAllChanges = true

            fetchOperation.recordWasChangedBlock = { _, result in
                if let record = try? result.get() {
                    modifiedRecords.append(record)
                }
            }

            fetchOperation.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedRecordIDs.append(recordID)
            }

            fetchOperation.recordZoneFetchResultBlock = { _, result in
                if let zoneResult = try? result.get() {
                    newToken = zoneResult.serverChangeToken
                }
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                fetchOperation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                cloudKit.privateDB.add(fetchOperation)
            }

            // Process modified records
            for record in modifiedRecords {
                if let handler = recordHandlers[record.recordType] {
                    handler(record)
                }
                localStore.cacheRecord(record)
            }

            // Process deleted records - use prefix map for reliable type matching
            for recordID in deletedRecordIDs {
                let recordName = recordID.recordName
                for (prefix, recordType) in deletePrefixMap {
                    if recordName.hasPrefix(prefix + "_") {
                        deleteHandlers[recordType]?(recordID)
                    }
                }
                localStore.removeCachedRecord(recordName: recordName)
            }

            // Persist change token
            if let newToken = newToken {
                localStore.serverChangeToken = newToken
            }

            lastSyncDate = Date()
        } catch let error as CKError where error.code == .changeTokenExpired {
            // Token expired - reset and re-fetch
            localStore.serverChangeToken = nil
            await fetchRemoteChanges()
        } catch {
            lastSyncError = error
        }
    }

    // MARK: - Query

    /// Query records by type with optional predicate and sort descriptors.
    public func queryRecords(
        recordType: String,
        predicate: NSPredicate = NSPredicate(value: true),
        sortDescriptors: [NSSortDescriptor]? = nil
    ) async throws -> [CKRecord] {
        guard cloudKit.isCloudAvailable else {
            throw CloudKitError.notConfigured
        }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        do {
            let (matchResults, _) = try await cloudKit.privateDB.records(matching: query)
            let records = matchResults.compactMap { _, result in
                try? result.get()
            }
            lastSyncDate = Date()
            return records
        } catch {
            lastSyncError = error
            throw error
        }
    }

    // MARK: - Batch Operations

    /// Batch save records in chunks of 400 (CK limit per operation).
    public func batchSaveRecords(_ records: [CKRecord]) async throws {
        guard cloudKit.isCloudAvailable else { return }
        guard !records.isEmpty else { return }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let chunkSize = 400
        let chunks = stride(from: 0, to: records.count, by: chunkSize).map {
            Array(records[$0..<min($0 + chunkSize, records.count)])
        }

        for chunk in chunks {
            _ = try await cloudKit.privateDB.modifyRecords(saving: chunk, deleting: [])
        }

        lastSyncDate = Date()
    }

    /// Batch delete records by IDs in chunks of 400.
    public func batchDeleteRecords(_ recordIDs: [CKRecord.ID]) async throws {
        guard cloudKit.isCloudAvailable else { return }
        guard !recordIDs.isEmpty else { return }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let chunkSize = 400
        let chunks = stride(from: 0, to: recordIDs.count, by: chunkSize).map {
            Array(recordIDs[$0..<min($0 + chunkSize, recordIDs.count)])
        }

        for chunk in chunks {
            _ = try await cloudKit.privateDB.modifyRecords(saving: [], deleting: chunk)
        }

        // Clean local cache
        for id in recordIDs {
            localStore.removeCachedRecord(recordName: id.recordName)
        }

        lastSyncDate = Date()
    }

    // MARK: - Conflict Resolution

    private func resolveConflictAndSave(localRecord: CKRecord, serverRecord: CKRecord) async throws {
        // Start from server version as base, overlay local changes
        for key in localRecord.allKeys() {
            if let localDate = localRecord[key] as? Date,
               let serverDate = serverRecord[key] as? Date {
                serverRecord[key] = localDate > serverDate ? localDate : serverDate
            } else if let localValue = localRecord[key] {
                serverRecord[key] = localValue
            }
        }

        serverRecord["updated_at"] = Date()

        do {
            _ = try await cloudKit.privateDB.save(serverRecord)
            localStore.cacheRecord(serverRecord)
            lastSyncDate = Date()
        } catch {
            lastSyncError = error
            throw error
        }
    }
}
