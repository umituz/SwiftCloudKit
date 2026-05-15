//
//  CloudKitRecordFactory.swift
//  SwiftCloudKit
//
//  Generic utilities for CloudKit record creation and manipulation.
//  Each app should create its own record factory extension or wrapper.
//

import CloudKit
import Foundation
import os.log

/// Generic CloudKit record factory utilities.
/// Provides shared helpers for record creation, ID generation, timestamps, and asset handling.
public enum CloudKitRecordFactory {

    // MARK: - Zone ID

    /// Get the shared zone ID from CloudKitManager.
    @MainActor
    public static var zoneID: CKRecordZone.ID {
        get throws {
            try CloudKitManager.shared.zoneID
        }
    }

    // MARK: - Record ID Generation

    /// Generate a record ID with the "type_identifier" naming convention.
    @MainActor
    public static func recordID(type: String, identifier: String) throws -> CKRecord.ID {
        return CKRecord.ID(recordName: "\(type.lowercased())_\(identifier)", zoneID: try zoneID)
    }

    /// Generate a singleton record ID (one per user per type).
    @MainActor
    public static func singletonRecordID(type: String) throws -> CKRecord.ID {
        return CKRecord.ID(recordName: "\(type.lowercased())_default", zoneID: try zoneID)
    }

    // MARK: - Timestamps

    /// Set `created_at` and `updated_at` on a record.
    /// Only sets `created_at` if it is not already present.
    public static func setTimestamps(_ record: CKRecord) {
        let now = Date()
        if record["created_at"] == nil {
            record["created_at"] = now
        }
        record["updated_at"] = now
    }

    /// Update only the `updated_at` timestamp.
    public static func touchTimestamp(_ record: CKRecord) {
        record["updated_at"] = Date()
    }

    // MARK: - Asset Helpers

    /// Create a CKAsset from Data with temp file registration for cleanup.
    @MainActor
    public static func createAsset(from data: Data) throws -> CKAsset {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(CloudKitAssetCleanup.filePrefix)\(UUID().uuidString)"
        let fileURL = tempDir.appendingPathComponent(fileName)

        try data.write(to: fileURL)
        CloudKitAssetCleanup.shared.registerTempFile(fileURL)

        return CKAsset(fileURL: fileURL)
    }

    /// Create a CKAsset from a file URL with temp file registration.
    @MainActor
    public static func createAsset(from url: URL) throws -> CKAsset {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(CloudKitAssetCleanup.filePrefix)\(UUID().uuidString)"
        let tempURL = tempDir.appendingPathComponent(fileName)

        try FileManager.default.copyItem(at: url, to: tempURL)
        CloudKitAssetCleanup.shared.registerTempFile(tempURL)

        return CKAsset(fileURL: tempURL)
    }

    /// Extract Data from a CKAsset.
    public static func data(from asset: CKAsset) throws -> Data {
        guard let fileURL = asset.fileURL else {
            throw CloudKitRecordFactoryError.invalidAssetURL
        }
        return try Data(contentsOf: fileURL)
    }

    // MARK: - Codable Helpers

    /// Encode a Codable object to Data and store as a CKAsset field.
    @MainActor
    public static func encodeToAsset<T: Encodable>(_ value: T, field: String, record: CKRecord) throws {
        let data = try JSONEncoder().encode(value)
        let asset = try createAsset(from: data)
        record[field] = asset
    }

    /// Decode a Codable object from a CKAsset field.
    /// Returns `nil` if the field is missing or contains invalid data.
    public static func decodeFromAsset<T: Decodable>(_ type: T.Type, field: String, record: CKRecord) -> T? {
        guard let asset = record[field] as? CKAsset else { return nil }
        do {
            let data = try data(from: asset)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }

    /// Store a Codable value as a JSON string field.
    public static func encodeToString<T: Encodable>(_ value: T, field: String, record: CKRecord) throws {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CloudKitRecordFactoryError.encodingFailed
        }
        record[field] = string
    }

    /// Decode a Codable value from a JSON string field.
    /// Returns `nil` if the field is missing or contains invalid data.
    public static func decodeFromString<T: Decodable>(_ type: T.Type, field: String, record: CKRecord) -> T? {
        guard let string = record[field] as? String,
              let data = string.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Errors

public enum CloudKitRecordFactoryError: LocalizedError, Sendable {
    case invalidAssetURL
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidAssetURL:
            return "CKAsset has no valid file URL."
        case .encodingFailed:
            return "Failed to encode value to UTF-8 string."
        }
    }
}
