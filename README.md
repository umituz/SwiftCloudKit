# SwiftCloudKit

Generic CloudKit integration package for iOS and macOS apps. Provides a clean, type-safe interface to CloudKit with built-in conflict resolution, change tracking, retry logic, and asset management.

## Requirements

- iOS 17+ / macOS 14+
- Xcode 15+
- Swift 5.9+
- Active Apple Developer account with CloudKit enabled

## Features

- Cross-Platform: iOS 17+ and macOS 14+ with identical API
- Conflict Resolution: Automatic Last-Write-Wins + Merge, or custom resolver
- Change Tracking: Efficient sync using CKServerChangeToken
- Retry Logic: Exponential backoff for transient CloudKit failures
- Cursor Pagination: Automatic cursor-based query pagination
- Sync Events: Observable sync lifecycle callbacks
- Asset Management: Automatic temp file cleanup for CKAsset
- Codable Helpers: Encode/decode models to/from CKRecord fields
- Offline Graceful: Works without iCloud account (local-first)
- Reset Support: Clean reconfiguration on logout

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
    from: 1.0.2
```

## Quick Start — iOS

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

        let success = await CloudKitManager.shared.configureIfPossible(with: config)

        if success {
            UIApplication.shared.registerForRemoteNotifications()
            await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
        }
    }
}
```

### 2. Set up AppDelegate for Push Notifications (iOS)

```swift
import SwiftCloudKit
import CloudKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let notificationInfo = userInfo as? [String: NSObject],
              let notification = CKNotification(fromRemoteNotificationDictionary: notificationInfo),
              notification.subscriptionID == "yourapp-database-changes" else {
            completionHandler(.noData)
            return
        }

        Task { @MainActor in
            await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
            completionHandler(.newData)
        }
    }
}
```

### 3. Add Entitlements (iOS)

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

### 4. Add UIBackgroundModes to Info.plist (iOS)

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

## Quick Start — macOS

### 1. Configure CloudKit in your App

```swift
import SwiftUI
import SwiftCloudKit

@main
struct YourMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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

        let success = await CloudKitManager.shared.configureIfPossible(with: config)

        if success {
            NSApplication.shared.registerForRemoteNotifications()
            await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
        }
    }
}
```

### 2. Set up AppDelegate for Push Notifications (macOS)

```swift
import SwiftCloudKit
import CloudKit
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID == "yourapp-database-changes" else {
            return
        }

        Task { @MainActor in
            await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
        }
    }
}
```

### 3. Add Entitlements (macOS)

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

### 4. Enable Push Notifications Capability

In Xcode: Target → Signing & Capabilities → add **Push Notifications**.

## API Reference

### CloudKitManager

Container lifecycle, zones, subscriptions, account monitoring.

```swift
// Configure (throws on failure)
try await CloudKitManager.shared.configure(with: config)

// Configure gracefully (returns false if iCloud unavailable)
let success = await CloudKitManager.shared.configureIfPossible(with: config)

// Retry after failure (e.g. account became available)
let success = await CloudKitManager.shared.retryConfiguration()

// Reset on logout
CloudKitManager.shared.resetConfiguration()

// Check availability
CloudKitManager.shared.isCloudAvailable
CloudKitManager.shared.isConfigured
CloudKitManager.shared.accountStatus
```

### CloudKitSyncCoordinator

Conflict resolution, remote fetching, CRUD operations with retry.

