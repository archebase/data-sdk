import DGWControlPlane
import DGWStore
import Foundation
import Testing

@testable import DataGatewayClient

final class PassthroughSecurityScopedAccessor: SecurityScopedFileAccessing, @unchecked Sendable {
    func access<Result>(_ fileURL: URL, operation: @Sendable () throws -> Result) rethrows -> Result where Result : Sendable {
        _ = fileURL
        return try operation()
    }

    func bookmarkData(for fileURL: URL) throws -> Data {
        Data("bookmark:\(fileURL.path())".utf8)
    }
}

final class MemoryFileSystem: FileSystemProviding, @unchecked Sendable {
    struct Entry {
        let size: UInt64
        let modifiedAt: Date?
        let data: Data

        static func file(size: UInt64, modifiedAt: Date?, data: Data) -> Entry {
            Entry(size: size, modifiedAt: modifiedAt, data: data)
        }
    }

    private var storage: [URL: Entry]
    private var copyRecords: [(URL, URL)] = []

    init(files: [URL: Entry]) {
        self.storage = files.mapKeys { $0.standardizedFileURL }
    }

    func fileExists(at url: URL) -> Bool {
        self.storage[url.standardizedFileURL] != nil
    }

    func attributes(at url: URL) throws -> [FileAttributeKey : Any] {
        guard let entry = self.storage[url.standardizedFileURL] else {
            throw CocoaError(.fileNoSuchFile)
        }
        var attributes: [FileAttributeKey: Any] = [.size: NSNumber(value: entry.size)]
        if let modifiedAt = entry.modifiedAt {
            attributes[.modificationDate] = modifiedAt
        }
        return attributes
    }

    func read(prefixFrom url: URL, maxLength: Int) throws -> Data {
        guard let entry = self.storage[url.standardizedFileURL] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Data(entry.data.prefix(maxLength))
    }

    func readAll(from url: URL) throws -> Data {
        guard let entry = self.storage[url.standardizedFileURL] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return entry.data
    }

    func createDirectory(at url: URL) throws {
        _ = url
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard let entry = self.storage[source] else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.storage[destination] = entry
        self.copyRecords.append((source, destination))
    }

    func copiedItems() -> [(URL, URL)] {
        self.copyRecords
    }
}

func makePersistencePolicy(copyExternalFileIntoManagedStaging: Bool) -> LocalPersistencePolicy {
    LocalPersistencePolicy(
        keepTerminalSnapshot: true,
        keepCompletedSnapshot: false,
        completedSnapshotTTL: .seconds(0),
        terminalSnapshotTTL: .seconds(3600),
        copyExternalFileIntoManagedStaging: copyExternalFileIntoManagedStaging
    )
}

@Test func dataGatewayClientModuleNameIsStable() {
    #expect(DataGatewayClientModule.name == "DataGatewayClient")
}

@Test func publicEndpointsMatchHardcodedContract() {
    #if DEV
    let hostPrefix = "dev-"
    #else
    let hostPrefix = ""
    #endif

    #expect(ArchebasePublicEndpoints.auth == URL(string: "https://\(hostPrefix)auth.platform.archebase.ai")!)
    #expect(ArchebasePublicEndpoints.gateway == URL(string: "https://\(hostPrefix)gateway.platform.archebase.ai")!)
    #expect(ArchebasePublicEndpoints.deviceInit == URL(string: "https://\(hostPrefix)init-device.platform.archebase.ai")!)
}

@Test func publicClientConfigUsesFixedTlsEndpoints() throws {
    let root = URL(fileURLWithPath: "/tmp/archebase-public-config", isDirectory: true)
    let config = DataGatewayClientConfig.recommended(credentialBase64: "credential-base64", persistRootURL: root)

    #expect(config.authEndpoint == ArchebasePublicEndpoints.auth)
    #expect(config.gatewayEndpoint == ArchebasePublicEndpoints.gateway)
    #expect(config.tls == .tls)
    #expect(config.credentialBase64 == "credential-base64")
    #expect(config.persistRootURL == root)
    #expect(throws: Never.self) { try config.validate() }
}

@Test func publicDeviceInitConfigUsesTlsByDefault() throws {
    let configURL = URL(fileURLWithPath: "/tmp/archebase-config.json")
    let config = DeviceInitClientConfig(configURL: configURL)

    #expect(config.configURL == configURL)
    #expect(config.tls == .tls)
}

private extension Dictionary {
    func mapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey) -> [NewKey: Value] {
        Dictionary<NewKey, Value>(uniqueKeysWithValues: self.map { (transform($0.key), $0.value) })
    }
}

@Test func zeroByteFileFailsBeforeAnyRemoteWork() {
    let fileURL = URL(fileURLWithPath: "/tmp/zero.bin")
    let filesystem = MemoryFileSystem(files: [
        fileURL: .file(size: 0, modifiedAt: Date(timeIntervalSince1970: 100), data: Data()),
    ])
    let coordinator = FileStagingCoordinator(
        stagingRoot: URL(fileURLWithPath: "/staging"),
        fileSystem: filesystem,
        securityScopedAccessor: PassthroughSecurityScopedAccessor()
    )

    let error = #expect(throws: DataGatewayClientError.self) {
        try coordinator.prepare(
            request: UploadRequest(fileURL: fileURL, clientHints: [:], rawTags: [:], displayName: nil),
            persistence: makePersistencePolicy(copyExternalFileIntoManagedStaging: false)
        )
    }

    #expect(error == .zeroByteFile)
}

