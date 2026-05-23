import CloudKit
import Foundation
import os.log

extension CloudKitSyncCoordinator {

    // MARK: - Batch Save Result

    /// Result of a batch save operation.
    public struct BatchSaveResult {
        /// Records that were saved successfully.
        public let savedRecords: [CKRecord]
        /// Record IDs that failed to save, paired with their errors.
        public let failedRecords: [(recordID: CKRecord.ID, error: Error)]

        public var hasFailures: Bool { !failedRecords.isEmpty }
    }

    /// Result of a batch delete operation.
    public struct BatchDeleteResult {
        /// Record IDs that were deleted successfully.
        public let deletedIDs: [CKRecord.ID]
        /// Record IDs that failed to delete, paired with their errors.
        public let failedIDs: [(recordID: CKRecord.ID, error: Error)]

        public var hasFailures: Bool { !failedIDs.isEmpty }
    }

    // MARK: - Batch Save

    /// Batch save records in chunks. Returns detailed results for partial failure inspection.
    public func batchSaveRecords(_ records: [CKRecord]) async throws -> BatchSaveResult {
        guard manager.isCloudAvailable else { throw CloudKitError.notConfigured }
        guard !records.isEmpty else {
            completeSync()
            return BatchSaveResult(savedRecords: [], failedRecords: [])
        }
        beginSync()

        let database = try manager.privateDB
        let chunks = records.chunked(into: Self.cloudKitBatchLimit)
        var savedRecords: [CKRecord] = []
        var failedRecords: [(recordID: CKRecord.ID, error: Error)] = []

        for (index, chunk) in chunks.enumerated() {
            do {
                let (saveResults, _) = try await database.modifyRecords(
                    saving: chunk, deleting: []
                )
                for (id, result) in saveResults {
                    switch result {
                    case .success(let record):
                        localStore.cacheRecord(record)
                        savedRecords.append(record)
                    case .failure(let error):
                        failedRecords.append((recordID: id, error: error))
                    }
                }
                logger.info("Batch save chunk \(index + 1)/\(chunks.count)")
            } catch let error as CKError where error.code == .partialFailure {
                if let partials = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                    for (id, partialError) in partials {
                        guard let recordID = id as? CKRecord.ID else { continue }
                        failedRecords.append((recordID: recordID, error: partialError))
                    }
                    let failedIDs = Set(partials.keys.compactMap { $0 as? CKRecord.ID })
                    for record in chunk where !failedIDs.contains(record.recordID) {
                        localStore.cacheRecord(record)
                        savedRecords.append(record)
                    }
                }
                logger.warning("Batch save chunk \(index + 1): \(failedRecords.count) partial failures")
            } catch {
                failSync(error)
                throw error
            }
        }
        completeSync()
        return BatchSaveResult(savedRecords: savedRecords, failedRecords: failedRecords)
    }

    // MARK: - Batch Delete

    /// Batch delete records by IDs in chunks. Returns detailed results for partial failure inspection.
    public func batchDeleteRecords(_ recordIDs: [CKRecord.ID]) async throws -> BatchDeleteResult {
        guard manager.isCloudAvailable else { throw CloudKitError.notConfigured }
        guard !recordIDs.isEmpty else {
            completeSync()
            return BatchDeleteResult(deletedIDs: [], failedIDs: [])
        }
        beginSync()

        let database = try manager.privateDB
        let chunks = recordIDs.chunked(into: Self.cloudKitBatchLimit)
        var deletedIDs: [CKRecord.ID] = []
        var failedIDs: [(recordID: CKRecord.ID, error: Error)] = []

        for (index, chunk) in chunks.enumerated() {
            do {
                let (_, deleteResults) = try await database.modifyRecords(saving: [], deleting: chunk)
                for (id, result) in deleteResults {
                    switch result {
                    case .success:
                        deletedIDs.append(id)
                        localStore.removeCachedRecord(recordName: id.recordName)
                    case .failure(let error):
                        failedIDs.append((recordID: id, error: error))
                    }
                }
                logger.info("Batch delete chunk \(index + 1)/\(chunks.count)")
            } catch {
                failSync(error)
                throw error
            }
        }

        completeSync()
        return BatchDeleteResult(deletedIDs: deletedIDs, failedIDs: failedIDs)
    }
}
