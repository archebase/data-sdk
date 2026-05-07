import DGWControlPlane
import Foundation

/// Actor responsible for loading and atomically replacing `archebase-config.json`.
public actor ArchebaseConfigStore {
    private let configURL: URL
    private let fileManager: FileManager

    /// Creates a store bound to one configuration file URL.
    public init(configURL: URL, fileManager: FileManager = .default) {
        self.configURL = configURL.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Returns whether the configuration file currently exists.
    public func exists() -> Bool {
        self.fileManager.fileExists(atPath: self.configURL.path())
    }

    /// Returns the standardized configuration file URL used by this store.
    public func resolvedConfigURL() -> URL {
        self.configURL
    }

    /// Loads and validates the current device configuration.
    public func load() throws -> ArchebaseConfig {
        guard self.exists() else {
            throw DataGatewayClientError.notInitialized(configURL: self.configURL)
        }
        do {
            return try ArchebaseConfig.decodeValidated(from: Data(contentsOf: self.configURL))
        } catch let error as DataGatewayClientError {
            throw error
        } catch {
            throw DataGatewayClientError.invalidConfiguration("failed to load archebase config: \(error.localizedDescription)")
        }
    }

    /// Writes the initial device configuration, rejecting an existing file.
    public func initialize(_ config: ArchebaseConfig) throws {
        guard !self.exists() else {
            throw DataGatewayClientError.alreadyInitialized(configURL: self.configURL)
        }
        try self.write(config, replacingExisting: false)
    }

    /// Replaces the existing device configuration after a successful reinit.
    public func replaceForReinit(_ config: ArchebaseConfig) throws {
        guard self.exists() else {
            throw DataGatewayClientError.notInitialized(configURL: self.configURL)
        }
        _ = try self.load()
        try self.write(config, replacingExisting: true)
    }

    private func write(_ config: ArchebaseConfig, replacingExisting: Bool) throws {
        let data = try config.prettyJSONData()
        let parent = self.configURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(".\(self.configURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try Self.writeProtected(data, to: tempURL)
            if replacingExisting {
                _ = try self.fileManager.replaceItemAt(self.configURL, withItemAt: tempURL)
            } else {
                try self.fileManager.moveItem(at: tempURL, to: self.configURL)
            }
            let loaded = try self.load()
            guard loaded == config else {
                throw DataGatewayClientError.persistenceFailed("archebase config verification failed after write")
            }
        } catch let error as DataGatewayClientError {
            try? self.fileManager.removeItem(at: tempURL)
            throw error
        } catch {
            try? self.fileManager.removeItem(at: tempURL)
            throw DataGatewayClientError.persistenceFailed("failed to write archebase config: \(error.localizedDescription)")
        }
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: [])
        #endif
    }
}
