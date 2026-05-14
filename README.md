# SwiftCloudKit

Generic CloudKit integration package for iOS apps. Provides a clean, type-safe interface to CloudKit with built-in conflict resolution, change tracking, and asset management.

## Features

- ✅ **Easy Integration**: Single package, minimal setup
- ✅ **Conflict Resolution**: Automatic Last-Write-Wins + Merge strategy
- ✅ **Change Tracking**: Efficient sync using CKServerChangeToken
- ✅ **Asset Management**: Automatic temp file cleanup
- ✅ **Type-Safe**: Swift native types throughout
- ✅ **iOS 17+ Support**: Modern async/await APIs

## Installation

### Swift Package Manager

**project.yml:**
```yaml
packages:
  SwiftCloudKit:
    url: https://github.com/umituz/SwiftCloudKit.git
    from: 1.0.0

targets:
  YourApp:
    dependencies:
      - package: SwiftCloudKit
        product: SwiftCloudKit
```

**Xcode:**
1. File → Add Package Dependencies
2. URL: `https://github.com/umituz/SwiftCloudKit.git`
3. Add `SwiftCloudKit` product

## Quick Start

### 1. Configure CloudKit

```swift
import SwiftCloudKit

// In your App init or onAppear
Task {
    let config = CloudKitManager.Configuration(
        containerIdentifier: "iCloud.com.yourcompany.yourapp",
        zoneName: "AppData",
        subscriptionID: "yourapp-database-changes"
    )
    try await CloudKitManager.shared.configure()
}
```

### 2. Set up AppDelegate

```swift
// AppDelegate.swift
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

### 3. Add to your main App

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
        do {
            let config = CloudKitManager.Configuration(
                containerIdentifier: "iCloud.com.yourcompany.yourapp",
                zoneName: "AppData",
                subscriptionID: "yourapp-database-changes"
            )
            try await CloudKitManager.shared.configure()
            UIApplication.shared.registerForRemoteNotifications()
            await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
        } catch {
            print("CloudKit error: \(error)")
        }
    }
}
```

## Usage

### Save Records

```swift
let record = CloudKitRecordFactory.createUserProfile()
record["name"] = "John Doe"
record["email"] = "john@example.com"
CloudKitRecordFactory.updateTimestamps(record)

try await CloudKitSyncCoordinator.shared.saveRecord(record)
```

### Query Records

```swift
let records = try await CloudKitSyncCoordinator.shared.queryRecords(
    recordType: "UserProfile",
    sortDescriptors: [NSSortDescriptor(key: "created_at", ascending: false)]
)
```

### Fetch Remote Changes

```swift
// Automatically called on app active and push notifications
await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
```

### Handle Changes

```swift
CloudKitSyncCoordinator.shared.registerRecordHandler(
    recordType: "UserProfile",
    onUpdate: { record in
        // Handle updated record
        let name = record["name"] as? String ?? ""
        print("Updated: \(name)")
    },
    onDelete: { recordID in
        // Handle deleted record
        print("Deleted: \(recordID.recordName)")
    }
)
```

## Entitlements

Add to your `.entitlements` file:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.yourcompany.yourapp</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)com.yourcompany.yourapp</string>
<key>aps-environment</key>
<string>production</string>
```

## Info.plist

Add to `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

## Architecture

### Components

- **CloudKitManager**: Container lifecycle, zones, subscriptions, account monitoring
- **CloudKitSyncCoordinator**: Conflict resolution, remote fetching, change tracking
- **CloudKitLocalStore**: Change token persistence, record caching
- **CloudKitRecordFactory**: Record ID generation, model↔record conversion
- **CloudKitAssetCleanup**: Temp file lifecycle management

### Data Flow

```
Domain Services
    ↓
CloudKitSyncCoordinator (conflict resolution)
    ↓
CloudKitManager (container, zone, subscription)
    ↓
CKDatabase (privateDB)
```

## CloudKit Dashboard Setup

1. Go to: https://icloud.developer.apple.com/dashboard
2. Create container: `iCloud.com.yourcompany.yourapp`
3. Create record types:
   - UserProfile
   - AppData
   - Settings

## Testing

- Test with two simulators (different iCloud accounts)
- Test airplane mode scenarios
- Test conflict resolution
- Test account changes

## License

MIT License

## Author

Created for generic CloudKit integration across all projects.

GitHub: https://github.com/umituz/SwiftCloudKit
