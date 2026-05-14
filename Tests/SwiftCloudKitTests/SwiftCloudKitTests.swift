import XCTest
@testable import SwiftCloudKit

final class SwiftCloudKitTests: XCTestCase {
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

    func testRecordIDGeneration() {
        let recordID = CloudKitRecordFactory.customRecordID(name: "test_record")
        XCTAssertEqual(recordID.recordName, "test_record")
    }

    func testSingletonInstances() {
        // Test that singletons are accessible
        _ = CloudKitManager.shared
        _ = CloudKitSyncCoordinator.shared
        _ = CloudKitLocalStore.shared
        _ = CloudKitAssetCleanup.shared
    }
}
