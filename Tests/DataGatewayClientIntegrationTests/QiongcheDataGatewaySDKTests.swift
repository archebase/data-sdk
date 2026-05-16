import DGWControlPlane
import DGWStore
import Foundation
import GRPCCore
import Testing

@testable import DataGatewayClient

@Test func qiongcheSDKPathsUseTemporaryRootWhenProvided() throws {
    let root = try qiongcheTemporaryRoot()
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Archebase", isDirectory: true)

    let paths = try QiongcheSDKPaths(rootURL: root)

    #expect(paths.rootURL == root.standardizedFileURL)
    #expect(paths.endpointsURL == root.appendingPathComponent("archebase-endpoints.json").standardizedFileURL)
    #expect(paths.configURL == root.appendingPathComponent("archebase-config.json").standardizedFileURL)
    #expect(paths.stateURL == root.appendingPathComponent("qiongche-sdk-state.json").standardizedFileURL)
    #expect(paths.persistRootURL == root.appendingPathComponent("Uploads", isDirectory: true).standardizedFileURL)
}

@Test func qiongcheSDKPathsDefaultToApplicationSupportArchebase() throws {
    let paths = try QiongcheSDKPaths()

    #expect(paths.rootURL.lastPathComponent == "Archebase")
    #expect(paths.rootURL.path.contains("Application Support"))
    #expect(paths.endpointsURL.lastPathComponent == "archebase-endpoints.json")
    #expect(paths.configURL.lastPathComponent == "archebase-config.json")
    #expect(paths.stateURL.lastPathComponent == "qiongche-sdk-state.json")
    #expect(paths.persistRootURL.lastPathComponent == "Uploads")
}

@Test func qiongcheSDKStateStoreWritesAndLoadsState() throws {
    let paths = try QiongcheSDKPaths(rootURL: qiongcheTemporaryRoot())
    let store = QiongcheSDKStateStore(stateURL: paths.stateURL)
    let state = try QiongcheSDKState(
        deviceID: "robot-001",
        endpointsSHA256: String(repeating: "a", count: 64),
        initializedAtUnix: 1_778_840_000
    )

    try store.replace(state)

    #expect(try store.load() == state)
    let raw = try String(contentsOf: paths.stateURL, encoding: .utf8)
    #expect(raw.contains("\"device_id\""))
    #expect(raw.contains("\"endpoints_sha256\""))
    #expect(!raw.contains("api_key"))
}

@Test func qiongcheSDKStateStoreOverwritesExistingState() throws {
    let paths = try QiongcheSDKPaths(rootURL: qiongcheTemporaryRoot())
    let store = QiongcheSDKStateStore(stateURL: paths.stateURL)
    let old = try QiongcheSDKState(
        deviceID: "robot-old",
        endpointsSHA256: String(repeating: "a", count: 64),
        initializedAtUnix: 1
    )
    let new = try QiongcheSDKState(
        deviceID: "robot-new",
        endpointsSHA256: String(repeating: "b", count: 64),
        initializedAtUnix: 2
    )

    try store.replace(old)
    try store.replace(new)

    #expect(try store.load() == new)
}

@Test func qiongcheSDKStateStoreCanReplaceCorruptedState() throws {
    let paths = try QiongcheSDKPaths(rootURL: qiongcheTemporaryRoot())
    try FileManager.default.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: paths.stateURL)
    let store = QiongcheSDKStateStore(stateURL: paths.stateURL)

    #expect(throws: DataGatewayClientError.self) {
        _ = try store.load()
    }

    let replacement = try QiongcheSDKState(
        deviceID: "robot-001",
        endpointsSHA256: String(repeating: "c", count: 64),
        initializedAtUnix: 3
    )
    try store.replace(replacement)

    #expect(try store.load() == replacement)
}