```swift
let coordinator = CloudKitSyncCoordinator.shared

// Configure retry behavior
coordinator.maxRetryCount = 3       // default: 3
coordinator.retryBaseDelay = 1.0    // default: 1.0s

// Observe sync lifecycle
coordinator.onSyncEvent = { event in
    switch event {
    case .syncStarted: break
    case .syncCompleted(let recordCount, let deleteCount): break
    case .syncFailed(let error): break
    case .recordSaved(let name): break
    case .recordDeleted(let name): break
    }
}

// Custom conflict resolver (optional — defaults to last-write-wins + merge)
coordinator.conflictResolver = { local, server in
    // Return the resolved CKRecord
    return server
}

// Register handlers for remote changes
coordinator.registerRecordHandler(
    recordType: "UserProfile",
    namePrefix: "userprofile",
    onUpdate: { record in /* handle update */ },
    onDelete: { recordID in /* handle deletion */ }
)

// Unregister handlers (on logout or cleanup)
coordinator.unregisterRecordHandler(recordType: "UserProfile")
coordinator.unregisterAllHandlers()

// Save with conflict resolution (throws if cloud unavailable)
try await coordinator.saveRecord(record)

// Delete
try await coordinator.deleteRecord(recordID)

// Fetch single record
let record = try await coordinator.fetchRecord(recordID: id)

// Query with pagination (automatic cursor handling)
let records = try await coordinator.queryRecords(
    recordType: "UserProfile",
    sortDescriptors: [NSSortDescriptor(key: "updated_at", ascending: false)],
    resultsLimit: 100
)

// Batch save
try await coordinator.batchSaveRecords(records)

// Batch delete
try await coordinator.batchDeleteRecords(recordIDs)

// Fetch remote changes (call on app active + push notification)
await coordinator.fetchRemoteChanges()

// Observe sync state
coordinator.isSyncing
coordinator.lastSyncDate
coordinator.lastSyncError
```

### CloudKitRecordFactory

Record ID generation, timestamps, asset and Codable helpers.

```swift
// Record IDs (throws — requires CloudKitManager to be configured)
let id = try CloudKitRecordFactory.recordID(type: "UserProfile", identifier: userUUID)
let singletonID = try CloudKitRecordFactory.singletonRecordID(type: "Settings")

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
CloudKitLocalStore.shared.cachedRecordCount

// Custom UserDefaults (for testing or isolated storage)
let store = CloudKitLocalStore(userDefaults: myUserDefaults)
```

### CloudKitAssetCleanup

Temp file lifecycle management for CKAsset.

```swift
CloudKitAssetCleanup.shared.registerTempFile(url)
CloudKitAssetCleanup.shared.cleanupTempFiles(for: identifier)
CloudKitAssetCleanup.shared.cleanup(record: record)
CloudKitAssetCleanup.shared.cleanupAll()
CloudKitAssetCleanup.shared.tempFileCount
```

### Error Handling

```swift
do {
    try await coordinator.saveRecord(record)
} catch let error as CloudKitError {
    switch error {
    case .notConfigured:  // CloudKit not configured
    case .noAccount:      // No iCloud account
    case .networkFailure: // Network error
    case .quotaExceeded:  // iCloud storage full
    case .syncFailed(let reason):  // Sync-specific failure
    default: break
    }
}
```

## Architecture

```
Domain Services (app-specific CRUD)
         |
CloudKitSyncCoordinator (conflict resolution, remote changes, retry)
         |
CloudKitManager (container, zone, subscription, account)
         |
   CKDatabase (privateDB)
```

| Component | Responsibility |
|-----------|---------------|
| **CloudKitManager** | Container lifecycle, zones, subscriptions, account monitoring |
| **CloudKitSyncCoordinator** | Conflict resolution, remote fetching, CRUD, retry logic |
| **CloudKitSyncRetryPolicy** | Exponential backoff retry for transient failures |
| **CloudKitLocalStore** | Change token persistence, record caching |
| **CloudKitRecordFactory** | Record ID generation, timestamps, asset/codable helpers |
| **CloudKitAssetCleanup** | Temp file lifecycle management |

## Per-App Integration

Each app should create:

1. **AppRecordFactory** — defines record types and model-to-CKRecord conversions
2. **AppCloudKitService** — domain-specific CRUD operations

Example:

```swift
@MainActor
enum AppRecordFactory {
    static let recordTypeUserProfile = "UserProfile"

    static func toRecord(_ profile: UserProfile) throws -> CKRecord {
        let id = try CloudKitRecordFactory.recordID(
            type: recordTypeUserProfile,
            identifier: profile.id.uuidString
        )
        let record = CKRecord(recordType: recordTypeUserProfile, recordID: id)
        record["name"] = profile.name
        record["username"] = profile.username
        CloudKitRecordFactory.setTimestamps(record)
        return record
    }

    static func fromRecord(_ record: CKRecord) -> UserProfile? {
        guard let name = record["name"] as? String,
              let username = record["username"] as? String else { return nil }
        return UserProfile(
            id: record.recordID.recordName,
            name: name,
            username: username
        )
    }
}
```

## License

MIT License
