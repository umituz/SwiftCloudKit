import CloudKit
import XCTest
@testable import SwiftCloudKit

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    override func setUp() {
        CloudKitManager.shared.resetConfiguration()
        CloudKitSyncCoordinator.shared.unregisterAllHandlers()
        CloudKitSyncCoordinator.shared.onSyncEvent = nil
        CloudKitSyncCoordinator.shared.conflictResolver = nil
    }

    func testDefaultConfiguration() {
        let coordinator = CloudKitSyncCoordinator.shared
        XCTAssertEqual(coordinator.maxRetryCount, 3)
        XCTAssertEqual(coordinator.retryBaseDelay, 1.0)
    }

    func testHandlerRegistrationDoesNotDuplicatePrefixEntries() {
        let coordinator = CloudKitSyncCoordinator.shared
        coordinator.registerRecordHandler(
            recordType: "TestType", namePrefix: "testtype"
        ) { _ in } onDelete: { _ in }
        coordinator.registerRecordHandler(
            recordType: "TestType", namePrefix: "testtype"
        ) { _ in } onDelete: { _ in }
        coordinator.unregisterRecordHandler(recordType: "TestType")
    }

    func testUnregisterRecordHandler() {
        let coordinator = CloudKitSyncCoordinator.shared
        coordinator.registerRecordHandler(
            recordType: "UnregisterTest", namePrefix: "unregistertest"
        ) { _ in } onDelete: { _ in }

        coordinator.unregisterRecordHandler(recordType: "UnregisterTest")
    }

    func testUnregisterAllHandlers() {
        let coordinator = CloudKitSyncCoordinator.shared
        coordinator.registerRecordHandler(
            recordType: "CleanupA", namePrefix: "cleanupa"
        ) { _ in } onDelete: { _ in }
        coordinator.registerRecordHandler(
            recordType: "CleanupB", namePrefix: "cleanupb"
        ) { _ in } onDelete: { _ in }

        coordinator.unregisterAllHandlers()
    }

    func testSyncEventCallback() {
        let coordinator = CloudKitSyncCoordinator.shared
        var receivedEvent: SyncEvent?

        coordinator.onSyncEvent = { event in
            receivedEvent = event
        }

        coordinator.onSyncEvent?(.syncStarted)
        XCTAssertNotNil(receivedEvent)

        coordinator.onSyncEvent = nil
    }

    func testConflictResolverCallback() {
        let coordinator = CloudKitSyncCoordinator.shared

        coordinator.conflictResolver = { _, server in
            return server
        }

        XCTAssertNotNil(coordinator.conflictResolver)
        coordinator.conflictResolver = nil
    }

    func testBatchSaveEmptyReturnsEmptyResult() async {
        let coordinator = CloudKitSyncCoordinator.shared
        do {
            let result = try await coordinator.batchSaveRecords([])
            XCTAssertTrue(result.savedRecords.isEmpty)
            XCTAssertTrue(result.failedRecords.isEmpty)
            XCTAssertFalse(result.hasFailures)
        } catch CloudKitError.notConfigured {
            // Expected when not configured
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBatchDeleteEmptyReturnsEmptyResult() async {
        let coordinator = CloudKitSyncCoordinator.shared
        do {
            let result = try await coordinator.batchDeleteRecords([])
            XCTAssertTrue(result.deletedIDs.isEmpty)
            XCTAssertTrue(result.failedIDs.isEmpty)
            XCTAssertFalse(result.hasFailures)
        } catch CloudKitError.notConfigured {
            // Expected when not configured
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveRecordThrowsWhenNotConfigured() async {
        do {
            let record = CKRecord(recordType: "Test", recordID: CKRecord.ID(recordName: "test"))
            try await CloudKitSyncCoordinator.shared.saveRecord(record)
            XCTFail("Expected CloudKitError.notConfigured")
        } catch CloudKitError.notConfigured {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteRecordThrowsWhenNotConfigured() async {
        do {
            let zoneID = CKRecordZone.ID(zoneName: "Test", ownerName: CKCurrentUserDefaultName)
            try await CloudKitSyncCoordinator.shared.deleteRecord(CKRecord.ID(recordName: "test", zoneID: zoneID))
            XCTFail("Expected CloudKitError.notConfigured")
        } catch CloudKitError.notConfigured {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchRecordThrowsWhenNotConfigured() async {
        do {
            let zoneID = CKRecordZone.ID(zoneName: "Test", ownerName: CKCurrentUserDefaultName)
            _ = try await CloudKitSyncCoordinator.shared.fetchRecord(recordID: CKRecord.ID(recordName: "test", zoneID: zoneID))
            XCTFail("Expected CloudKitError.notConfigured")
        } catch CloudKitError.notConfigured {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQueryRecordsThrowsWhenNotConfigured() async {
        do {
            _ = try await CloudKitSyncCoordinator.shared.queryRecords(recordType: "Test")
            XCTFail("Expected CloudKitError.notConfigured")
        } catch CloudKitError.notConfigured {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
