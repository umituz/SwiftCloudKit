//
//  CloudKitLocalStore.swift
//  SwiftCloudKit
//
//  Handles change token persistence and record caching.
//

import CloudKit
import Foundation

/// CloudKit local store - handles change token persistence and record caching.
public final class CloudKitLocalStore {

    // MARK: - Singleton

    public static let shared = CloudKitLocalStore()

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    private let changeTokenKey = "SwiftCloudKit_ServerChangeToken"
    private let cacheDirectory: URL

    // MARK: - Initialization

    private init() {
        self.userDefaults = .standard
        self.fileManager = .default

        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = cachesURL.appendingPathComponent("SwiftCloudKit_RecordCache")

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Change Token Persistence

    /// Persist and retrieve the server change token for incremental fetches.
    public var serverChangeToken: CKServerChangeToken? {
        get {
            guard let data = userDefaults.data(forKey: changeTokenKey) else {
                return nil
            }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
            } catch {
                // Stale token from a different OS version - delete it
                userDefaults.removeObject(forKey: changeTokenKey)
                return nil
            }
        }
        set {
            if let token = newValue {
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                    userDefaults.set(data, forKey: changeTokenKey)
                } catch {
                    print("[SwiftCloudKit] Failed to archive change token: \(error)")
                }
            } else {
                userDefaults.removeObject(forKey: changeTokenKey)
            }
        }
    }

    // MARK: - Record Cache

    /// Cache a CKRecord to local file storage.
    public func cacheRecord(_ record: CKRecord) {
        let fileName = record.recordID.recordName.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).cache")

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            try data.write(to: fileURL)
        } catch {
            print("[SwiftCloudKit] Failed to cache record: \(error)")
        }
    }

    /// Retrieve a cached CKRecord by record name.
    public func cachedRecord(recordName: String) -> CKRecord? {
        let fileName = recordName.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).cache")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        } catch {
            // Stale cache - delete and return nil
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    /// Remove a cached record by record name.
    public func removeCachedRecord(recordName: String) {
        let fileName = recordName.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).cache")
        try? fileManager.removeItem(at: fileURL)
    }

    /// Clear all cached records.
    public func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Utility

    /// Total cache size in bytes.
    public var cacheSize: Int64 {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
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
}
