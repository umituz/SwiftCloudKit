import CloudKit
import Foundation
import os.log

/// CloudKit local store — handles change token persistence and record caching.
///
/// Uses the shared singleton by default. For testing, create an instance with a custom `UserDefaults` suite.
@MainActor
public final class CloudKitLocalStore {

    // MARK: - Singleton

    public static let shared = CloudKitLocalStore()

    // MARK: - Constants

    private static let changeTokenKey = "SwiftCloudKit_ServerChangeToken"
    private static let cacheDirectoryName = "SwiftCloudKit_RecordCache"
    private static let cacheVersionKey = "SwiftCloudKit_CacheVersion"
    private static let currentCacheVersion = 1

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let logger = Logger(subsystem: "SwiftCloudKit", category: "LocalStore")

    // MARK: - Initialization

    /// Create with custom UserDefaults and FileManager for testing or isolated storage.
    public init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager

        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            logger.critical("Caches directory unavailable — using temporary fallback")
            self.cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent(Self.cacheDirectoryName)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            validateCacheVersion()
            return
        }
        self.cacheDirectory = cachesURL.appendingPathComponent(Self.cacheDirectoryName)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        validateCacheVersion()
    }

    // MARK: - Change Token Persistence

    /// Persist and retrieve the server change token for incremental fetches.
    public var serverChangeToken: CKServerChangeToken? {
        get {
            guard let data = userDefaults.data(forKey: Self.changeTokenKey) else {
                return nil
            }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
            } catch {
                logger.warning("Failed to decode change token, resetting: \(error.localizedDescription)")
                userDefaults.removeObject(forKey: Self.changeTokenKey)
                return nil
            }
        }
        set {
            if let token = newValue {
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                    userDefaults.set(data, forKey: Self.changeTokenKey)
                } catch {
                    logger.error("Failed to archive change token: \(error.localizedDescription)")
                }
            } else {
                userDefaults.removeObject(forKey: Self.changeTokenKey)
            }
        }
    }

    // MARK: - Record Cache

    /// Cache a CKRecord to local file storage.
    /// - Returns: `true` if caching succeeded.
    @discardableResult
    public func cacheRecord(_ record: CKRecord) -> Bool {
        let fileName = sanitizedFileName(record.recordID.recordName)
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).cache")

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            try data.write(to: fileURL)
            return true
        } catch {
            logger.error("Failed to cache record \(record.recordID.recordName): \(error.localizedDescription)")
            return false
        }
    }

    /// Retrieve a cached CKRecord by record name.
    public func cachedRecord(recordName: String) -> CKRecord? {
        let fileName = sanitizedFileName(recordName)
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).cache")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        } catch {
            logger.warning("Stale cache for \(recordName), removing: \(error.localizedDescription)")
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    /// Remove a cached record by record name.
    public func removeCachedRecord(recordName: String) {
        let fileName = sanitizedFileName(recordName)
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).cache")
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            // File may already be gone — not an error
        }
    }

    /// Clear all cached records.
    public func clearCache() {
        do {
            try fileManager.removeItem(at: cacheDirectory)
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            userDefaults.set(Self.currentCacheVersion, forKey: Self.cacheVersionKey)
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Utility

    /// Total cache size in bytes.
    public var cacheSize: Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }

    /// Number of cached records.
    public var cachedRecordCount: Int {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "cache" }.count
    }

    // MARK: - Private

    private func sanitizedFileName(_ recordName: String) -> String {
        recordName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Invalidate cache if the schema version changed between app updates.
    private func validateCacheVersion() {
        let storedVersion = userDefaults.integer(forKey: Self.cacheVersionKey)
        if storedVersion != Self.currentCacheVersion {
            clearCache()
        }
    }
}
