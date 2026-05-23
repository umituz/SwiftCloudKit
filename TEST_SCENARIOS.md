# SwiftCloudKit — Test Scenarios

Production QA-level test scenarios for the SwiftCloudKit framework. A manual tester can follow these scenarios without prior knowledge of the codebase.

---

## Table of Contents

1. [Configuration Tests](#1-configuration-tests)
2. [Account Status Tests](#2-account-status-tests)
3. [Save Record Tests](#3-save-record-tests)
4. [Delete Record Tests](#4-delete-record-tests)
5. [Fetch Record Tests](#5-fetch-record-tests)
6. [Query Records Tests](#6-query-records-tests)
7. [Batch Save Tests](#7-batch-save-tests)
8. [Batch Delete Tests](#8-batch-delete-tests)
9. [Remote Sync Tests](#9-remote-sync-tests)
10. [Conflict Resolution Tests](#10-conflict-resolution-tests)
11. [Retry Policy Tests](#11-retry-policy-tests)
12. [Record Factory Tests](#12-record-factory-tests)
13. [Asset Management Tests](#13-asset-management-tests)
14. [Local Store / Cache Tests](#14-local-store--cache-tests)
15. [Reset & Cleanup Tests](#15-reset--cleanup-tests)
16. [Edge Cases](#16-edge-cases)
17. [Critical Risks](#17-critical-risks)
18. [Technical Debt](#18-technical-debt)
19. [App Store Readiness Checklist](#19-app-store-readiness-checklist)

---

## 1. Configuration Tests

### 1.1 Initial State
- **Test**: Verify unconfigured state
- **Preconditions**: App freshly launched, no prior configuration
- **Steps**:
  1. Access `CloudKitManager.shared.isConfigured`
  2. Access `CloudKitManager.shared.isCloudAvailable`
  3. Access `CloudKitManager.shared.accountStatus`
- **Expected**: `isConfigured == false`, `isCloudAvailable == false`, `accountStatus == .couldNotDetermine`
- **Fail if**: Any property returns an unexpected value

### 1.2 Unconfigured Access Throws
- **Test**: Accessing container/database/zoneID before configuration throws
- **Preconditions**: Manager not configured
- **Steps**:
  1. Try to access `CloudKitManager.shared.container`
  2. Try to access `CloudKitManager.shared.privateDB`
  3. Try to access `CloudKitManager.shared.zoneID`
  4. Try to access `CloudKitManager.shared.configuration`
- **Expected**: Each access throws `CloudKitError.notConfigured`
- **Fail if**: Any access succeeds or throws a different error

### 1.3 Successful Configuration
- **Test**: Configure with valid iCloud account
- **Preconditions**: Device signed into iCloud, valid container identifier in entitlements
- **Steps**:
  1. Create `CloudKitManager.Configuration(containerIdentifier: "iCloud.com.yourapp")`
  2. Call `await CloudKitManager.shared.configureIfPossible(with: config)`
- **Expected**: Returns `true`, `isConfigured == true`, `isCloudAvailable == true`, `accountStatus == .available`
- **Fail if**: Returns `false` on a device with active iCloud account

### 1.4 Configuration Without iCloud Account
- **Test**: Configure when no iCloud account is signed in
- **Preconditions**: Device has no iCloud account signed in
- **Steps**:
  1. Create a valid configuration
  2. Call `configureIfPossible(with: config)`
- **Expected**: Returns `false`, `isCloudAvailable == false`, `lastAccountStatusError` is set, partial config stored for retry
- **Fail if**: Throws or crashes

### 1.5 Retry Configuration
- **Test**: Retry after account becomes available
- **Preconditions**: Configuration previously failed (no account)
- **Steps**:
  1. Sign into iCloud on device
  2. Call `await CloudKitManager.shared.retryConfiguration()`
- **Expected**: Returns `true`, full configuration succeeds
- **Fail if**: Returns `false` despite account being available

### 1.6 Reset Configuration
- **Test**: Reset cleans all state
- **Preconditions**: Manager is configured
- **Steps**:
  1. Call `CloudKitManager.shared.resetConfiguration()`
  2. Check all properties
- **Expected**: `isConfigured == false`, `isCloudAvailable == false`, `accountStatus == .couldNotDetermine`, `lastAccountStatusError == nil`
- **Fail if**: Any residual state remains

### 1.7 Idempotent Reset
- **Test**: Multiple resets don't crash
- **Steps**: Call `resetConfiguration()` 3 times in a row
- **Expected**: No crash, state remains clean

---

## 2. Account Status Tests

### 2.1 Account Status Observer
- **Test**: Observer fires on account change
- **Preconditions**: Manager configured with account observer
- **Steps**:
  1. Sign out of iCloud in Settings
  2. Wait for observer callback
- **Expected**: `isCloudAvailable` becomes `false`, account status updates
- **Fail if**: Status doesn't update within 10 seconds

### 2.2 Account Recovery Triggers Sync
- **Test**: When account becomes available, auto-retry triggers
- **Preconditions**: Initial config failed (no account)
- **Steps**:
  1. Sign into iCloud
  2. Wait for account change notification
- **Expected**: Configuration retries, if successful `fetchRemoteChanges()` is called
- **Fail if**: No retry attempt or crash during retry

---

## 3. Save Record Tests

### 3.1 Save New Record
- **Test**: Create and save a new CKRecord
- **Preconditions**: CloudKit configured and available
- **Steps**:
  1. Create a `CKRecord` with valid type and fields
  2. Call `coordinator.saveRecord(record)`
  3. Verify `isSyncing` transitions: `false -> true -> false`
- **Expected**: No error, record saved to CloudKit, cached locally, `lastSyncDate` updated, `onSyncEvent(.recordSaved)` fired
- **Fail if**: Error thrown, or `isSyncing` stuck at `true`

### 3.2 Save When Not Configured
- **Test**: Save without configuration throws
- **Steps**: Call `saveRecord` on unconfigured coordinator
- **Expected**: Throws `CloudKitError.notConfigured`
- **Fail if**: Doesn't throw

### 3.3 Save With Quota Exceeded
- **Test**: Save when iCloud storage is full
- **Preconditions**: iCloud storage at capacity
- **Steps**: Attempt to save a record with large asset
- **Expected**: Throws `CloudKitError.quotaExceeded`, `lastSyncError` set
- **Fail if**: Silent failure or wrong error

### 3.4 Save Triggers Conflict
- **Test**: Save a record that was modified on another device
- **Preconditions**: Record exists on server with different data
- **Steps**:
  1. Modify record locally
  2. Modify same record on another device (change server version)
  3. Save local record
- **Expected**: Conflict resolution fires — default merge or custom resolver. Resolved record saved.
- **Fail if**: Data loss or error not handled

---

## 4. Delete Record Tests

### 4.1 Delete Existing Record
- **Test**: Delete a record that exists on CloudKit
- **Steps**:
  1. Create a record ID
  2. Call `deleteRecord(recordID)`
- **Expected**: Record deleted from CloudKit, removed from local cache, `onSyncEvent(.recordDeleted)` fired
- **Fail if**: Error thrown for existing record

### 4.2 Delete Non-Existent Record
- **Test**: Delete a record that doesn't exist
- **Steps**: Call `deleteRecord` with unknown record ID
- **Expected**: Gracefully handled (`.unknownItem` error caught), no crash, local cache cleaned
- **Fail if**: Crash or unhandled error

### 4.3 Delete When Not Configured
- **Expected**: Throws `CloudKitError.notConfigured`

---

## 5. Fetch Record Tests

### 5.1 Fetch Existing Record
- **Steps**:
  1. Save a record
  2. Fetch it by record ID
- **Expected**: Returns the saved record, cached locally

### 5.2 Fetch Non-Existent Record
- **Steps**: Fetch with unknown record ID
- **Expected**: Throws appropriate error

### 5.3 Fetch When Not Configured
- **Expected**: Throws `CloudKitError.notConfigured`

---

## 6. Query Records Tests

### 6.1 Query With Results
- **Steps**:
  1. Save multiple records
  2. Query by record type
- **Expected**: All matching records returned, all cached locally

### 6.2 Query With No Results
- **Steps**: Query for a record type with no records
- **Expected**: Empty array, no error

### 6.3 Query With Predicate
- **Steps**: Query with `NSPredicate(format: "field == %@", value)`
- **Expected**: Only matching records returned

### 6.4 Query With Pagination
- **Preconditions**: More than `resultsLimit` records exist
- **Steps**: Query with `resultsLimit: 10`
- **Expected**: All records returned (cursor pagination handles automatically), `isSyncing` returns to `false`

### 6.5 Query When Not Configured
- **Expected**: Throws `CloudKitError.notConfigured`

---

## 7. Batch Save Tests

### 7.1 Batch Save Multiple Records
- **Steps**:
  1. Create 10 records
  2. Call `batchSaveRecords(records)`
- **Expected**: Returns `BatchSaveResult` with all records in `savedRecords`, `hasFailures == false`

### 7.2 Batch Save Empty Array
- **Steps**: Call `batchSaveRecords([])`
- **Expected**: Returns empty result, no error, `hasFailures == false`

### 7.3 Batch Save With Partial Failures
- **Steps**: Save records where some have invalid data
- **Expected**: `hasFailures == true`, `failedRecords` contains the failed ones, `savedRecords` contains the successful ones

### 7.4 Batch Save Large Set (>400 records)
- **Steps**: Create 500 records, batch save
- **Expected**: Chunked correctly (400 + 100), all saved, no records lost

### 7.5 Batch Save When Not Configured
- **Expected**: Throws `CloudKitError.notConfigured`

---

## 8. Batch Delete Tests

### 8.1 Batch Delete Multiple Records
- **Steps**:
  1. Create and save records
  2. Call `batchDeleteRecords(recordIDs)`
- **Expected**: Returns `BatchDeleteResult` with all IDs in `deletedIDs`, `hasFailures == false`

### 8.2 Batch Delete Empty Array
- **Expected**: Returns empty result, no error

### 8.3 Batch Delete Large Set (>400 records)
- **Expected**: Chunked correctly, all deleted

### 8.4 Batch Delete When Not Configured
- **Expected**: Throws `CloudKitError.notConfigured`

---

## 9. Remote Sync Tests

### 9.1 Fetch Remote Changes — No Changes
- **Steps**: Call `fetchRemoteChanges()` when no changes on server
- **Expected**: `syncCompleted(recordCount: 0, deleteCount: 0)`, no error

### 9.2 Fetch Remote Changes — With Modifications
- **Preconditions**: Another device made changes
- **Steps**: Call `fetchRemoteChanges()`
- **Expected**: Modified records dispatched to handlers, cached locally, `syncCompleted` with correct counts

### 9.3 Fetch Remote Changes — With Deletions
- **Steps**: Fetch after records were deleted on another device
- **Expected**: Deleted record IDs dispatched to delete handlers, removed from cache

### 9.4 Token Expiry Recovery
- **Steps**: Trigger sync with expired change token
- **Expected**: Token reset, full re-fetch triggered, new token stored

### 9.5 Repeated Token Expiry
- **Steps**: Token expires more than `maxTokenRefreshDepth` (2) times
- **Expected**: `lastSyncError` set to `syncFailed("Token expired repeatedly")`, sync stops

### 9.6 Concurrent Fetch Prevention
- **Steps**: Call `fetchRemoteChanges()` while already syncing
- **Expected**: Second call returns immediately, no double sync

### 9.7 Push Notification Triggers Sync
- **Steps**: Receive remote notification for subscription
- **Expected**: `fetchRemoteChanges()` called, new data fetched

---

## 10. Conflict Resolution Tests

### 10.1 Default Merge Strategy
- **Steps**: Save a record whose server version changed
- **Expected**: Local values overwrite server values (except dates — latest wins), resolved record saved

### 10.2 Custom Conflict Resolver
- **Steps**:
  1. Set `conflictResolver = { local, server in server }`
  2. Trigger a conflict
- **Expected**: Custom resolver called, server record kept

### 10.3 Date Field Merge
- **Steps**: Conflict where local has older `updated_at` than server
- **Expected**: Server date wins (later date kept)

---

## 11. Retry Policy Tests

### 11.1 Retryable Errors Trigger Retry
- **Test**: Network failure, service unavailable, rate limited
- **Expected**: Operation retried with exponential backoff, succeeds eventually

### 11.2 Non-Retryable Errors Throw Immediately
- **Test**: `.notAuthenticated`, `.permissionFailure`
- **Expected**: Error thrown immediately, no retry

### 11.3 Max Retry Exhaustion
- **Test**: All retries fail
- **Expected**: Last error thrown after `maxRetryCount` attempts

### 11.4 Backoff Timing
- **Test**: Verify delays increase exponentially
- **Expected**: ~1s, ~2s, ~4s (capped at 30s)

---

## 12. Record Factory Tests

### 12.1 Record ID Generation
- **Steps**: `CloudKitRecordFactory.recordID(type: "UserProfile", identifier: "abc123")`
- **Expected**: Record name `"userprofile_abc123"` with correct zone ID

### 12.2 Singleton Record ID
- **Steps**: `CloudKitRecordFactory.singletonRecordID(type: "Settings")`
- **Expected**: Record name `"settings_default"`

### 12.3 Timestamps
- **Steps**: `setTimestamps(record)` on new record
- **Expected**: Both `created_at` and `updated_at` set

### 12.4 Timestamps Preserve created_at
- **Steps**: `setTimestamps` on record with existing `created_at`
- **Expected**: `created_at` unchanged, `updated_at` updated

### 12.5 Touch Timestamp
- **Steps**: `touchTimestamp(record)`
- **Expected**: Only `updated_at` set, `created_at` remains nil

### 12.6 Codable String Encoding/Decoding
- **Steps**: Encode a Codable struct to string field, decode back
- **Expected**: Round-trip produces equal value

### 12.7 Codable Asset Encoding/Decoding
- **Steps**: Encode a Codable struct to asset field, decode back
- **Expected**: Round-trip produces equal value

### 12.8 Missing Field Throws
- **Steps**: Decode from missing field
- **Expected**: Throws `CloudKitRecordFactoryError.missingField`

### 12.9 Invalid JSON Throws
- **Steps**: Decode from string containing invalid JSON
- **Expected**: Throws decoding error

### 12.10 Asset Creation Registers Temp File
- **Steps**: `createAsset(from: data)`
- **Expected**: Temp file created and registered with `CloudKitAssetCleanup`

---

## 13. Asset Management Tests

### 13.1 Register and Cleanup Single File
- **Steps**: Register a temp file, cleanup by identifier
- **Expected**: File removed from disk and tracking set

### 13.2 Cleanup All
- **Steps**: Register multiple files, call `cleanupAll()`
- **Expected**: All files removed, `tempFileCount == 0`

### 13.3 Cleanup Missing File
- **Steps**: Register a non-existent path, call `cleanupAll()`
- **Expected**: No crash

### 13.4 Stale File Cleanup on Init
- **Steps**: Create a temp file with prefix `sck_temp_`, wait >1 hour, restart app
- **Expected**: Stale file cleaned up on `CloudKitAssetCleanup` initialization

### 13.5 Record-Based Cleanup
- **Steps**: Create a CKRecord with a CKAsset, register temp file, call `cleanup(record:)`
- **Expected**: Asset temp file removed from tracking

---

## 14. Local Store / Cache Tests

### 14.1 Cache Round-Trip
- **Steps**: Cache a CKRecord, retrieve it
- **Expected**: Retrieved record matches original type

### 14.2 Remove Cached Record
- **Steps**: Cache then remove a record
- **Expected**: `cachedRecord` returns nil

### 14.3 Remove Non-Existent Record
- **Steps**: Remove a record that was never cached
- **Expected**: No crash

### 14.4 Clear Cache
- **Steps**: Cache multiple records, call `clearCache()`
- **Expected**: All records removed, `cacheSize == 0`

### 14.5 Cache Count Accuracy
- **Steps**: Cache 5 records, check `cachedRecordCount`
- **Expected**: Count >= 5

### 14.6 Special Characters in Record Name
- **Steps**: Cache record with name containing `/` and `:`
- **Expected**: File name sanitized, retrieval works

### 14.7 Change Token Persistence
- **Steps**: Set `serverChangeToken`, retrieve it
- **Expected**: Same token returned

### 14.8 Corrupt Token Handling
- **Steps**: Write invalid data to token storage, retrieve token
- **Expected**: Returns nil, corrupt data removed

### 14.9 Cache Version Invalidation
- **Steps**: Change cache version constant, restart
- **Expected**: Old cache cleared on init

### 14.10 Custom UserDefaults
- **Steps**: Create CloudKitLocalStore with custom UserDefaults suite
- **Expected**: Isolated from shared store, separate token storage

---

## 15. Reset & Cleanup Tests

### 15.1 Full Reset Flow
- **Steps**:
  1. Configure CloudKit
  2. Register handlers
  3. Save records
  4. Call `unregisterAllHandlers()`
  5. Call `resetConfiguration()`
- **Expected**: All state clean, no residual handlers or observers

### 15.2 Handler Unregistration
- **Steps**:
  1. Register handlers for 3 record types
  2. Unregister one
  3. Verify only 2 remain active
- **Expected**: Unregistered type no longer receives callbacks

### 15.3 Handler Re-registration
- **Steps**:
  1. Register handler for type "A"
  2. Register again for same type
- **Expected**: No duplicate entries, new handler replaces old

---

## 16. Edge Cases

### 16.1 Network Loss During Save
- **Steps**: Save record, disable network mid-operation
- **Expected**: Error surfaced, retry attempted if error is retryable

### 16.2 Airplane Mode Configuration
- **Steps**: Enable airplane mode, attempt configuration
- **Expected**: `configureIfPossible` returns `false`, no crash

### 16.3 Very Large Record (near CK limit)
- **Steps**: Save a record with a 1MB asset
- **Expected**: Save succeeds, asset temp file cleaned up

### 16.4 Empty String Fields
- **Steps**: Save record with empty string fields
- **Expected**: Saved correctly, retrieval works

### 16.5 Concurrent Save and Delete
- **Steps**: Save and delete the same record ID simultaneously
- **Expected**: No deadlock, one operation succeeds

### 16.6 Rapid Configuration Toggle
- **Steps**: Configure, reset, configure, reset rapidly
- **Expected**: No crash, final state consistent

---

## 17. Critical Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Force unwrap in BatchSaveResult (removed in refactor) | HIGH | Replaced with safe `as?` cast |
| `isSyncing` stuck at `true` if error not properly handled | HIGH | All error paths set `isSyncing = false` via `failSync` or explicit reset |
| NSLock in `performZoneFetch` could deadlock if callbacks throw | MEDIUM | Callbacks use `try?` which never throws |
| Memory growth with `queryRecords` collecting all pages | MEDIUM | Document limitation; large queries should use server-side limits |
| Stale temp files accumulate if app killed before cleanup | LOW | `cleanStaleTempFiles()` runs on init, cleans files >1 hour old |
| Singleton state leaks between unit tests | MEDIUM | `setUp`/`tearDown` should call `resetConfiguration()` and `unregisterAllHandlers()` |
| Change token corruption causes full re-fetch | LOW | Token decode errors reset the token gracefully |

---

## 18. Technical Debt

| Item | Priority | Notes |
|------|----------|-------|
| No dependency injection — singletons make testing harder | Medium | Consider protocol-based abstractions for `CloudKitManager` and `CloudKitLocalStore` |
| `queryRecords` collects all pages eagerly | Medium | Add `AsyncSequence` variant for streaming results |
| `handleSaveError` has `.unknownItem` retry that re-saves directly | Low | Could loop infinitely if zone is missing |
| No structured logging/metrics hooks for consumers | Low | `onSyncEvent` partially addresses this |
| No background task (`BGTaskScheduler`) integration | Low | Consumer responsibility — document this |
| `CloudKitRecordFactory` depends on `CloudKitManager.shared` | Low | Could accept `zoneID` as parameter instead |
| Test suite doesn't test actual CloudKit operations | Medium | Need CloudKit integration test environment |
| No `Sendable` conformance on `CloudKitManager.Configuration` properties | Low | Already `Sendable` struct — verified |
| Batch operations don't support progress reporting | Low | Could add `onProgress` callback |

---

## 19. App Store Readiness Checklist

### Pre-Release Requirements

- [ ] All entitlements configured (`com.apple.developer.icloud-container-identifiers`, `CloudKit`, `aps-environment`)
- [ ] `Info.plist` contains `UIBackgroundModes` → `remote-notification`
- [ ] Container identifier matches CloudKit Dashboard configuration
- [ ] CloudKit schema deployed to Production environment
- [ ] CloudKit Deployment to Production completed in Dashboard
- [ ] Subscription ID matches between code and CloudKit Dashboard
- [ ] Zone name matches between code and CloudKit Dashboard

### Data Safety

- [ ] No force unwraps in production code paths
- [ ] All error paths surface errors to user (no silent failures)
- [ ] Local cache invalidated on schema version change
- [ ] Change token corruption handled gracefully
- [ ] Temp files cleaned up on app launch
- [ ] Account status changes handled (sign in/out)

### Performance

- [ ] No main thread blocking during sync operations
- [ ] Batch operations chunk at 400 (CloudKit limit)
- [ ] Query results paginated automatically
- [ ] Record cache uses file system (not memory) for scalability
- [ ] Exponential backoff prevents server hammering

### Concurrency

- [ ] All `@Published` properties on `@MainActor`
- [ ] `NSLock` used correctly in `performZoneFetch` callback context
- [ ] No data races on shared mutable state
- [ ] `[weak self]` in notification observer closure
- [ ] `deinit` removes notification observer

### Error Handling

- [ ] `CloudKitError` covers all known failure modes
- [ ] `CloudKitRecordFactoryError` for factory-specific failures
- [ ] `SyncEvent` provides lifecycle visibility
- [ ] Batch results report partial failures
- [ ] Quota exceeded surfaced to consumer (not swallowed)

### Security

- [ ] `NSKeyedArchiver` uses `requiringSecureCoding: true`
- [ ] No credentials or tokens logged
- [ ] Private database used (not public)
- [ ] No sensitive data in temp file names

### Compatibility

- [ ] iOS 17+ deployment target verified
- [ ] macOS 14+ deployment target verified
- [ ] Swift 5.9+ compatibility
- [ ] No deprecated CloudKit APIs used
- [ ] `@preconcurrency import CloudKit` for Swift 6 forward compatibility
