# SwiftCloudKit

Generic CloudKit integration package for iOS apps. Provides a clean, type-safe interface to CloudKit with built-in conflict resolution, change tracking, and asset management.

## Features

- Easy Integration: Single package, minimal setup
- Conflict Resolution: Automatic Last-Write-Wins + Merge strategy
- Change Tracking: Efficient sync using CKServerChangeToken
- Asset Management: Automatic temp file cleanup for CKAsset
- Codable Helpers: Encode/decode models to/from CKRecord fields
- Offline Graceful: Works without iCloud account (local-first)
- iOS 17+ Support: Modern async/await APIs throughout

## Installation

### Swift Package Manager (XcodeGen project.yml)

```yaml
packages:
  SwiftCloudKit:
    path: ../_packages/SwiftCloudKit

targets:
  YourApp:
    dependencies:
      - package: SwiftCloudKit
```

### Swift Package Manager (remote)

```yaml
packages:
  SwiftCloudKit:
    url: https://github.com/umituz/SwiftCloudKit
    from: 1.0.0
```

## Quick Start

### 1. Configure CloudKit in your App

```swift
import SwiftUI
import SwiftCloudKit

@main
struct YourApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        Task { @MainActor in
            await configureCloudKit()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private func configureCloudKit() async {
        let config = CloudKitManager.Configuration(
            containerIdentifier: "iCloud.com.umituz.yourapp",
            zoneName: "YourAppData",
            subscriptionID: "yourapp-database-changes"
        )

        // configureIfPossible won't crash if iCloud is unavailable
        let success = await CloudKitManager.shared.configureIfPossible(with: config)

        if success {
            UIApplication.shared.registerForRemoteNotifications()
            await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
        }
    }
}
```

### 2. Set up AppDelegate for Push Notifications

```swift
import SwiftCloudKit
import CloudKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let notification = CKNotification(fromRemoteNotificationDictionary: userInfo as! [String: NSObject])
        if notification.subscriptionID == "yourapp-database-changes" {
            Task { @MainActor in
                await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
                completionHandler(.newData)
            }
        } else {
            completionHandler(.noData)
        }
    }
}
```

### 3. Add Entitlements

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.umituz.yourapp</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)com.umituz.yourapp</string>
<key>aps-environment</key>
<string>production</string>
```

### 4. Add UIBackgroundModes to Info.plist

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

## API Reference

### CloudKitManager

Container lifecycle, zones, subscriptions, account monitoring.

```swift
// Configure (throws on failure)
try await CloudKitManager.shared.configure(with: config)

// Configure gracefully (returns false if iCloud unavailable)
let success = await CloudKitManager.shared.configureIfPossible(with: config)

// Check availability
CloudKitManager.shared.isCloudAvailable
CloudKitManager.shared.isConfigured
CloudKitManager.shared.accountStatus
```

### CloudKitSyncCoordinator

Conflict resolution, remote fetching, CRUD operations.

```swift
// Register handlers for remote changes
CloudKitSyncCoordinator.shared.registerRecordHandler(
    recordType: "UserProfile",
    namePrefix: "userprofile",
    onUpdate: { record in /* handle update */ },
    onDelete: { recordID in /* handle deletion */ }
)

// Save with conflict resolution
try await CloudKitSyncCoordinator.shared.saveRecord(record)

// Delete
try await CloudKitSyncCoordinator.shared.deleteRecord(recordID)

// Fetch single record
let record = try await CloudKitSyncCoordinator.shared.fetchRecord(recordID: id)

// Query
let records = try await CloudKitSyncCoordinator.shared.queryRecords(
    recordType: "UserProfile",
    sortDescriptors: [NSSortDescriptor(key: "updated_at", ascending: false)]
)

// Batch save
try await CloudKitSyncCoordinator.shared.batchSaveRecords(records)

// Batch delete
try await CloudKitSyncCoordinator.shared.batchDeleteRecords(recordIDs)

// Fetch remote changes (call on app active + push notification)
await CloudKitSyncCoordinator.shared.fetchRemoteChanges()