@Test func qiongcheDeviceProvisioningFakeRecordsInputs() async throws {
    let provisioner = RecordingQiongcheDeviceProvisioner(
        result: try ArchebaseConfig(apiKey: "credential-v1", tags: ["device": "robot"])
    )
    let endpoint = URL(string: "https://init.example.com:443")!

    let config = try await provisioner.initDevice(
        deviceID: "robot-001",
        deviceInitEndpoint: endpoint,
        tls: .tls,
        timeout: .seconds(7)
    )

    #expect(config == (try ArchebaseConfig(apiKey: "credential-v1", tags: ["device": "robot"])))
    let records = await provisioner.records()
    #expect(records == [
        .init(deviceID: "robot-001", endpoint: endpoint, tls: .tls, timeout: .seconds(7)),
    ])
}

@Test func qiongcheDefaultDeviceProvisionerCanBeConstructedWithoutLocalFiles() {
    _ = DefaultQiongcheDeviceProvisioner()
}

@Test func qiongcheSDKActorDefaultInitSucceedsWithTemporaryRoot() throws {
    _ = try QiongcheDataGatewaySDK(rootURL: qiongcheTemporaryRoot())
}

@Test func qiongcheSDKActorTestInitAcceptsFakeDependencies() throws {
    _ = try QiongcheDataGatewaySDK(
        rootURL: qiongcheTemporaryRoot(),
        deviceInitTimeout: .seconds(5),
        readinessTimeout: .seconds(2),
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(
            result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
        ),
        readinessProbe: AlwaysReachableQiongcheProbe(),
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1_778_840_000))
    )
}

@Test func qiongcheSaveConfigAndInitFirstCallWritesEndpointsConfigAndState() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    let remoteConfig = try ArchebaseConfig(apiKey: "credential-v1", tags: ["device": "robot"])
    let provisioner = RecordingQiongcheDeviceProvisioner(result: remoteConfig)
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: root,
        deviceProvisioner: provisioner,
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1_778_840_000))
    )

    try await sdk.saveConfigAndInit(configString: validQiongcheConfig(deviceID: "robot-001"))

    let endpoints = try ArchebasePublicEndpoints.load(endpointsURL: paths.endpointsURL)
    #expect(endpoints.auth == URL(string: "http://auth.example.com:50051")!)
    #expect(try await ArchebaseConfigStore(configURL: paths.configURL).load() == remoteConfig)
    let state = try QiongcheSDKStateStore(stateURL: paths.stateURL).load()
    let parsed = try QiongcheConfigParser.parse(validQiongcheConfig(deviceID: "robot-001"))
    #expect(state.deviceID == "robot-001")
    #expect(state.endpointsSHA256 == parsed.endpointsSHA256Hex)
    #expect(state.initializedAtUnix == 1_778_840_000)

    let records = await provisioner.records()
    #expect(records == [
        .init(
            deviceID: "robot-001",
            endpoint: URL(string: "https://init.example.com:443")!,
            tls: .tls,
            timeout: .seconds(10)
        ),
    ])
}

@Test func qiongcheSaveConfigAndInitOverwritesExistingLocalFiles() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    try ArchebasePublicEndpoints.replace(
        endpointsJSON: validQiongcheConfig(deviceID: "robot-old", authHost: "old-auth.example.com"),
        endpointsURL: paths.endpointsURL
    )
    try await ArchebaseConfigStore(configURL: paths.configURL)
        .replaceOrInitialize(try ArchebaseConfig(apiKey: "credential-old", tags: ["device": "old"]))
    try QiongcheSDKStateStore(stateURL: paths.stateURL).replace(try QiongcheSDKState(
        deviceID: "robot-old",
        endpointsSHA256: String(repeating: "a", count: 64),
        initializedAtUnix: 1
    ))

    let remoteConfig = try ArchebaseConfig(apiKey: "credential-new", tags: ["device": "new"])
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: root,
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(result: remoteConfig),
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 2))
    )

    try await sdk.saveConfigAndInit(
        configString: validQiongcheConfig(deviceID: "robot-new", authHost: "new-auth.example.com")
    )

    let endpoints = try ArchebasePublicEndpoints.load(endpointsURL: paths.endpointsURL)
    #expect(endpoints.auth == URL(string: "http://new-auth.example.com:50051")!)
    #expect(try await ArchebaseConfigStore(configURL: paths.configURL).load() == remoteConfig)
    let state = try QiongcheSDKStateStore(stateURL: paths.stateURL).load()
    #expect(state.deviceID == "robot-new")
    #expect(state.initializedAtUnix == 2)
}

