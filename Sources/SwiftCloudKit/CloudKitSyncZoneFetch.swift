import CloudKit
import Foundation
import os.log

extension CloudKitSyncCoordinator {

    struct ZoneFetchResult {
        let modifiedRecords: [CKRecord]
        let deletedRecordIDs: [CKRecord.ID]
        let changeToken: CKServerChangeToken?
    }

    func performZoneFetch(
        database: CKDatabase,
        zone: CKRecordZone.ID,
        previousToken: CKServerChangeToken?
    ) async throws -> ZoneFetchResult {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = previousToken

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: config]
        )
        operation.fetchAllChanges = true

        let lock = NSLock()
        var modified: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var token: CKServerChangeToken?

        operation.recordWasChangedBlock = { [logger] _, result in
            switch result {
            case .success(let record):
                lock.lock()
                modified.append(record)
                lock.unlock()
            case .failure(let error):
                logger.warning("Failed to fetch individual record: \(error.localizedDescription)")
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            lock.lock()
            deleted.append(recordID)
            lock.unlock()
        }
        operation.recordZoneFetchResultBlock = { _, result in
            if let zoneResult = try? result.get() {
                lock.lock()
                token = zoneResult.serverChangeToken
                lock.unlock()
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let err): continuation.resume(throwing: err)
                }
            }
            database.add(operation)
        }

        return ZoneFetchResult(
            modifiedRecords: modified,
            deletedRecordIDs: deleted,
            changeToken: token
        )
    }

    func processFetchedRecords(_ result: ZoneFetchResult) {
        for record in result.modifiedRecords {
            recordHandlers[record.recordType]?(record)
            localStore.cacheRecord(record)
        }
        for recordID in result.deletedRecordIDs {
            dispatchDeletedRecord(recordID)
            localStore.removeCachedRecord(recordName: recordID.recordName)
        }
        if let token = result.changeToken {
            localStore.serverChangeToken = token
        }
    }
}