// Observe sync state
CloudKitSyncCoordinator.shared.isSyncing
CloudKitSyncCoordinator.shared.lastSyncDate
CloudKitSyncCoordinator.shared.lastSyncError
```

### CloudKitRecordFactory

Record ID generation, timestamps, asset and Codable helpers.

```swift
// Record IDs
let id = CloudKitRecordFactory.recordID(type: "UserProfile", identifier: userUUID)
let singletonID = CloudKitRecordFactory.singletonRecordID(type: "Settings")

// Timestamps
CloudKitRecordFactory.setTimestamps(record)  // sets created_at + updated_at
CloudKitRecordFactory.touchTimestamp(record)  // updates only updated_at

// Assets from Data/URL
let asset = try CloudKitRecordFactory.createAsset(from: imageData)
let data = try CloudKitRecordFactory.data(from: asset)

// Encode/decode Codable to JSON string field
try CloudKitRecordFactory.encodeToString(myModel, field: "data", record: record)
let decoded = CloudKitRecordFactory.decodeFromString(MyModel.self, field: "data", record: record)

// Encode/decode Codable to CKAsset field (for larger data)
try CloudKitRecordFactory.encodeToAsset(myModel, field: "data", record: record)
let decoded = CloudKitRecordFactory.decodeFromAsset(MyModel.self, field: "data", record: record)
```

### CloudKitLocalStore

Change token persistence and record caching.

```swift
// Change token (automatically managed)
CloudKitLocalStore.shared.serverChangeToken

// Record cache
CloudKitLocalStore.shared.cacheRecord(record)
let cached = CloudKitLocalStore.shared.cachedRecord(recordName: "id")
CloudKitLocalStore.shared.removeCachedRecord(recordName: "id")
CloudKitLocalStore.shared.clearCache()
CloudKitLocalStore.shared.cacheSize
```

### CloudKitAssetCleanup

Temp file lifecycle management for CKAsset.

```swift
CloudKitAssetCleanup.shared.registerTempFile(url)
CloudKitAssetCleanup.shared.cleanupTempFiles(for: identifier)
CloudKitAssetCleanup.shared.cleanup(record: record)
CloudKitAssetCleanup.shared.cleanupAll()
```

## Architecture

```
Domain Services (app-specific CRUD)
         |
CloudKitSyncCoordinator (conflict resolution, remote changes)
         |
CloudKitManager (container, zone, subscription, account)
         |
   CKDatabase (privateDB)
```

| Component | Responsibility |
|-----------|---------------|
| **CloudKitManager** | Container lifecycle, zones, subscriptions, account monitoring |
| **CloudKitSyncCoordinator** | Conflict resolution, remote fetching, CRUD operations |
| **CloudKitLocalStore** | Change token persistence, record caching |
| **CloudKitRecordFactory** | Record ID generation, timestamps, asset/codable helpers |
| **CloudKitAssetCleanup** | Temp file lifecycle management |

## Per-App Integration

Each app should create:

1. **AppRecordFactory** - defines record types and model-to-CKRecord conversions
2. **AppCloudKitService** - domain-specific CRUD operations

Example:

```swift
@MainActor
enum AppRecordFactory {
    static let recordTypeUserProfile = "UserProfile"
    static let recordTypePrediction = "Prediction"

    static func toRecord(_ profile: UserProfile) -> CKRecord {
        let id = CloudKitRecordFactory.recordID(type: recordTypeUserProfile, identifier: profile.id)
        let record = CKRecord(recordType: recordTypeUserProfile, recordID: id)
        record["name"] = profile.name
        record["username"] = profile.username
        CloudKitRecordFactory.setTimestamps(record)
        return record
    }

    static func fromRecord(_ record: CKRecord) -> UserProfile? {
        guard let name = record["name"] as? String,
              let username = record["username"] as? String else { return nil }
        return UserProfile(id: record.recordID.recordName, name: name, username: username)
    }
}
```

## License

MIT License
