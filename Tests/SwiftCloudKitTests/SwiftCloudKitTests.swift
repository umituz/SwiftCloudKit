import CloudKit
import XCTest
@testable import SwiftCloudKit

// MARK: - Configuration Tests

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

    func testConfigurationIsSendable() {
        let config = CloudKitManager.Configuration(containerIdentifier: "test")
        let _: any Sendable = config
    }
}

// MARK: - CloudKitManager Tests

@MainActor
final class CloudKitManagerTests: XCTestCase {

    override func setUp() {
        CloudKitManager.shared.resetConfiguration()
    }

    func testUnconfiguredManagerThrowsContainer() async {
        do {
            _ = try CloudKitManager.shared.container
            XCTFail("Expected CloudKitError.notConfigured")
        } catch let error as CloudKitError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnconfiguredManagerThrowsDatabase() {
        do {
            _ = try CloudKitManager.shared.privateDB
            XCTFail("Expected CloudKitError.notConfigured")
        } catch let error as CloudKitError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnconfiguredManagerThrowsZoneID() {
        do {
            _ = try CloudKitManager.shared.zoneID
            XCTFail("Expected CloudKitError.notConfigured")
        } catch let error as CloudKitError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnconfiguredManagerThrowsConfiguration() {
        do {
            _ = try CloudKitManager.shared.configuration
            XCTFail("Expected CloudKitError.notConfigured")
        } catch let error as CloudKitError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInitialNotConfigured() {
        XCTAssertFalse(CloudKitManager.shared.isConfigured)
        XCTAssertFalse(CloudKitManager.shared.isCloudAvailable)
        XCTAssertEqual(CloudKitManager.shared.accountStatus, .couldNotDetermine)
        XCTAssertNil(CloudKitManager.shared.lastAccountStatusError)
    }

    func testResetConfigurationCleansAllState() {
        let manager = CloudKitManager.shared
        manager.resetConfiguration()

        XCTAssertFalse(manager.isConfigured)
        XCTAssertFalse(manager.isCloudAvailable)
        XCTAssertEqual(manager.accountStatus, .couldNotDetermine)
        XCTAssertNil(manager.lastAccountStatusError)
    }

    func testResetConfigurationIsIdempotent() {
        CloudKitManager.shared.resetConfiguration()
        CloudKitManager.shared.resetConfiguration()
        XCTAssertFalse(CloudKitManager.shared.isConfigured)
    }
}

// MARK: - Record Factory Tests

@MainActor
final class RecordFactoryTests: XCTestCase {

    func testSetTimestampsSetsBothFields() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        CloudKitRecordFactory.setTimestamps(record)
        XCTAssertNotNil(record["created_at"])
        XCTAssertNotNil(record["updated_at"])
    }

    func testSetTimestampsPreservesExistingCreatedAt() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        let originalDate = Date.distantPast
        record["created_at"] = originalDate
        CloudKitRecordFactory.setTimestamps(record)
        XCTAssertEqual(record["created_at"] as? Date, originalDate)
    }

    func testTouchTimestampOnlyUpdatesUpdatedAt() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        CloudKitRecordFactory.touchTimestamp(record)
        XCTAssertNotNil(record["updated_at"])
        XCTAssertNil(record["created_at"])
    }

    func testEncodeDecodeStringRoundTrip() throws {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        struct Sample: Codable, Equatable { let name: String; let count: Int }
        let original = Sample(name: "Test", count: 42)

        try CloudKitRecordFactory.encodeToString(original, field: "data", record: record)
        let decoded = try CloudKitRecordFactory.decodeFromString(Sample.self, field: "data", record: record)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeMissingFieldThrows() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        struct Sample: Codable { let name: String }
        XCTAssertThrowsError(try CloudKitRecordFactory.decodeFromString(Sample.self, field: "nonexistent", record: record))
    }

    func testDecodeInvalidJSONThrows() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        record["data"] = "not valid json {{{"
        struct Sample: Codable { let name: String }
        XCTAssertThrowsError(try CloudKitRecordFactory.decodeFromString(Sample.self, field: "data", record: record))
    }

    func testDecodeFromAssetWithMissingFieldThrows() {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        XCTAssertThrowsError(try CloudKitRecordFactory.decodeFromAsset(String.self, field: "nonexistent", record: record))
    }

    func testEncodeToStringWithNonASCII() throws {
        let record = CKRecord(recordType: "TestRecord", recordID: CKRecord.ID(recordName: "test"))
        struct Payload: Codable, Equatable { let text: String }
        let original = Payload(text: "Hello \u{4E16}\u{754C}")
        try CloudKitRecordFactory.encodeToString(original, field: "data", record: record)
        XCTAssertEqual(try CloudKitRecordFactory.decodeFromString(Payload.self, field: "data", record: record), original)
    }
}

// MARK: - Error Description Tests

@MainActor
final class ErrorDescriptionTests: XCTestCase {

    func testAllCloudKitErrorsHaveDescriptions() {
        let errors: [CloudKitError] = [
            .noAccount,
            .restricted,
            .accountStatusUnknown,
            .accountTemporarilyUnavailable,
            .zoneNotFound,
            .quotaExceeded,
            .networkFailure,
            .notConfigured,
            .syncFailed("test reason"),
            .recordNotFound
        ]

        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Missing description for \(error)")
        }
    }

    func testAllRecordFactoryErrorsHaveDescriptions() {
        let errors: [CloudKitRecordFactoryError] = [
            .invalidAssetURL,
            .encodingFailed,
            .missingField("test_field")
        ]

        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Missing description for \(error)")
        }
    }

    func testCloudKitErrorEquality() {
        XCTAssertEqual(CloudKitError.noAccount, CloudKitError.noAccount)
        XCTAssertNotEqual(CloudKitError.noAccount, CloudKitError.restricted)
        XCTAssertEqual(CloudKitError.syncFailed("a"), CloudKitError.syncFailed("a"))
        XCTAssertNotEqual(CloudKitError.syncFailed("a"), CloudKitError.syncFailed("b"))
    }
}

// MARK: - SyncEvent Tests

@MainActor
final class SyncEventTests: XCTestCase {

    func testAllSyncEventCases() {
        let events: [SyncEvent] = [
            .syncStarted,
            .syncCompleted(recordCount: 5, deleteCount: 2),
            .syncFailed(error: CloudKitError.networkFailure),
            .recordSaved(recordName: "test_record"),
            .recordDeleted(recordName: "deleted_record")
        ]
        XCTAssertEqual(events.count, 5)
    }

    func testSyncEventIsSendable() {
        let event: SyncEvent = .syncStarted
        let _: any Sendable = event
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

    func testRegisterMultipleFiles() {
        let cleanup = CloudKitAssetCleanup.shared
        let initialCount = cleanup.tempFileCount
        let urls = (0..<3).map { _ in FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
        for url in urls {
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }

        cleanup.registerTempFiles(urls)
        XCTAssertEqual(cleanup.tempFileCount, initialCount + 3)

        cleanup.cleanupAll()
        XCTAssertEqual(cleanup.tempFileCount, 0)
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

    func testRemoveNonexistentRecordDoesNotCrash() {
        CloudKitLocalStore.shared.removeCachedRecord(recordName: "nonexistent_\(UUID().uuidString)")
    }
}