@Test func qiongcheSaveConfigAndInitRepeatedSameConfigCallsRemoteEachTime() async throws {
    let root = try qiongcheTemporaryRoot()
    let provisioner = RecordingQiongcheDeviceProvisioner(
        result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
    )
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: root,
        deviceProvisioner: provisioner,
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1))
    )

    try await sdk.saveConfigAndInit(configString: validQiongcheConfig(deviceID: "robot-001"))
    try await sdk.saveConfigAndInit(configString: validQiongcheConfig(deviceID: "robot-001"))

    #expect(await provisioner.records().count == 2)
}

@Test func qiongcheSaveConfigAndInitRebuildsConfigWhenStateExistsButConfigMissing() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    try ArchebasePublicEndpoints.replace(endpointsJSON: validQiongcheConfig(), endpointsURL: paths.endpointsURL)
    try QiongcheSDKStateStore(stateURL: paths.stateURL).replace(try QiongcheSDKState(
        deviceID: "robot-001",
        endpointsSHA256: String(repeating: "d", count: 64),
        initializedAtUnix: 1
    ))
    let remoteConfig = try ArchebaseConfig(apiKey: "credential-v1", tags: ["device": "rebuilt"])
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: root,
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(result: remoteConfig),
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 2))
    )

    try await sdk.saveConfigAndInit(configString: validQiongcheConfig(deviceID: "robot-001"))

    #expect(try await ArchebaseConfigStore(configURL: paths.configURL).load() == remoteConfig)
    #expect(try QiongcheSDKStateStore(stateURL: paths.stateURL).load().initializedAtUnix == 2)
}

@Test func qiongcheSaveConfigAndInitKeepsOldFilesWhenRemoteInitFails() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    let oldConfigString = validQiongcheConfig(deviceID: "robot-old", authHost: "old-auth.example.com")
    let oldRemoteConfig = try ArchebaseConfig(apiKey: "credential-old", tags: ["device": "old"])
    let oldState = try QiongcheSDKState(
        deviceID: "robot-old",
        endpointsSHA256: String(repeating: "a", count: 64),
        initializedAtUnix: 1
    )
    try ArchebasePublicEndpoints.replace(endpointsJSON: oldConfigString, endpointsURL: paths.endpointsURL)
    try await ArchebaseConfigStore(configURL: paths.configURL).replaceOrInitialize(oldRemoteConfig)
    try QiongcheSDKStateStore(stateURL: paths.stateURL).replace(oldState)

    let sdk = try QiongcheDataGatewaySDK(
        rootURL: root,
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(
            error: .gatewayFailed(statusCode: 14, detailCode: nil, message: "unavailable")
        ),
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 2))
    )

    await #expect(throws: DataGatewayClientError.self) {
        try await sdk.saveConfigAndInit(
            configString: validQiongcheConfig(deviceID: "robot-new", authHost: "new-auth.example.com")
        )
    }

    let endpoints = try ArchebasePublicEndpoints.load(endpointsURL: paths.endpointsURL)
    #expect(endpoints.auth == URL(string: "http://old-auth.example.com:50051")!)
    #expect(try await ArchebaseConfigStore(configURL: paths.configURL).load() == oldRemoteConfig)
    #expect(try QiongcheSDKStateStore(stateURL: paths.stateURL).load() == oldState)
}

@Test func qiongcheSaveConfigAndInitPropagatesEndpointPersistenceFailure() async throws {
    let provisioner = RecordingQiongcheDeviceProvisioner(
        result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
    )
    let persister = RecordingQiongcheLocalPersister(failures: [.endpoints])
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: qiongcheTemporaryRoot(),
        deviceProvisioner: provisioner,
        localPersister: persister,
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1))
    )

    await #expect(throws: DataGatewayClientError.self) {
        try await sdk.saveConfigAndInit(configString: validQiongcheConfig())
    }

    #expect(await persister.operations() == [.endpoints])
    #expect(await provisioner.records().count == 1)
}

