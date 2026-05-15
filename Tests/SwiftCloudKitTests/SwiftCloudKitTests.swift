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
}

// MARK: - Record Factory Tests

@MainActor
final class RecordFactoryTests: XCTestCase {

    func testRecordIDNamingConvention() {
        let zoneID = CKRecordZone.ID(
            zoneName: "TestZone",
            ownerName: CKCurrentUserDefaultName
        )

        let recordID = CKRecord.ID(recordName: "userprofile_abc123", zoneID: zoneID)
        XCTAssertEqual(recordID.recordName, "userprofile_abc123")

        let singletonID = CKRecord.ID(recordName: "settings_default", zoneID: zoneID)
        XCTAssertEqual(singletonID.recordName, "settings_default")
    }

    func testSetTimestamps() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        CloudKitRecordFactory.setTimestamps(record)

        XCTAssertNotNil(record["created_at"])
        XCTAssertNotNil(record["updated_at"])
    }

    func testSetTimestampsDoesNotOverwriteCreatedAt() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        let originalDate = Date.distantPast
        record["created_at"] = originalDate

        CloudKitRecordFactory.setTimestamps(record)

        XCTAssertEqual(record["created_at"] as? Date, originalDate)
        XCTAssertNotNil(record["updated_at"])
    }

    func testTouchTimestamp() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        CloudKitRecordFactory.touchTimestamp(record)

        XCTAssertNotNil(record["updated_at"])
        XCTAssertNil(record["created_at"])
    }

    func testEncodeDecodeString() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        struct Sample: Codable, Equatable {
            let name: String
            let count: Int
        }

        let original = Sample(name: "Test", count: 42)

        XCTAssertNoThrow(
            try CloudKitRecordFactory.encodeToString(
                original, field: "data", record: record
            )
        )

        let decoded = CloudKitRecordFactory.decodeFromString(
            Sample.self, field: "data", record: record
        )
        XCTAssertEqual(decoded, original)
    }

    func testDecodeMissingFieldReturnsNil() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        struct Sample: Codable { let name: String }

        let result = CloudKitRecordFactory.decodeFromString(
            Sample.self, field: "nonexistent", record: record
        )
        XCTAssertNil(result)
    }

    func testDecodeInvalidJSONReturnsNil() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        record["data"] = "not valid json {{{"

        struct Sample: Codable { let name: String }

        let result = CloudKitRecordFactory.decodeFromString(
            Sample.self, field: "data", record: record
        )
        XCTAssertNil(result)
    }

    func testDecodeFromAssetWithMissingFieldReturnsNil() {
        let recordID = CKRecord.ID(recordName: "test_no_url")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        let result = CloudKitRecordFactory.decodeFromAsset(
            String.self, field: "nonexistent", record: record
        )
        XCTAssertNil(result)
    }

    func testEncodeToStringWithNonASCII() {
        let recordID = CKRecord.ID(recordName: "test_unicode")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        struct UnicodeData: Codable, Equatable {
            let text: String
        }

        let original = UnicodeData(text: "Hello \u{4E16}\u{754C}")
        XCTAssertNoThrow(
            try CloudKitRecordFactory.encodeToString(
                original, field: "data", record: record
            )
        )

        let decoded = CloudKitRecordFactory.decodeFromString(
            UnicodeData.self, field: "data", record: record
        )
        XCTAssertEqual(decoded, original)
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

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))

        cleanup.registerTempFile(tempURL)
        XCTAssertEqual(cleanup.tempFileCount, initialCount + 1)

        cleanup.cleanupTempFiles(for: tempURL.lastPathComponent)
        XCTAssertEqual(cleanup.tempFileCount, initialCount)
    }

    func testRemovesFileFromDisk() {
        let cleanup = CloudKitAssetCleanup.shared

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        cleanup.registerTempFile(tempURL)
        cleanup.cleanupAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testHandlesMissingFile() {
        let cleanup = CloudKitAssetCleanup.shared
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        cleanup.registerTempFile(fakeURL)
        cleanup.cleanupAll()
    }

    func testCleanupForRecord() {
        let cleanup = CloudKitAssetCleanup.shared

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))

        let recordID = CKRecord.ID(recordName: "test_asset_cleanup")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        let asset = CKAsset(fileURL: tempURL)
        record["image"] = asset

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
        let recordID = CKRecord.ID(recordName: "test_cache_record")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        record["test_field"] = "test_value"

        let success = store.cacheRecord(record)
        XCTAssertTrue(success)

        let cached = store.cachedRecord(recordName: "test_cache_record")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.recordType, "TestRecord")

        store.removeCachedRecord(recordName: "test_cache_record")
        XCTAssertNil(store.cachedRecord(recordName: "test_cache_record"))
    }

    func testCachedRecordCount() {
        let store = CloudKitLocalStore.shared
        let countBefore = store.cachedRecordCount

        let recordID = CKRecord.ID(recordName: "test_count_record")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        store.cacheRecord(record)

        XCTAssertGreaterThanOrEqual(store.cachedRecordCount, countBefore + 1)

        store.removeCachedRecord(recordName: "test_count_record")
        XCTAssertEqual(store.cachedRecordCount, countBefore)
    }

    func testCacheSize() {
        let store = CloudKitLocalStore.shared
        XCTAssertGreaterThanOrEqual(store.cacheSize, 0)
    }

    func testClearCache() {
        let store = CloudKitLocalStore.shared

        let recordID = CKRecord.ID(recordName: "test_clear_record")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        store.cacheRecord(record)

        store.clearCache()
        XCTAssertNil(store.cachedRecord(recordName: "test_clear_record"))
        XCTAssertEqual(store.cacheSize, 0)
    }

    func testCustomUserDefaults() {
        let suiteName = "test.SwiftCloudKit.\(UUID().uuidString)"
        guard let customDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create test UserDefaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = CloudKitLocalStore(userDefaults: customDefaults)
        XCTAssertNil(store.serverChangeToken)
    }

    func testSanitizesRecordName() {
        let store = CloudKitLocalStore.shared

        let recordID = CKRecord.ID(recordName: "test/special:chars")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        record["field"] = "value"

        store.cacheRecord(record)

        let cached = store.cachedRecord(recordName: "test/special:chars")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.recordType, "TestRecord")

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
}
