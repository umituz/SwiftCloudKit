//
//  CloudKitManager.swift
//  SwiftCloudKit
//
//  Configurable CloudKit manager for container lifecycle, zones, subscriptions, and account monitoring.
//

import CloudKit
import Foundation

/// Main CloudKit manager - handles container lifecycle, zones, subscriptions, and account monitoring.
/// Must be configured via `configure(with:)` before any CloudKit operations.
@MainActor
public final class CloudKitManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = CloudKitManager()

    // MARK: - Configuration

    public struct Configuration {
        public let containerIdentifier: String
        public let zoneName: String
        public let subscriptionID: String

        public init(
            containerIdentifier: String,
            zoneName: String = "AppData",
            subscriptionID: String = "app-database-changes"
        ) {
            self.containerIdentifier = containerIdentifier
            self.zoneName = zoneName
            self.subscriptionID = subscriptionID
        }
    }

    // MARK: - CloudKit Availability

    /// Whether CloudKit is available and configured. App can use this to work offline gracefully.
    @Published public private(set) var isCloudAvailable = false

    // MARK: - Stored Properties

    private var _container: CKContainer?
    private var _privateDB: CKDatabase?
    private var _zoneID: CKRecordZone.ID?
    private var _configuration: Configuration?

    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public private(set) var lastAccountStatusError: Error?
    @Published public private(set) var isConfigured = false

    private var accountStatusObserver: NSObjectProtocol?

    // MARK: - Computed Properties

    public var container: CKContainer {
        guard let container = _container else {
            fatalError("CloudKitManager.configure(with:) must be called before accessing container.")
        }
        return container
    }

    public var privateDB: CKDatabase {
        guard let db = _privateDB else {
            fatalError("CloudKitManager.configure(with:) must be called before accessing privateDB.")
        }
        return db
    }

    public var zoneID: CKRecordZone.ID {
        guard let id = _zoneID else {
            fatalError("CloudKitManager.configure(with:) must be called before accessing zoneID.")
        }
        return id
    }

    public var configuration: Configuration {
        guard let config = _configuration else {
            fatalError("CloudKitManager.configure(with:) must be called before accessing configuration.")
        }
        return config
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Configure CloudKit with app-specific settings. Throws if iCloud account is unavailable.
    /// Call this early in app lifecycle (e.g. in App.init or AppDelegate).
    public func configure(with config: Configuration) async throws {
        _configuration = config
        _container = CKContainer(identifier: config.containerIdentifier)
        _privateDB = _container!.privateCloudDatabase
        _zoneID = CKRecordZone.ID(zoneName: config.zoneName, ownerName: CKCurrentUserDefaultName)

        // 1. Check account status
        try await checkAccountStatus()

        // 2. Ensure custom zone exists
        try await ensureCustomZoneExists()

        // 3. Ensure database subscription
        try await ensureDatabaseSubscriptionExists()

        // 4. Start monitoring account status changes (guard against duplicates)
        setupAccountStatusObserver()

        isConfigured = true
        isCloudAvailable = true
    }

    /// Attempt to configure CloudKit without throwing. Suitable for local-first apps
    /// that should work even when iCloud is unavailable.
    /// - Returns: `true` if configuration succeeded, `false` if CloudKit is unavailable.
    @discardableResult
    public func configureIfPossible(with config: Configuration) async -> Bool {
        do {
            try await configure(with: config)
            return true
        } catch {
            lastAccountStatusError = error
            isCloudAvailable = false

            // Still store config so we can retry later when account becomes available
            if _configuration == nil {
                _configuration = config
                _container = CKContainer(identifier: config.containerIdentifier)
                _privateDB = _container!.privateCloudDatabase
                _zoneID = CKRecordZone.ID(zoneName: config.zoneName, ownerName: CKCurrentUserDefaultName)
                setupAccountStatusObserver()
            }

            return false
        }
    }

    /// Retry configuration after a previous failure (e.g. when iCloud account becomes available).
    public func retryConfiguration() async -> Bool {
        guard let config = _configuration else { return false }
        return await configureIfPossible(with: config)
    }

    // MARK: - Account Status

    private func checkAccountStatus() async throws {
        let status = try await container.accountStatus()
        accountStatus = status

        switch status {
        case .available:
            return
        case .noAccount:
            isCloudAvailable = false
            throw CloudKitError.noAccount
        case .restricted:
            isCloudAvailable = false
            throw CloudKitError.restricted
        case .couldNotDetermine:
            isCloudAvailable = false
            throw CloudKitError.accountStatusUnknown
        case .temporarilyUnavailable:
            isCloudAvailable = false
            throw CloudKitError.accountTemporarilyUnavailable
        @unknown default:
            isCloudAvailable = false
            throw CloudKitError.accountStatusUnknown
        }
    }

    private func setupAccountStatusObserver() {
        // Guard against registering multiple observers
        guard accountStatusObserver == nil else { return }

        accountStatusObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAccountStatusChanged()
            }
        }
    }

    private func handleAccountStatusChanged() async {
        do {
            let status = try await container.accountStatus()
            accountStatus = status

            if status == .available && !isConfigured {
                // Account became available - try to configure
                let success = await retryConfiguration()
                if success {
                    // Trigger a sync of remote changes
                    await CloudKitSyncCoordinator.shared.fetchRemoteChanges()
                }
            } else if status == .available {
                isCloudAvailable = true
            } else {
                isCloudAvailable = false
            }
        } catch {
            lastAccountStatusError = error
            isCloudAvailable = false
        }
    }

    // MARK: - Zone Management

    private func ensureCustomZoneExists() async throws {
        do {
            _ = try await privateDB.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            try await createCustomZone()
        }
    }

    private func createCustomZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await privateDB.save(zone)
    }

    // MARK: - Subscription Management

    private func ensureDatabaseSubscriptionExists() async throws {
        let subscriptionID = configuration.subscriptionID

        do {
            let results = try await privateDB.subscriptions(for: [subscriptionID])
            if results[subscriptionID] != nil { return }
        } catch {
            // Fetch failed - try to create
        }

        try await createDatabaseSubscription()
    }

    private func createDatabaseSubscription() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: configuration.subscriptionID)
        subscription.recordType = nil

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        _ = try await privateDB.save(subscription)
    }

    // MARK: - Deinitialization

    deinit {
        if let observer = accountStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Errors

public enum CloudKitError: LocalizedError {
    case noAccount
    case restricted
    case accountStatusUnknown
    case accountTemporarilyUnavailable
    case zoneNotFound
    case quotaExceeded
    case networkFailure
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .noAccount:
            return "No iCloud account is signed in."
        case .restricted:
            return "iCloud access is restricted."
        case .accountStatusUnknown:
            return "Could not determine iCloud account status."
        case .accountTemporarilyUnavailable:
            return "iCloud is temporarily unavailable."
        case .zoneNotFound:
            return "CloudKit zone not found."
        case .quotaExceeded:
            return "iCloud storage quota exceeded."
        case .networkFailure:
            return "Network connection failed."
        case .notConfigured:
            return "CloudKit has not been configured."
        }
    }
}