@Test func qiongcheSaveConfigAndInitPropagatesConfigPersistenceFailure() async throws {
    let persister = RecordingQiongcheLocalPersister(failures: [.config])
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: qiongcheTemporaryRoot(),
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(
            result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
        ),
        localPersister: persister,
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1))
    )

    await #expect(throws: DataGatewayClientError.self) {
        try await sdk.saveConfigAndInit(configString: validQiongcheConfig())
    }

    #expect(await persister.operations() == [.endpoints, .config])
}

@Test func qiongcheSaveConfigAndInitCanRecoverAfterStatePersistenceFailure() async throws {
    let provisioner = RecordingQiongcheDeviceProvisioner(
        result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
    )
    let persister = RecordingQiongcheLocalPersister(failures: [.state])
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: qiongcheTemporaryRoot(),
        deviceProvisioner: provisioner,
        localPersister: persister,
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1))
    )

    await #expect(throws: DataGatewayClientError.self) {
        try await sdk.saveConfigAndInit(configString: validQiongcheConfig())
    }

    try await sdk.saveConfigAndInit(configString: validQiongcheConfig())

    #expect(await persister.operations() == [.endpoints, .config, .state, .endpoints, .config, .state])
    #expect(await provisioner.records().count == 2)
}

@Test func qiongcheEndpointReachabilityClassifiesReachableRPCFailures() {
    for code in [
        RPCError.Code.unauthenticated,
        .permissionDenied,
        .invalidArgument,
        .notFound,
        .failedPrecondition,
    ] {
        #expect(QiongcheEndpointReachability.isReachable(error: RPCError(code: code, message: "reachable")))
    }
}

@Test func qiongcheEndpointReachabilityClassifiesUnreachableRPCFailures() {
    for code in [
        RPCError.Code.unavailable,
        .deadlineExceeded,
        .cancelled,
    ] {
        #expect(!QiongcheEndpointReachability.isReachable(error: RPCError(code: code, message: "unreachable")))
    }
}

@Test func qiongcheEndpointReachabilityClassifiesCancellationAsUnreachable() {
    #expect(!QiongcheEndpointReachability.isReachable(error: CancellationError()))
}

@Test func qiongcheProbeTimeoutReturnsFastTaskResult() async throws {
    let result = try await QiongcheProbeTimeout.run(timeout: .seconds(1)) {
        true
    }

    #expect(result)
}

@Test func qiongcheProbeTimeoutThrowsAndClassifiesAsUnreachable() async {
    let error = await #expect(throws: QiongcheProbeTimeoutError.self) {
        try await QiongcheProbeTimeout.run(
            timeout: Duration(secondsComponent: 0, attosecondsComponent: 10_000_000_000_000_000)
        ) {
            try await Task.sleep(for: .seconds(1))
            return true
        }
    }

    if let error {
        #expect(!QiongcheEndpointReachability.isReachable(error: error))
    }
}

@Test func qiongcheDefaultEndpointProbeReturnsFalseForInvalidTLSConfiguration() async {
    let probe = DefaultQiongcheEndpointProbe()
    let endpoint = URL(string: "https://auth.example.com:443")!

    let authReachable = await probe.authEndpointReachable(
        endpoint: endpoint,
        tls: .plaintext,
        timeout: .seconds(1)
    )
    let gatewayReachable = await probe.gatewayEndpointReachable(
        endpoint: endpoint,
        tls: .plaintext,
        timeout: .seconds(1)
    )

    #expect(!authReachable)
    #expect(!gatewayReachable)
}

@Test func qiongcheIsReadyToUploadReturnsFalseWhenConfigMissing() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    try ArchebasePublicEndpoints.replace(endpointsJSON: validQiongcheConfig(), endpointsURL: paths.endpointsURL)
    let sdk = try qiongcheReadySDK(rootURL: root, authReachable: true, gatewayReachable: true)

    #expect(await sdk.isReadyToUpload() == false)
}

