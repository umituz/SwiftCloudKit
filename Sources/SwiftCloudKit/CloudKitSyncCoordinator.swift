//
//  CloudKitSyncCoordinator.swift
//  Generic CloudKit Sync Coordinator
//
//  Created for generic CloudKit integration across all projects
//  Reference: CLOUDKIT_STRUCTURE_FOR_OTHER_PROJECTS.md
//

import CloudKit
import Foundation

/// CloudKit sync coordinator - handles conflict resolution, remote fetching, and change tracking
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

    // Record handlers for incoming remote changes
    private var recordHandlers: [String: (CKRecord) -> Void] = [:]
    private var deleteHandlers: [String: (CKRecord.ID) -> Void] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Register handler for incoming remote record changes
    public func registerRecordHandler(
        recordType: String,
        onUpdate: @escaping (CKRecord) -> Void,
        onDelete: @escaping (CKRecord.ID) -> Void
    ) {
        recordHandlers[recordType] = onUpdate
        deleteHandlers[recordType] = onDelete
    }

    /// Save a record with conflict resolution
    public func saveRecord(_ record: CKRecord) async throws {
        isSyncing = true
        lastSyncError = nil

        do {
            try await cloudKit.privateDB.save(record)
            lastSyncDate = Date()
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Conflict resolution required
            try await resolveConflictAndSave(record, serverRecord: error.serverRecord!)
        } catch {
            lastSyncError = error
            throw error
        }

        isSyncing = false
    }

    /// Update a record with conflict resolution
    public func updateRecord(_ record: CKRecord) async throws {
        isSyncing = true
        lastSyncError = nil

        do {
            try await cloudKit.privateDB.save(record)
            lastSyncDate = Date()
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Conflict resolution required
            try await resolveConflictAndSave(record, serverRecord: error.serverRecord!)
        } catch {
            lastSyncError = error
            throw error
        }

        isSyncing = false
    }

    /// Delete a record
    public func deleteRecord(_ recordID: CKRecord.ID) async throws {
        isSyncing = true
        lastSyncError = nil

        do {
            try await cloudKit.privateDB.deleteRecord(withID: recordID)
            lastSyncDate = Date()
        } catch {
            lastSyncError = error
            throw error
        }

        isSyncing = false
    }

    /// Fetch remote changes using CKFetchRecordZoneChangesOperation
    public func fetchRemoteChanges() async {
        guard !isSyncing else { return } // Already syncing

        isSyncing = true
        lastSyncError = nil

        do {
            let changes = try await fetchRecordZoneChanges()

            // Process modified records
            for record in changes.modifiedRecords {
                if let handler = recordHandlers[record.recordType] {
                    handler(record)
                }

                // Cache the record
                localStore.cacheRecord(record)
            }

            // Process deleted records
            for recordID in changes.deletedRecordIDs {
                if let handler = deleteHandlers[recordID.recordType] {
                    handler(recordID)
                }

                // Remove from cache
                localStore.removeCachedRecord(recordName: recordID.recordName)
            }

            // Persist new change token
            if let newToken = changes.changeToken {
                localStore.serverChangeToken = newToken
            }

            lastSyncDate = Date()
        } catch {
            lastSyncError = error
        }

        isSyncing = false
    }

    /// Query records with optional predicates and sort descriptors
    public func queryRecords(
        recordType: String,
        predicate: NSPredicate = NSPredicate(value: true),
        sortDescriptors: [NSSortDescriptor]? = nil
    ) async throws -> [CKRecord] {
        isSyncing = true
        lastSyncError = nil

        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        do {
            let (matchedRecords, _) = try await cloudKit.privateDB.records(matching: query)
            let records = matchedResultsToArray(matchedRecords)
            lastSyncDate = Date()
            isSyncing = false
            return records
        } catch {
            lastSyncError = error
            isSyncing = false
            throw error
        }
    }

    /// Batch save records
    public func batchSaveRecords(_ records: [CKRecord]) async throws {
        isSyncing = true
        lastSyncError = nil

        // Chunk into groups of 400 (CK limit)
        let chunkSize = 400
        let chunks = stride(from: 0, to: records.count, by: chunkSize).map {
            Array(records[$0..<min($0 + chunkSize, records.count)])
        }

        for chunk in chunks {
            let saveOperation = CKModifyRecordsOperation(
                recordsToSave: chunk,
                recordIDsToDelete: []
            )

            saveOperation.isAtomic = false
            saveOperation.qualityOfService = .userInitiated

            try await withCheckedThrowingContinuation { continuation in
                saveOperation.perRecordCompletionBlock = { record, error in
                    if let error = error {
                        let ckError = error as? CKError
                        if ckError?.code == .serverRecordChanged {
                            // Conflict resolution - handle per record
                            // For now, just log and continue
                            print("Conflict detected for record: \(record.recordID)")
                        }
                    }
                }

                saveOperation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }

                cloudKit.privateDB.add(saveOperation)
            }
        }

        lastSyncDate = Date()
        isSyncing = false
    }

    // MARK: - Private Methods

    private struct FetchedChanges {
        let modifiedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
        let changeToken: CKServerChangeToken?
    }

    private func fetchRecordZoneChanges() async throws -> FetchedChanges {
        let previousServerChangeToken = localStore.serverChangeToken

        var modifiedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var changeToken: CKServerChangeToken?

        let zoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        zoneConfig.previousServerChangeToken = previousServerChangeToken

        let fetchOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [cloudKit.zoneID],
            configurationsByRecordZoneID: [cloudKit.zoneID: zoneConfig]
        )

        fetchOperation.fetchAllChanges = true

        fetchOperation.recordChangedBlock = { record in
            modifiedRecords.append(record)
        }

        fetchOperation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }

        fetchOperation.recordZoneFetchCompletionBlock = { zoneID, changeToken, _, _, error in
            if let error = error {
                print("Zone fetch completion error: \(error)")
            } else {
                changeToken = changeToken
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            fetchOperation.fetchRecordZoneChangesCompletionBlock = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            cloudKit.privateDB.add(fetchOperation)
        }

        return FetchedChanges(
            modifiedRecords: modifiedRecords,
            deletedRecordIDs: deletedRecordIDs,
            changeToken: changeToken
        )
    }

    private func resolveConflictAndSave(_ localRecord: CKRecord, serverRecord: CKRecord) async throws {
        // Last-Write-Wins + Merge strategy
        let mergedRecord = CKRecord(recordType: localRecord.recordType, recordID: localRecord.recordID)

        // Copy all fields from local record
        for (key, value) in localRecord.allKeys() {
            mergedRecord[key] = localRecord[key]
        }

        // For timestamp fields, prefer the newer value
        let timestampFields = ["createdAt", "updatedAt", "modifiedAt"]
        for field in timestampFields {
            if let localDate = localRecord[field] as? Date,
               let serverDate = serverRecord[field] as? Date {
                mergedRecord[field] = serverDate > localDate ? serverDate : localDate
            }
        }

        // For CKAsset fields, prefer whichever version is newer
        for (key, value) in localRecord.allKeys() {
            if let localAsset = localRecord[key] as? CKAsset,
               let serverAsset = serverRecord[key] as? CKAsset {
                // Compare file modification dates if available
                if let localAttrs = try? FileManager.default.attributesOfItem(atPath: localAsset.fileURL.path),
                   let serverAttrs = try? FileManager.default.attributesOfItem(atPath: serverAsset.fileURL.path),
                   let localModDate = localAttrs[.modificationDate] as? Date,
                   let serverModDate = serverAttrs[.modificationDate] as? Date {
                    mergedRecord[key] = serverModDate > localModDate ? serverAsset : localAsset
                }
            }
        }

        // Save the merged record
        try await cloudKit.privateDB.save(mergedRecord)
    }

    private func matchedResultsToArray<T>(_ results: [CKRecord.ID: T]) -> [T] {
        return Array(results.values)
    }
}

// MARK: - Errors

extension CloudKitSyncCoordinator {
    public enum SyncError: LocalizedError {
        case conflictDetected
        case networkFailure
        case quotaExceeded

        public var errorDescription: String? {
            switch self {
            case .conflictDetected:
                return "Conflict detected during sync."
            case .networkFailure:
                return "Network connection failed during sync."
            case .quotaExceeded:
                return "CloudKit quota exceeded."
            }
        }
    }
}
