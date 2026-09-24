import Compression
import CryptoKit
import Darwin
import Foundation

enum ModelStorage {
    private struct Manifest: Decodable {
        let modelSHA256: String
        let modelBytes: UInt64
        let configSHA256: String
    }

    private enum StorageError: LocalizedError {
        case invalidManifest
        case checksumMismatch
        case sizeMismatch
        case cannotCreateFile

        var errorDescription: String? {
            switch self {
            case .invalidManifest: "The bundled model manifest is invalid."
            case .checksumMismatch: "The bundled model did not pass its checksum check."
            case .sizeMismatch: "The bundled model has the wrong size."
            case .cannotCreateFile: "The extracted model file could not be created."
            }
        }
    }

    private static let lock = NSLock()
    private static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("model", isDirectory: true)
    }

    static var isBundled: Bool {
        guard let directory = bundledDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors.xz").path)
    }

    static func prepareBundledModel() throws -> String? {
        guard let bundledDirectory, isBundled else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let manifestURL = bundledDirectory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.modelSHA256.count == 64,
              manifest.configSHA256.count == 64,
              manifest.modelSHA256.allSatisfy(\.isHexDigit),
              manifest.configSHA256.allSatisfy(\.isHexDigit),
              manifest.modelBytes > 0 else { throw StorageError.invalidManifest }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Nemo/Models", isDirectory: true)
        let destination = root.appendingPathComponent("\(manifest.modelSHA256)-\(manifest.configSHA256)", isDirectory: true)
        let modelURL = destination.appendingPathComponent("model.safetensors")
        let configURL = destination.appendingPathComponent("config.json")
        let config = try Data(contentsOf: bundledDirectory.appendingPathComponent("config.json"))
        guard checksum(config) == manifest.configSHA256 else { throw StorageError.checksumMismatch }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".prepare.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".preparing-") {
            try? FileManager.default.removeItem(at: entry)
        }

        if FileManager.default.fileExists(atPath: modelURL.path),
           let size = try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber,
           size.uint64Value == manifest.modelBytes,
           (try? Data(contentsOf: configURL)) == config {
            return destination.path
        }

        let staging = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try config.write(to: staging.appendingPathComponent("config.json"))

        let outputURL = staging.appendingPathComponent("model.safetensors")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw StorageError.cannotCreateFile }
        let source = try FileHandle(forReadingFrom: bundledDirectory.appendingPathComponent("model.safetensors.xz"))
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? source.close()
            try? output.close()
        }
        let filter = try InputFilter<Data>(.decompress, using: .lzma, bufferCapacity: 256 * 1024) { count in
            guard let data = try source.read(upToCount: count), !data.isEmpty else { return nil }
            return data
        }
        var digest = SHA256()
        var bytes: UInt64 = 0
        while let data = try filter.readData(ofLength: 256 * 1024) {
            bytes += UInt64(data.count)
            guard bytes <= manifest.modelBytes else { throw StorageError.sizeMismatch }
            digest.update(data: data)
            try output.write(contentsOf: data)
        }
        guard bytes == manifest.modelBytes else { throw StorageError.sizeMismatch }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.modelSHA256 else {
            throw StorageError.checksumMismatch
        }
        try output.synchronize()

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination.path
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