@Test func qiongcheIsReadyToUploadReturnsFalseWhenEndpointsMissing() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    try await ArchebaseConfigStore(configURL: paths.configURL)
        .replaceOrInitialize(try ArchebaseConfig(apiKey: "credential-v1", tags: [:]))
    let sdk = try qiongcheReadySDK(rootURL: root, authReachable: true, gatewayReachable: true)

    #expect(await sdk.isReadyToUpload() == false)
}

@Test func qiongcheIsReadyToUploadReturnsFalseWhenEndpointsAreCorrupt() async throws {
    let root = try qiongcheTemporaryRoot()
    let paths = try QiongcheSDKPaths(rootURL: root)
    try FileManager.default.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: paths.endpointsURL)
    try await ArchebaseConfigStore(configURL: paths.configURL)
        .replaceOrInitialize(try ArchebaseConfig(apiKey: "credential-v1", tags: [:]))
    let sdk = try qiongcheReadySDK(rootURL: root, authReachable: true, gatewayReachable: true)

    #expect(await sdk.isReadyToUpload() == false)
}

@Test func qiongcheIsReadyToUploadReturnsTrueWhenAuthAndGatewayReachable() async throws {
    let root = try qiongcheTemporaryRoot()
    try await writeQiongcheReadyFiles(rootURL: root)
    let sdk = try qiongcheReadySDK(rootURL: root, authReachable: true, gatewayReachable: true)

    #expect(await sdk.isReadyToUpload())
}

@Test func qiongcheIsReadyToUploadReturnsFalseWhenEitherEndpointIsUnreachable() async throws {
    let root = try qiongcheTemporaryRoot()
    try await writeQiongcheReadyFiles(rootURL: root)
    let authDownSDK = try qiongcheReadySDK(rootURL: root, authReachable: false, gatewayReachable: true)
    let gatewayDownSDK = try qiongcheReadySDK(rootURL: root, authReachable: true, gatewayReachable: false)

    #expect(await authDownSDK.isReadyToUpload() == false)
    #expect(await gatewayDownSDK.isReadyToUpload() == false)
}

@Test func qiongcheIsReadyToUploadReturnsFalseWhenProbeTimesOut() async throws {
    let root = try qiongcheTemporaryRoot()
    try await writeQiongcheReadyFiles(rootURL: root)
    let sdk = try QiongcheDataGatewaySDK(
        rootURL: root,
        readinessTimeout: Duration(secondsComponent: 0, attosecondsComponent: 10_000_000_000_000_000),
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(
            result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
        ),
        readinessProbe: TimeoutQiongcheProbe(),
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1))
    )

    #expect(await sdk.isReadyToUpload() == false)
}

func qiongcheTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("qiongche-sdk-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeQiongcheReadyFiles(rootURL: URL) async throws {
    let paths = try QiongcheSDKPaths(rootURL: rootURL)
    try ArchebasePublicEndpoints.replace(endpointsJSON: validQiongcheConfig(), endpointsURL: paths.endpointsURL)
    try await ArchebaseConfigStore(configURL: paths.configURL)
        .replaceOrInitialize(try ArchebaseConfig(apiKey: "credential-v1", tags: [:]))
}

private func qiongcheReadySDK(
    rootURL: URL,
    authReachable: Bool,
    gatewayReachable: Bool
) throws -> QiongcheDataGatewaySDK {
    try QiongcheDataGatewaySDK(
        rootURL: rootURL,
        deviceProvisioner: RecordingQiongcheDeviceProvisioner(
            result: try ArchebaseConfig(apiKey: "credential-v1", tags: [:])
        ),
        readinessProbe: ConfiguredQiongcheProbe(authReachable: authReachable, gatewayReachable: gatewayReachable),
        clock: FixedQiongcheSDKClock(date: Date(timeIntervalSince1970: 1))
    )
}

