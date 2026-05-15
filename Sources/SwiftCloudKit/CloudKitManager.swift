//
//  CloudKitManager.swift
//  SwiftCloudKit
//
//  Configurable CloudKit manager for container lifecycle, zones, subscriptions, and account monitoring.
//

@preconcurrency import CloudKit
import Foundation
import os.log

/// Main CloudKit manager — handles container lifecycle, zones, subscriptions, and account monitoring.
///
/// Configure via ``configure(with:)`` or ``configureIfPossible(with:)`` before performing
/// CloudKit operations. Access computed properties (`container`, `privateDB`, `zoneID`,
/// `configuration`) only after successful configuration; they will throw
/// ``CloudKitError/notConfigured`` if accessed prematurely.
@MainActor
public final class CloudKitManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = CloudKitManager()

    // MARK: - Configuration

    public struct Configuration: Sendable {
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

    /// Whether CloudKit is available and configured. Use this for offline-first UI decisions.
    @Published public private(set) var isCloudAvailable = false

    // MARK: - Stored Properties

    private var ckContainer: CKContainer?
    private var ckPrivateDatabase: CKDatabase?
    private var ckZoneID: CKRecordZone.ID?
    private var storedConfiguration: Configuration?

    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public private(set) var lastAccountStatusError: Error?
    @Published public private(set) var isConfigured = false

    private nonisolated(unsafe) var accountStatusObserver: NSObjectProtocol?

    private let logger = Logger(subsystem: "SwiftCloudKit", category: "CloudKitManager")

    // MARK: - Computed Properties

    /// The configured CKContainer. Throws ``CloudKitError/notConfigured`` if called before configuration.
    public var container: CKContainer {
        get throws {
            guard let container = ckContainer else {
                throw CloudKitError.notConfigured
            }
            return container
        }
    }

    /// The private CloudKit database. Throws ``CloudKitError/notConfigured`` if called before configuration.
    public var privateDB: CKDatabase {
        get throws {
            guard let database = ckPrivateDatabase else {
                throw CloudKitError.notConfigured
            }
            return database
        }
    }

    /// The custom zone ID. Throws ``CloudKitError/notConfigured`` if called before configuration.
    public var zoneID: CKRecordZone.ID {
        get throws {
            guard let zone = ckZoneID else {
                throw CloudKitError.notConfigured
            }
            return zone
        }
    }

    /// The active configuration. Throws ``CloudKitError/notConfigured`` if called before configuration.
    public var configuration: Configuration {
        get throws {
            guard let config = storedConfiguration else {
                throw CloudKitError.notConfigured
            }
            return config
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Configuration

    /// Configure CloudKit with app-specific settings. Throws if iCloud account is unavailable.
    ///
    /// Call early in the app lifecycle (e.g. `App.init` or `AppDelegate`).
    public func configure(with config: Configuration) async throws {
        storedConfiguration = config
        let container = CKContainer(identifier: config.containerIdentifier)
        ckContainer = container
        ckPrivateDatabase = container.privateCloudDatabase
        ckZoneID = CKRecordZone.ID(
            zoneName: config.zoneName,
            ownerName: CKCurrentUserDefaultName
        )

        // 1. Check account status
        try await checkAccountStatus()

        // 2. Ensure custom zone exists
        try await ensureCustomZoneExists()

        // 3. Ensure database subscription
        try await ensureDatabaseSubscriptionExists()

        // 4. Start monitoring account status changes
        setupAccountStatusObserver()

        isConfigured = true
        isCloudAvailable = true

        logger.info("CloudKit configured for container: \(config.containerIdentifier)")
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

            // Store partial config so we can retry when account becomes available
            if storedConfiguration == nil {
                storedConfiguration = config
                let container = CKContainer(identifier: config.containerIdentifier)
                ckContainer = container
                ckPrivateDatabase = container.privateCloudDatabase
                ckZoneID = CKRecordZone.ID(
                    zoneName: config.zoneName,
                    ownerName: CKCurrentUserDefaultName
                )
                setupAccountStatusObserver()
            }

            logger.warning("CloudKit configuration deferred: \(error.localizedDescription)")
            return false
        }
    }

    /// Retry configuration after a previous failure (e.g. when iCloud account becomes available).
    public func retryConfiguration() async -> Bool {
        guard let config = storedConfiguration else { return false }
        return await configureIfPossible(with: config)
    }

    /// Reset CloudKitManager to its unconfigured state.
    /// Call this on logout or when switching CloudKit containers.
    public func resetConfiguration() {
        if let observer = accountStatusObserver {
            NotificationCenter.default.removeObserver(observer)
            accountStatusObserver = nil
        }

        ckContainer = nil
        ckPrivateDatabase = nil
        ckZoneID = nil
        storedConfiguration = nil
        isConfigured = false
        isCloudAvailable = false
        accountStatus = .couldNotDetermine
        lastAccountStatusError = nil

        logger.info("CloudKit configuration reset")
    }

    // MARK: - Account Status

    private func checkAccountStatus() async throws {
        _ = try privateDB
        let ckContainer = try container
        let status = try await ckContainer.accountStatus()
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
            let ckContainer = try container
            let status = try await ckContainer.accountStatus()
            accountStatus = status

            if status == .available && !isConfigured {
                let success = await retryConfiguration()
                if success {
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
        let database = try privateDB
        let zone = try zoneID

        do {
            _ = try await database.recordZone(for: zone)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            try await createCustomZone()
        }
    }

    private func createCustomZone() async throws {
        let database = try privateDB
        let zone = try zoneID
        let recordZone = CKRecordZone(zoneID: zone)
        _ = try await database.save(recordZone)
        logger.info("Created custom zone: \(zone.zoneName)")
    }

    // MARK: - Subscription Management

    private func ensureDatabaseSubscriptionExists() async throws {
        let database = try privateDB
        let subID = try configuration.subscriptionID

        do {
            let results = try await database.subscriptions(for: [subID])
            if results[subID] != nil { return }
        } catch {
            logger.debug("Could not fetch subscriptions: \(error.localizedDescription)")
        }

        try await createDatabaseSubscription()
    }

    private func createDatabaseSubscription() async throws {
        let database = try privateDB
        let subID = try configuration.subscriptionID

        let subscription = CKDatabaseSubscription(subscriptionID: subID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        _ = try await database.save(subscription)
        logger.info("Created database subscription: \(subID)")
    }

    // MARK: - Deinitialization

    deinit {
        if let observer = accountStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Errors

public enum CloudKitError: LocalizedError, Sendable {
    case noAccount
    case restricted
    case accountStatusUnknown
    case accountTemporarilyUnavailable
    case zoneNotFound
    case quotaExceeded
    case networkFailure
    case notConfigured
    case syncFailed(String)
    case recordNotFound

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
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        case .recordNotFound:
            return "Record not found."
        }
    }
}
