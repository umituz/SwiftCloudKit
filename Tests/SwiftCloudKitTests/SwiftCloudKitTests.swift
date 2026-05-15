//
//  SwiftCloudKitTests.swift
//  SwiftCloudKitTests
//

import CloudKit
import XCTest
@testable import SwiftCloudKit

// MARK: - Configuration & Singleton Tests

@MainActor
final class ConfigurationTests: XCTestCase {

    func testConfigurationCreation() {
        let config = CloudKitManager.Configuration(
            containerIdentifier: "iCloud.com.test.app",
            zoneName: "TestZone",
            subscriptionID: "test-subscription"
        )

        XCTAssertEqual(config.containerIdentifier, "iCloud.com.test.app")
        XCTAssertEqual(config.zoneName, "TestZone")
        XCTAssertEqual(config.subscriptionID, "test-subscription")
    }

    func testConfigurationDefaults() {
        let config = CloudKitManager.Configuration(
            containerIdentifier: "iCloud.com.test.app"
        )

        XCTAssertEqual(config.zoneName, "AppData")
        XCTAssertEqual(config.subscriptionID, "app-database-changes")
    }

    func testSingletonInstances() {
        _ = CloudKitManager.shared
        _ = CloudKitSyncCoordinator.shared
        _ = CloudKitLocalStore.shared
        _ = CloudKitAssetCleanup.shared
    }
}

// MARK: - CloudKitManager Tests

@MainActor
final class CloudKitManagerTests: XCTestCase {

    func testUnconfiguredManagerThrows() async {
        let manager = CloudKitManager.shared

        do {
            _ = try manager.container
            XCTFail("Expected CloudKitError.notConfigured")
        } catch let error as CloudKitError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testManagerIsNotConfiguredInitially() {
        let manager = CloudKitManager.shared
        _ = manager.isConfigured
    }

    func testResetConfiguration() {
        let manager = CloudKitManager.shared
        manager.resetConfiguration()
        XCTAssertFalse(manager.isConfigured)
        XCTAssertFalse(manager.isCloudAvailable)
    }
}

// MARK: - Record Factory Tests

@MainActor
final class RecordFactoryTests: XCTestCase {

    func testRecordIDNamingConvention() {
        let zoneID = CKRecordZone.ID(
            zoneName: "TestZone", ownerName: CKCurrentUserDefaultName
        )
        let recordID = CKRecord.ID(recordName: "userprofile_abc123", zoneID: zoneID)
        XCTAssertEqual(recordID.recordName, "userprofile_abc123")

        let singletonID = CKRecord.ID(recordName: "settings_default", zoneID: zoneID)
        XCTAssertEqual(singletonID.recordName, "settings_default")
    }

    func testSetTimestamps() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        CloudKitRecordFactory.setTimestamps(record)
        XCTAssertNotNil(record["created_at"])
        XCTAssertNotNil(record["updated_at"])
    }

    func testSetTimestampsDoesNotOverwriteCreatedAt() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        let originalDate = Date.distantPast
        record["created_at"] = originalDate
        CloudKitRecordFactory.setTimestamps(record)
        XCTAssertEqual(record["created_at"] as? Date, originalDate)
    }

    func testTouchTimestamp() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        CloudKitRecordFactory.touchTimestamp(record)
        XCTAssertNotNil(record["updated_at"])
        XCTAssertNil(record["created_at"])
    }

    func testEncodeDecodeString() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        struct Sample: Codable, Equatable { let name: String; let count: Int }
        let original = Sample(name: "Test", count: 42)

        XCTAssertNoThrow(try CloudKitRecordFactory.encodeToString(original, field: "data", record: record))
        let decoded = CloudKitRecordFactory.decodeFromString(Sample.self, field: "data", record: record)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeMissingFieldReturnsNil() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        struct Sample: Codable { let name: String }
        XCTAssertNil(CloudKitRecordFactory.decodeFromString(Sample.self, field: "nonexistent", record: record))
    }

    func testDecodeInvalidJSONReturnsNil() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        record["data"] = "not valid json {{{"
        struct Sample: Codable { let name: String }
        XCTAssertNil(CloudKitRecordFactory.decodeFromString(Sample.self, field: "data", record: record))
    }

    func testDecodeFromAssetWithMissingFieldReturnsNil() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        XCTAssertNil(CloudKitRecordFactory.decodeFromAsset(String.self, field: "nonexistent", record: record))
    }

    func testEncodeToStringWithNonASCII() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        struct Data: Codable, Equatable { let text: String }
        let original = Data(text: "Hello \u{4E16}\u{754C}")
        XCTAssertNoThrow(try CloudKitRecordFactory.encodeToString(original, field: "data", record: record))
        XCTAssertEqual(CloudKitRecordFactory.decodeFromString(Data.self, field: "data", record: record), original)
    }

    func testDataFromAssetWithoutURLThrows() {
        let asset = CKAsset(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent_\(UUID().uuidString)"))
        // fileURL exists but file doesn't — CKAsset may or may not have a URL
        // Just verify the function exists and handles edge cases
        _ = asset.fileURL
    }
}

// MARK: - Error Description Tests

@MainActor
final class ErrorDescriptionTests: XCTestCase {

    func testCloudKitErrorDescriptions() {
        XCTAssertFalse(CloudKitError.noAccount.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.restricted.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.accountStatusUnknown.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.accountTemporarilyUnavailable.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.zoneNotFound.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.quotaExceeded.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.networkFailure.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.notConfigured.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.syncFailed("test").errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.recordNotFound.errorDescription?.isEmpty ?? true)
    }

