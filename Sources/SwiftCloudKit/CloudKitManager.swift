//
//  CloudKitManager.swift
//  Generic CloudKit Manager
//
//  Created for generic CloudKit integration across all projects
//  Reference: CLOUDKIT_STRUCTURE_FOR_OTHER_PROJECTS.md
//

import CloudKit
import Foundation

/// Main CloudKit manager - handles container lifecycle, zones, subscriptions, and account monitoring
@MainActor
public final class CloudKitManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = CloudKitManager()

    // MARK: - Properties

    public let container: CKContainer
    public let privateDB: CKDatabase
    public let zoneID: CKRecordZone.ID

    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public private(set) var lastAccountStatusError: Error?

    private var accountStatusObserver: NSObjectProtocol?

    // MARK: - Configuration

    public struct Configuration {
        let containerIdentifier: String
        let zoneName: String
        let subscriptionID: String

        public init(containerIdentifier: String, zoneName: String = "AppData", subscriptionID: String = "app-database-changes") {
            self.containerIdentifier = containerIdentifier
            self.zoneName = zoneName
            self.subscriptionID = subscriptionID
        }
    }

    private let configuration: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration? = nil) {
        // Use default configuration or custom
        if let config = configuration {
            self.configuration = config
        } else {
            // Default configuration - should be overridden per project
            self.configuration = Configuration(
                containerIdentifier: "iCloud.com.umituz.app",
                zoneName: "AppData",
                subscriptionID: "app-database-changes"
            )
        }

        // Initialize container
        self.container = CKContainer(identifier: self.configuration.containerIdentifier)
        self.privateDB = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: self.configuration.zoneName, ownerName: CKCurrentUserDefaultName)

        super.init()

        // Start monitoring account status changes
        setupAccountStatusObserver()
    }

    // MARK: - Public Methods

    /// Configure CloudKit - must be called before any CloudKit operations
    public func configure() async throws {
        // 1. Check account status - fail fast if unavailable
        try await checkAccountStatus()

        // 2. Ensure custom zone exists
        try await ensureCustomZoneExists()

        // 3. Ensure database subscription (push notifications)
        try await ensureDatabaseSubscriptionExists()

        // 4. Start monitoring account status changes
        startMonitoringAccountStatus()
    }

    // MARK: - Account Status

    private func checkAccountStatus() async throws {
        let status = try await container.accountStatus()
        self.accountStatus = status

        switch status {
        case .available:
            return // Account available, continue
        case .noAccount:
            throw CloudKitError.noAccount
        case .restricted:
            throw CloudKitError.restricted
        case .couldNotDetermine:
            throw CloudKitError.accountStatusUnknown
        case .temporarilyUnavailable:
            throw CloudKitError.accountTemporarilyUnavailable
        @unknown default:
            throw CloudKitError.accountStatusUnknown
        }
    }

    private func setupAccountStatusObserver() {
        accountStatusObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAccountStatusChanged()
            }
        }
    }

    private func startMonitoringAccountStatus() {
        // Account status observer is already set up in setupAccountStatusObserver()
    }

    private func handleAccountStatusChanged() async {
        do {
            try await checkAccountStatus()

            // If account became available, re-configure
            if accountStatus == .available {
                try? await configure()
            }
        } catch {
            self.lastAccountStatusError = error
        }
    }

    // MARK: - Zone Management

    private func ensureCustomZoneExists() async throws {
        let fetchRecordZonesOperation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])

        var zoneExists = false

        fetchRecordZonesOperation.perRecordZoneCompletionBlock = { zoneID, error in
            if let error = error {
                let ckError = error as? CKError
                if ckError?.code == .unknownItem {
                    // Zone doesn't exist - will create it
                    zoneExists = false
                } else {
                    // Some other error
                    return
                }
            } else {
                // Zone exists
                zoneExists = true
            }
        }

        await withCheckedContinuation { continuation in
            fetchRecordZonesOperation.completionBlock = {
                continuation.resume()
            }
            privateDB.add(fetchRecordZonesOperation)
        }

        if !zoneExists {
            try await createCustomZone()
        }
    }

    private func createCustomZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: [])

        try await withCheckedThrowingContinuation { continuation in
            createZoneOperation.modifyRecordZonesCompletionBlock = { savedZones, deletedZoneIDs, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            privateDB.add(createZoneOperation)
        }
    }

    // MARK: - Subscription Management

    private func ensureDatabaseSubscriptionExists() async throws {
        let subscriptionID = configuration.subscriptionID
        let fetchSubscriptionsOperation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])

        var subscriptionExists = false

        fetchSubscriptionsOperation.perSubscriptionCompletionBlock = { subscriptionID, error in
            if let error = error {
                let ckError = error as? CKError
                if ckError?.code == .unknownItem {
                    // Subscription doesn't exist - will create it
                    subscriptionExists = false
                } else {
                    // Some other error
                    return
                }
            } else {
                // Subscription exists
                subscriptionExists = true
            }
        }

        await withCheckedContinuation { continuation in
            fetchSubscriptionsOperation.completionBlock = {
                continuation.resume()
            }
            privateDB.add(fetchSubscriptionsOperation)
        }

        if !subscriptionExists {
            try await createDatabaseSubscription()
        }
    }

    private func createDatabaseSubscription() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: configuration.subscriptionID)
        subscription.recordType = nil // All record types in zone

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // Silent push
        subscription.notificationInfo = notificationInfo

        let createSubscriptionOperation = CKModifySubscriptionsOperation(
            subscriptionsToSave: [subscription],
            subscriptionIDsToDelete: []
        )

        try await withCheckedThrowingContinuation { continuation in
            createSubscriptionOperation.modifySubscriptionsCompletionBlock = { savedSubscriptions, deletedSubscriptionIDs, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            privateDB.add(createSubscriptionOperation)
        }
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
        }
    }
}