@Test func externalFileIsCopiedIntoManagedStaging() throws {
    let sourceURL = URL(fileURLWithPath: "/external/photo.heic")
    let stagingRoot = URL(fileURLWithPath: "/sandbox/staging")
    let data = Data("robot-camera-data".utf8)
    let modifiedAt = Date(timeIntervalSince1970: 200)
    let filesystem = MemoryFileSystem(files: [
        sourceURL: .file(size: UInt64(data.count), modifiedAt: modifiedAt, data: data),
    ])
    let coordinator = FileStagingCoordinator(
        stagingRoot: stagingRoot,
        fileSystem: filesystem,
        securityScopedAccessor: PassthroughSecurityScopedAccessor()
    )

    let prepared = try coordinator.prepare(
        request: UploadRequest(fileURL: sourceURL, clientHints: [:], rawTags: [:], displayName: nil),
        persistence: makePersistencePolicy(copyExternalFileIntoManagedStaging: true)
    )

    #expect(prepared.sourceFileURL == sourceURL)
    #expect(prepared.managedFileURL != sourceURL)
    #expect(prepared.managedFileURL.path().hasPrefix(stagingRoot.path()))
    #expect(filesystem.copiedItems().count == 1)
    #expect(prepared.fileSize == UInt64(data.count))
    #expect(prepared.fingerprint == LocalFileFingerprint(
        size: UInt64(data.count),
        modifiedAt: modifiedAt,
        firstChunkMD5Hex: "115EEAF7F69D1BF8FA4FAB891CB724C7"
    ))
    #expect(prepared.bookmarkData == Data("bookmark:/external/photo.heic".utf8))
}

@Test func missingManagedFileMakesResumeImpossible() {
    let managedURL = URL(fileURLWithPath: "/sandbox/staging/missing.bin")
    let coordinator = FileStagingCoordinator(
        stagingRoot: URL(fileURLWithPath: "/sandbox/staging"),
        fileSystem: MemoryFileSystem(files: [:]),
        securityScopedAccessor: PassthroughSecurityScopedAccessor()
    )

    let error = #expect(throws: DataGatewayClientError.self) {
        try coordinator.validatePreparedFile(
            managedFileURL: managedURL,
            expectedFingerprint: LocalFileFingerprint(
                size: 128,
                modifiedAt: Date(timeIntervalSince1970: 100),
                firstChunkMD5Hex: "ABCDEF0123456789ABCDEF0123456789"
            )
        )
    }

    #expect(error == .resumeNotPossible("managed file missing: /sandbox/staging/missing.bin"))
}

@Test func fingerprintMismatchMakesResumeImpossible() throws {
    let managedURL = URL(fileURLWithPath: "/sandbox/staging/demo.bin")
    let data = Data("robot-data-v2".utf8)
    let filesystem = MemoryFileSystem(files: [
        managedURL: .file(size: UInt64(data.count), modifiedAt: Date(timeIntervalSince1970: 100), data: data),
    ])
    let coordinator = FileStagingCoordinator(
        stagingRoot: URL(fileURLWithPath: "/sandbox/staging"),
        fileSystem: filesystem,
        securityScopedAccessor: PassthroughSecurityScopedAccessor()
    )

    let error = #expect(throws: DataGatewayClientError.self) {
        try coordinator.validatePreparedFile(
            managedFileURL: managedURL,
            expectedFingerprint: LocalFileFingerprint(
                size: UInt64(data.count),
                modifiedAt: Date(timeIntervalSince1970: 100),
                firstChunkMD5Hex: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            )
        )
    }

    #expect(error == .resumeNotPossible("local file fingerprint changed"))
}

@Test func fingerprintValidationToleratesFilesystemModifiedAtPrecisionDrift() throws {
    let managedURL = URL(fileURLWithPath: "/sandbox/staging/demo-drift.bin")
    let data = Data("robot-data-drift".utf8)
    let filesystem = MemoryFileSystem(files: [
        managedURL: .file(size: UInt64(data.count), modifiedAt: Date(timeIntervalSince1970: 100.900), data: data),
    ])
    let coordinator = FileStagingCoordinator(
        stagingRoot: URL(fileURLWithPath: "/sandbox/staging"),
        fileSystem: filesystem,
        securityScopedAccessor: PassthroughSecurityScopedAccessor()
    )

    #expect(throws: Never.self) {
        try coordinator.validatePreparedFile(
            managedFileURL: managedURL,
            expectedFingerprint: LocalFileFingerprint(
                size: UInt64(data.count),
                modifiedAt: Date(timeIntervalSince1970: 100.100),
                firstChunkMD5Hex: "5B0A5149AD41E87A29BCF9B37AD42DC4"
            )
        )
    }
}