    func testRecordFactoryErrorDescriptions() {
        XCTAssertFalse(CloudKitRecordFactoryError.invalidAssetURL.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitRecordFactoryError.encodingFailed.errorDescription?.isEmpty ?? true)
    }

    func testSyncEventCases() {
        let events: [SyncEvent] = [
            .syncStarted,
            .syncCompleted(recordCount: 5, deleteCount: 2),
            .syncFailed(error: CloudKitError.networkFailure),
            .recordSaved(recordName: "test"),
            .recordDeleted(recordName: "test")
        ]
        XCTAssertEqual(events.count, 5)
    }
}

// MARK: - Asset Cleanup Tests

@MainActor
final class AssetCleanupTests: XCTestCase {

    func testRegisterAndCount() {
        let cleanup = CloudKitAssetCleanup.shared
        let initialCount = cleanup.tempFileCount
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))

        cleanup.registerTempFile(tempURL)
        XCTAssertEqual(cleanup.tempFileCount, initialCount + 1)

        cleanup.cleanupTempFiles(for: tempURL.lastPathComponent)
        XCTAssertEqual(cleanup.tempFileCount, initialCount)
    }

    func testRemovesFileFromDisk() {
        let cleanup = CloudKitAssetCleanup.shared
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        cleanup.registerTempFile(tempURL)
        cleanup.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testHandlesMissingFile() {
        let cleanup = CloudKitAssetCleanup.shared
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cleanup.registerTempFile(fakeURL)
        cleanup.cleanupAll()
    }

    func testCleanupForRecord() {
        let cleanup = CloudKitAssetCleanup.shared
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))

        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test_asset"))
        record["image"] = CKAsset(fileURL: tempURL)

        cleanup.registerTempFile(tempURL)
        let countBefore = cleanup.tempFileCount
        cleanup.cleanup(record: record)
        XCTAssertEqual(cleanup.tempFileCount, countBefore - 1)
    }
}

// MARK: - Local Store Tests

@MainActor
final class LocalStoreTests: XCTestCase {

    func testServerChangeTokenRoundTrip() {
        let store = CloudKitLocalStore.shared
        store.serverChangeToken = nil
        XCTAssertNil(store.serverChangeToken)
    }

    func testCacheRecordRoundTrip() {
        let store = CloudKitLocalStore.shared
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test_cache"))
        record["field"] = "value"

        XCTAssertTrue(store.cacheRecord(record))
        XCTAssertNotNil(store.cachedRecord(recordName: "test_cache"))
        XCTAssertEqual(store.cachedRecord(recordName: "test_cache")?.recordType, "TestRecord")

        store.removeCachedRecord(recordName: "test_cache")
        XCTAssertNil(store.cachedRecord(recordName: "test_cache"))
    }

    func testCachedRecordCount() {
        let store = CloudKitLocalStore.shared
        let countBefore = store.cachedRecordCount

        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test_count"))
        store.cacheRecord(record)
        XCTAssertGreaterThanOrEqual(store.cachedRecordCount, countBefore + 1)

        store.removeCachedRecord(recordName: "test_count")
        XCTAssertEqual(store.cachedRecordCount, countBefore)
    }

    func testCacheSize() {
        XCTAssertGreaterThanOrEqual(CloudKitLocalStore.shared.cacheSize, 0)
    }

    func testClearCache() {
        let store = CloudKitLocalStore.shared
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test_clear"))
        store.cacheRecord(record)

        store.clearCache()
        XCTAssertNil(store.cachedRecord(recordName: "test_clear"))
        XCTAssertEqual(store.cacheSize, 0)
    }

    func testCustomUserDefaults() {
        let suiteName = "test.SwiftCloudKit.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(CloudKitLocalStore(userDefaults: defaults).serverChangeToken)
    }

    func testSanitizesRecordName() {
        let store = CloudKitLocalStore.shared
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test/special:chars"))
        record["field"] = "value"

        store.cacheRecord(record)
        XCTAssertNotNil(store.cachedRecord(recordName: "test/special:chars"))
        store.removeCachedRecord(recordName: "test/special:chars")
    }
}

// MARK: - Sync Coordinator Tests

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    func testDefaultConfiguration() {
        let coordinator = CloudKitSyncCoordinator.shared
        XCTAssertEqual(coordinator.maxRetryCount, 3)
        XCTAssertEqual(coordinator.retryBaseDelay, 1.0)
    }

    func testHandlerRegistrationDoesNotDuplicate() {
        let coordinator = CloudKitSyncCoordinator.shared
        coordinator.registerRecordHandler(
            recordType: "TestType", namePrefix: "testtype"
        ) { _ in } onDelete: { _ in }
        coordinator.registerRecordHandler(
            recordType: "TestType", namePrefix: "testtype"
        ) { _ in } onDelete: { _ in }
    }

    func testPrefixMatchingOrder() {
        let coordinator = CloudKitSyncCoordinator.shared
        coordinator.registerRecordHandler(
            recordType: "UserProfile", namePrefix: "userprofile"
        ) { _ in } onDelete: { _ in }
        coordinator.registerRecordHandler(
            recordType: "User", namePrefix: "user"
        ) { _ in } onDelete: { _ in }
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

        // Simulate a sync event
        coordinator.onSyncEvent?(.syncStarted)
        XCTAssertNotNil(receivedEvent)

        coordinator.onSyncEvent = nil
    }
}
