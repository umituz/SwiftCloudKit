//
//  CloudKitLocalStore.swift
//  Generic CloudKit Local Store
//
//  Created for generic CloudKit integration across all projects
//  Reference: CLOUDKIT_STRUCTURE_FOR_OTHER_PROJECTS.md
//

import CloudKit
import Foundation

/// CloudKit local store - handles change token persistence and record caching
public final class CloudKitLocalStore {

    // MARK: - Singleton

    public static let shared = CloudKitLocalStore()

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    private let changeTokenKey = "CloudKitServerChangeToken"
    private let cacheDirectory: URL

    // MARK: - Initialization

    private init() {
        self.userDefaults = .standard
        self.fileManager = .default

        // Setup cache directory
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = cachesURL.appendingPathComponent("CloudKitRecordCache")

        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Change Token Persistence

    /// Persist server change token using NSKeyedArchiver
    public var serverChangeToken: CKServerChangeToken? {
        get {
            guard let data = userDefaults.data(forKey: changeTokenKey) else {
                return nil
            }

            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
            } catch {
                // Token could not be unarchived - might be from a different OS version
                // Delete the stale token
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
                    print("Failed to archive change token: \(error)")
                }
            } else {
                userDefaults.removeObject(forKey: changeTokenKey)
            }
        }
    }

    // MARK: - Record Cache

    /// Cache a CKRecord to local storage
    public func cacheRecord(_ record: CKRecord) {
        let fileName = record.recordID.recordName.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).archive")

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            try data.write(to: fileURL)
        } catch {
            print("Failed to cache record: \(error)")
        }
    }

    /// Retrieve a cached CKRecord
    public func cachedRecord(recordName: String) -> CKRecord? {
        let fileName = recordName.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).archive")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        } catch {
            // Cache read failed - delete stale cache
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    /// Remove a cached record
    public func removeCachedRecord(recordName: String) {
        let fileName = recordName.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent("\(fileName).archive")

        try? fileManager.removeItem(at: fileURL)
    }

    /// Clear all cached records
    public func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Utility

    /// Get cache size in bytes
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

    /// Get cache size formatted as string
    public var cacheSizeFormatted: String {
        let bytes = cacheSize
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
