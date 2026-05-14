import CloudKit
import XCTest
@testable import SwiftCloudKit

final class SwiftCloudKitTests: XCTestCase {

    // MARK: - Configuration

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

    // MARK: - Singletons

    func testSingletonInstances() {
        _ = CloudKitManager.shared
        _ = CloudKitSyncCoordinator.shared
        _ = CloudKitLocalStore.shared
        _ = CloudKitAssetCleanup.shared
    }

    // MARK: - Record ID Generation

    func testRecordIDNamingConvention() {
        // Test naming convention without requiring CloudKitManager configuration
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

        let recordID = CKRecord.ID(recordName: "userprofile_abc123", zoneID: zoneID)
        XCTAssertEqual(recordID.recordName, "userprofile_abc123")

        let singletonID = CKRecord.ID(recordName: "settings_default", zoneID: zoneID)
        XCTAssertEqual(singletonID.recordName, "settings_default")
    }

    // MARK: - Timestamps

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
        XCTAssertNil(record["created_at"]) // Should NOT set created_at
    }

    // MARK: - Codable Helpers

    func testEncodeDecodeString() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        struct Sample: Codable, Equatable {
            let name: String
            let count: Int
        }

        let original = Sample(name: "Test", count: 42)

        XCTAssertNoThrow(try CloudKitRecordFactory.encodeToString(original, field: "data", record: record))

        let decoded = CloudKitRecordFactory.decodeFromString(Sample.self, field: "data", record: record)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeMissingFieldReturnsNil() {
        let recordID = CKRecord.ID(recordName: "test")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)

        struct Sample: Codable {
            let name: String
        }

        let result = CloudKitRecordFactory.decodeFromString(Sample.self, field: "nonexistent", record: record)
        XCTAssertNil(result)
    }

    // MARK: - CloudKitError

    func testCloudKitErrorDescriptions() {
        XCTAssertFalse(CloudKitError.noAccount.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.restricted.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.accountStatusUnknown.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.accountTemporarilyUnavailable.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.zoneNotFound.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.quotaExceeded.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.networkFailure.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CloudKitError.notConfigured.errorDescription?.isEmpty ?? true)
    }

    // MARK: - CloudKitRecordFactoryError

    func testRecordFactoryErrorDescription() {
        XCTAssertFalse(CloudKitRecordFactoryError.invalidAssetURL.errorDescription?.isEmpty ?? true)
    }

    // MARK: - Asset Cleanup

    @MainActor
    func testAssetCleanupRegisterAndCount() {
        let cleanup = CloudKitAssetCleanup.shared
        let initialCount = cleanup.tempFileCount

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))

        cleanup.registerTempFile(tempURL)
        XCTAssertEqual(cleanup.tempFileCount, initialCount + 1)

        cleanup.cleanupTempFiles(for: tempURL.lastPathComponent)
        XCTAssertEqual(cleanup.tempFileCount, initialCount)
    }

    // MARK: - Local Store

    func testLocalStoreServerChangeTokenRoundTrip() {
        let store = CloudKitLocalStore.shared

        // Initially nil
        XCTAssertNil(store.serverChangeToken)

        // Clear to ensure clean state
        store.serverChangeToken = nil
        XCTAssertNil(store.serverChangeToken)
    }

    func testLocalStoreCacheRecordRoundTrip() {
        let store = CloudKitLocalStore.shared
        let recordID = CKRecord.ID(recordName: "test_cache_record")
        let record = CKRecord(recordType: "TestRecord", recordID: recordID)
        record["test_field"] = "test_value"

        store.cacheRecord(record)

        let cached = store.cachedRecord(recordName: "test_cache_record")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.recordType, "TestRecord")

        store.removeCachedRecord(recordName: "test_cache_record")
        XCTAssertNil(store.cachedRecord(recordName: "test_cache_record"))
    }
}