private actor RecordingQiongcheDeviceProvisioner: QiongcheDeviceProvisioning {
    struct Record: Equatable {
        var deviceID: String
        var endpoint: URL
        var tls: TLSMode
        var timeout: Duration
    }

    private enum Outcome {
        case success(ArchebaseConfig)
        case failure(DataGatewayClientError)
    }

    private let outcome: Outcome
    private var recorded: [Record] = []

    init(result: ArchebaseConfig) {
        self.outcome = .success(result)
    }

    init(error: DataGatewayClientError) {
        self.outcome = .failure(error)
    }

    func initDevice(
        deviceID: String,
        deviceInitEndpoint: URL,
        tls: TLSMode,
        timeout: Duration
    ) async throws -> ArchebaseConfig {
        self.recorded.append(.init(deviceID: deviceID, endpoint: deviceInitEndpoint, tls: tls, timeout: timeout))
        switch self.outcome {
        case .success(let config):
            return config
        case .failure(let error):
            throw error
        }
    }

    func records() -> [Record] {
        self.recorded
    }
}

private struct AlwaysReachableQiongcheProbe: QiongcheEndpointProbing {
    func authEndpointReachable(endpoint: URL, tls: TLSMode, timeout: Duration) async -> Bool {
        _ = (endpoint, tls, timeout)
        return true
    }

    func gatewayEndpointReachable(endpoint: URL, tls: TLSMode, timeout: Duration) async -> Bool {
        _ = (endpoint, tls, timeout)
        return true
    }
}

private struct ConfiguredQiongcheProbe: QiongcheEndpointProbing {
    var authReachable: Bool
    var gatewayReachable: Bool

    func authEndpointReachable(endpoint: URL, tls: TLSMode, timeout: Duration) async -> Bool {
        _ = (endpoint, tls, timeout)
        return self.authReachable
    }

    func gatewayEndpointReachable(endpoint: URL, tls: TLSMode, timeout: Duration) async -> Bool {
        _ = (endpoint, tls, timeout)
        return self.gatewayReachable
    }
}

private struct TimeoutQiongcheProbe: QiongcheEndpointProbing {
    func authEndpointReachable(endpoint: URL, tls: TLSMode, timeout: Duration) async -> Bool {
        _ = (endpoint, tls)
        return await self.timedOutResult(timeout: timeout)
    }

    func gatewayEndpointReachable(endpoint: URL, tls: TLSMode, timeout: Duration) async -> Bool {
        _ = (endpoint, tls)
        return await self.timedOutResult(timeout: timeout)
    }

    private func timedOutResult(timeout: Duration) async -> Bool {
        do {
            return try await QiongcheProbeTimeout.run(timeout: timeout) {
                try await Task.sleep(for: .seconds(1))
                return true
            }
        } catch {
            return false
        }
    }
}

private struct FixedQiongcheSDKClock: QiongcheSDKClock {
    var date: Date

    func now() async -> Date {
        self.date
    }
}

private actor RecordingQiongcheLocalPersister: QiongcheLocalPersisting {
    enum Stage: Equatable, Sendable {
        case endpoints
        case config
        case state
    }

    private var failures: [Stage]
    private var recordedOperations: [Stage] = []

    init(failures: [Stage]) {
        self.failures = failures
    }

    func replaceEndpoints(endpointsJSON: String, endpointsURL: URL) async throws {
        _ = (endpointsJSON, endpointsURL)
        try self.record(.endpoints)
    }

    func replaceConfig(_ config: ArchebaseConfig, configURL: URL) async throws {
        _ = (config, configURL)
        try self.record(.config)
    }

    func replaceState(_ state: QiongcheSDKState, stateURL: URL) async throws {
        _ = (state, stateURL)
        try self.record(.state)
    }

    func operations() -> [Stage] {
        self.recordedOperations
    }

    private func record(_ stage: Stage) throws {
        self.recordedOperations.append(stage)
        if self.failures.first == stage {
            self.failures.removeFirst()
            throw DataGatewayClientError.persistenceFailed("injected qiongche \(stage) failure")
        }
    }
}
