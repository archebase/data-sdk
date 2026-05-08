import DGWAuth
import DGWControlPlane
import DGWProto
import DGWStore
import Foundation
import GRPCNIOTransportHTTP2
import Testing

@testable import DataGatewayClient

private let runtimeIntegrationEnabled = ProcessInfo.processInfo.environment["DGW_LOCAL_RUNTIME_INTEGRATION"] == "1"
private let realRuntimeIntegrationEnabled = ProcessInfo.processInfo.environment["DGW_REAL_RUNTIME_INTEGRATION"] == "1"
private let realDeviceInitIntegrationEnabled = ProcessInfo.processInfo.environment["DGW_REAL_DEVICE_INIT_INTEGRATION"] == "1"
private let publicDNSIntegrationEnabled = ProcessInfo.processInfo.environment["DGW_PUBLIC_DNS_INTEGRATION"] == "1"

@Suite(.serialized)
struct LocalStackHarnessTests {

@Test func localStackEnvironmentReadsConfiguredEndpointsAndCredential() throws {
    let environment: [String: String] = [
        "DGW_LOCAL_AUTH_ENDPOINT": "http://127.0.0.1:15055",
        "DGW_LOCAL_GATEWAY_ENDPOINT": "http://127.0.0.1:15053",
        "DGW_LOCAL_INIT_ENDPOINT": "http://127.0.0.1:15057",
        "DGW_LOCAL_CREDENTIAL_BASE64": "credential-base64",
        "DGW_LOCAL_DEVICE_ID": "260427-000001",
        "DGW_LOCAL_UNBOUND_DEVICE_ID": "260427-000002",
        "DGW_LOCAL_PERSIST_ROOT": "/tmp/swift-dgw-local-tests",
    ]

    let config = try LocalStackTestEnvironment(environment: environment).makeClientConfig()
    let initConfig = try LocalStackTestEnvironment(environment: environment).makeDeviceInitConfig()

    #expect(config.authEndpoint == URL(string: "http://127.0.0.1:15055")!)
    #expect(config.gatewayEndpoint == URL(string: "http://127.0.0.1:15053")!)
    #expect(config.credentialBase64 == "credential-base64")
    #expect(config.persistRootURL == URL(fileURLWithPath: "/tmp/swift-dgw-local-tests", isDirectory: true))
    #expect(config.tls == .plaintext)
    #expect(initConfig.endpoint == URL(string: "http://127.0.0.1:15057")!)
    #expect(initConfig.deviceID == "260427-000001")
    #expect(initConfig.unboundDeviceID == "260427-000002")
}

@Test func localStackEnvironmentNormalizesSingleSlashSimulatorURLs() throws {
    let environment: [String: String] = [
        "DGW_LOCAL_AUTH_ENDPOINT": "http:/127.0.0.1:15055",
        "DGW_LOCAL_GATEWAY_ENDPOINT": "http:/127.0.0.1:15053",
        "DGW_LOCAL_CREDENTIAL_BASE64": "credential-base64",
        "DGW_LOCAL_PERSIST_ROOT": "/tmp/swift-dgw-local-tests",
    ]

    let config = try LocalStackTestEnvironment(environment: environment).makeClientConfig()

    #expect(config.authEndpoint == URL(string: "http://127.0.0.1:15055")!)
    #expect(config.gatewayEndpoint == URL(string: "http://127.0.0.1:15053")!)
}

@Test func localStackEnvironmentFailsWhenRequiredVariablesAreMissing() {
    let environment = LocalStackTestEnvironment(environment: [:])

    let error = #expect(throws: LocalStackHarnessError.self) {
        try environment.makeClientConfig()
    }

    #expect(error == .missingEnvironmentVariable("DGW_LOCAL_AUTH_ENDPOINT"))
}

@Test func localStackBootstrapConfigUsesExplicitEnvironmentOverrides() throws {
    let environment = LocalStackTestEnvironment(environment: [
        "DGW_LOCAL_GATEWAY_HTTP_BASE": "http://127.0.0.1:18098",
        "DGW_LOCAL_BOOTSTRAP_ADMIN_PASSWORD": "ci-admin-password",
        "DGW_LOCAL_BOOTSTRAP_ORGANIZATION": "system",
        "DGW_LOCAL_BOOTSTRAP_ADMIN_USER": "admin",
        "DGW_LOCAL_BOOTSTRAP_SITE_NAME": "swift-site",
        "DGW_LOCAL_BOOTSTRAP_SITE_STATUS": "2",
        "DGW_LOCAL_BOOTSTRAP_API_KEY_ID": "swift-key",
        "DGW_LOCAL_BOOTSTRAP_API_KEY_PREFIX": "swift-prefix",
        "DGW_LOCAL_BOOTSTRAP_API_KEY_STATUS": "2",
        "DGW_LOCAL_BOOTSTRAP_CSRF_ORIGIN": "http://127.0.0.1:18098",
    ])

    let config = try environment.makeBootstrapConfig()

    #expect(config.gatewayBaseURL == URL(string: "http://127.0.0.1:18098")!)
    #expect(config.organization == "system")
    #expect(config.adminUserName == "admin")
    #expect(config.adminPassword == "ci-admin-password")
    #expect(config.siteName == "swift-site")
    #expect(config.siteStatus == 2)
    #expect(config.apiKeyID == "swift-key")
    #expect(config.apiKeyPrefix == "swift-prefix")
    #expect(config.apiKeyStatus == 2)
    #expect(config.csrfOrigin == "http://127.0.0.1:18098")
}

@Test func localStackBootstrapConfigSuppliesStableDefaults() throws {
    let config = try LocalStackTestEnvironment(environment: [
        "DGW_LOCAL_GATEWAY_HTTP_BASE": "http://127.0.0.1:18098/",
        "DGW_LOCAL_BOOTSTRAP_ADMIN_PASSWORD": "ci-admin-password",
    ]).makeBootstrapConfig()

    #expect(config.organization == "system")
    #expect(config.adminUserName == "admin")
    #expect(config.siteName == "swift-local-site")
    #expect(config.siteStatus == 1)
    #expect(config.apiKeyID == "swift-local-key")
    #expect(config.apiKeyPrefix == "swift-local")
    #expect(config.apiKeyStatus == 1)
    #expect(config.csrfOrigin == "http://127.0.0.1:18098")
}

@Test func localStackBootstrapConfigRequiresGatewayBaseAndAdminPassword() {
    let missingGateway = LocalStackTestEnvironment(environment: [
        "DGW_LOCAL_BOOTSTRAP_ADMIN_PASSWORD": "ci-admin-password",
    ])
    let missingPassword = LocalStackTestEnvironment(environment: [
        "DGW_LOCAL_GATEWAY_HTTP_BASE": "http://127.0.0.1:18098",
    ])

    let gatewayError = #expect(throws: LocalStackHarnessError.self) {
        try missingGateway.makeBootstrapConfig()
    }
    let passwordError = #expect(throws: LocalStackHarnessError.self) {
        try missingPassword.makeBootstrapConfig()
    }

    #expect(gatewayError == .missingEnvironmentVariable("DGW_LOCAL_GATEWAY_HTTP_BASE"))
    #expect(passwordError == .missingEnvironmentVariable("DGW_LOCAL_BOOTSTRAP_ADMIN_PASSWORD"))
}

@Test func localStackBootstrapScriptContainsRequiredPreparationSteps() throws {
    let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/local_integration_bootstrap.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    #expect(script.contains("scripts/local_run.sh --build debug --deploy --reset-db"))
    #expect(script.contains("DATA_GATEWAY_USE_MOCK_STS=true"))
    #expect(script.contains("DGW_LOCAL_GATEWAY_HTTP_BASE"))
    #expect(script.contains("DGW_LOCAL_BOOTSTRAP_ADMIN_PASSWORD"))
    #expect(script.contains("DGW_LOCAL_BOOTSTRAP_MAX_TIME_SECONDS"))
    #expect(script.contains("DGW_LOCAL_BOOTSTRAP_CONNECT_TIMEOUT_SECONDS"))
    #expect(script.contains(#"BOOTSTRAP_API_KEY_SUFFIX="${BOOTSTRAP_API_KEY_SUFFIX:0:26}""#))
    #expect(script.contains("swift-key-${BOOTSTRAP_API_KEY_SUFFIX}"))
    #expect(script.contains("DGW_LOCAL_CREDENTIAL_BASE64"))
    #expect(script.contains("DGW_LOCAL_DEVICE_ID"))
    #expect(script.contains("DGW_LOCAL_UNBOUND_DEVICE_ID"))
    #expect(script.contains("DGW_LOCAL_INIT_ENDPOINT"))
    #expect(script.contains("curl -sS -X POST"))
    #expect(script.contains("/api/dataplatform/v1/auth/login"))
    #expect(script.contains("/api/dataplatform/v1/sites"))
    #expect(script.contains("/api/dataplatform/v1/sites/${SITE_ID}/api-keys"))
    #expect(script.contains("/api/dataplatform/v1/devices:register"))
    #expect(script.contains("/api/dataplatform/v1/deviceSuites"))
    #expect(script.contains(":addDevice"))
}

@Test func simulatorSmokeScriptSkipsPackageUpdatesForCachedDependencies() throws {
    let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/simulator_smoke.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    #expect(script.contains("xcodebuild build-for-testing"))
    #expect(script.contains("-skipPackageUpdates"))
}

@Test func aliyunEnvironmentContractValidatesPresenceOfCredentials() {
    let environment = AliyunOSSTestEnvironment(environment: [:])

    let error = #expect(throws: AliyunOSSHarnessError.self) {
        try environment.validate()
    }

    #expect(error == .missingEnvironmentVariable("DGW_OSS_TEST_ENDPOINT"))
}

@Test func aliyunEnvironmentContractAcceptsCompleteConfiguration() throws {
    let environment = AliyunOSSTestEnvironment(environment: [
        "DGW_OSS_TEST_ENDPOINT": "https://oss-cn-shanghai.aliyuncs.com",
        "DGW_OSS_TEST_BUCKET": "bucket-1",
        "DGW_OSS_TEST_ACCESS_KEY_ID": "ak",
        "DGW_OSS_TEST_ACCESS_KEY_SECRET": "sk",
        "DGW_OSS_TEST_SECURITY_TOKEN": "token",
        "DGW_OSS_TEST_OBJECT_PREFIX": "swift-tests/run-1",
    ])

    try environment.validate()
}

@Test func aliyunEnvironmentBuildsRemoteClientConfig() throws {
    let config = try AliyunOSSTestEnvironment(environment: [
        "DGW_REAL_AUTH_ENDPOINT": "http://example-auth:50051",
        "DGW_REAL_GATEWAY_ENDPOINT": "http://example-gateway:50053",
        "DGW_REAL_CREDENTIAL_BASE64": "credential-base64",
        "DGW_REAL_PERSIST_ROOT": "/tmp/swift-dgw-real-tests",
        "DGW_REAL_TLS_MODE": "plaintext",
    ]).makeRemoteClientConfig()

    #expect(config.authEndpoint == URL(string: "http://example-auth:50051")!)
    #expect(config.gatewayEndpoint == URL(string: "http://example-gateway:50053")!)
    #expect(config.credentialBase64 == "credential-base64")
    #expect(config.persistRootURL == URL(fileURLWithPath: "/tmp/swift-dgw-real-tests", isDirectory: true))
    #expect(config.tls == .plaintext)
}

@Test func aliyunEnvironmentRemoteConfigRequiresCredentialBeforeEndpointOverrides() {
    let environment = AliyunOSSTestEnvironment(environment: [:])

    let error = #expect(throws: AliyunOSSHarnessError.self) {
        try environment.makeRemoteClientConfig()
    }

    #expect(error == .missingEnvironmentVariable("DGW_REAL_CREDENTIAL_BASE64"))
}

@Test func aliyunEnvironmentNormalizesSingleSlashRemoteURLs() throws {
    let config = try AliyunOSSTestEnvironment(environment: [
        "DGW_REAL_AUTH_ENDPOINT": "http:/example-auth:50051",
        "DGW_REAL_GATEWAY_ENDPOINT": "http:/example-gateway:50053",
        "DGW_REAL_CREDENTIAL_BASE64": "credential-base64",
        "DGW_REAL_PERSIST_ROOT": "/tmp/swift-dgw-real-tests",
        "DGW_REAL_TLS_MODE": "plaintext",
        "DGW_OSS_TEST_ENDPOINT": "https://oss-cn-shanghai.aliyuncs.com",
        "DGW_OSS_TEST_BUCKET": "archebase",
        "DGW_OSS_TEST_ACCESS_KEY_ID": "ak",
        "DGW_OSS_TEST_ACCESS_KEY_SECRET": "sk",
        "DGW_OSS_TEST_SECURITY_TOKEN": "token",
        "DGW_OSS_TEST_OBJECT_PREFIX": "dev/1",
    ]).makeRemoteClientConfig()

    #expect(config.authEndpoint == URL(string: "http://example-auth:50051")!)
    #expect(config.gatewayEndpoint == URL(string: "http://example-gateway:50053")!)
}

@Test func aliyunEnvironmentProvidesRemoteUploadExpectation() throws {
    let expectation = try AliyunOSSTestEnvironment(environment: [
        "DGW_OSS_TEST_ENDPOINT": "https://oss-cn-shanghai.aliyuncs.com",
        "DGW_OSS_TEST_BUCKET": "archebase",
        "DGW_OSS_TEST_ACCESS_KEY_ID": "ak",
        "DGW_OSS_TEST_ACCESS_KEY_SECRET": "sk",
        "DGW_OSS_TEST_SECURITY_TOKEN": "token",
        "DGW_OSS_TEST_OBJECT_PREFIX": "dev/1",
    ]).remoteUploadExpectation()

    #expect(expectation.bucket == "archebase")
    #expect(expectation.objectPrefix == "dev/1")
}

@Test(
    .enabled(if: runtimeIntegrationEnabled)
) func localStackRuntimeBootstrapAndControlPlaneFlow() async throws {
    let environment = LocalStackTestEnvironment()
    let clientConfig = try environment.makeClientConfig()
    #expect(!clientConfig.credentialBase64.isEmpty)

    let authFactory = ControlPlaneClientFactory(
        configuration: ControlPlaneTransportConfiguration(
            endpoint: clientConfig.authEndpoint,
            security: .plaintext,
            requestTimeout: clientConfig.requestTimeout
        )
    )
    let authTransport = try authFactory.makeAuthTransport()
    let authProvider = CredentialAuthProvider(
        credentialBase64: clientConfig.credentialBase64,
        refreshBefore: clientConfig.authRefreshBefore,
        requestTimeout: clientConfig.requestTimeout,
        transport: authTransport.serviceClient
    )
    let gatewayTransport = try ManagedControlPlaneServiceClient(
        configuration: ControlPlaneTransportConfiguration(
            endpoint: clientConfig.gatewayEndpoint,
            security: .plaintext,
            requestTimeout: clientConfig.requestTimeout
        )
    ) { grpcClient in
        Archebase_DataGateway_V1_DataGatewayService.Client(wrapping: grpcClient)
    }
    let gatewayClient = AnyUploadCoordinatorGatewayClient(
        authProvider: authProvider,
        gatewayServiceClient: gatewayTransport.serviceClient,
        requestTimeout: clientConfig.requestTimeout,
        retryPolicy: clientConfig.retryPolicy.controlPlane.controlPlaneValue
    )
    let stateStore = UploadStateStore(persistRoot: clientConfig.persistRootURL)
    let fileCoordinator = FileStagingCoordinator(
        stagingRoot: clientConfig.persistRootURL
            .appendingPathComponent("data-gateway-client", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    )
    let client = DataGatewayClient(
        uploadCoordinator: UploadCoordinator(
            executionPolicy: clientConfig.execution,
            dependencies: UploadCoordinatorDependencies(
                gatewayClient: gatewayClient,
                stateStore: stateStore,
                fileCoordinator: fileCoordinator,
                ossClientFactory: { context in LocalStackMockMultipartSession(uploadID: context.uploadID) }
            )
        ),
        runtimeResources: DataGatewayClientRuntimeResources(
            authTransport: authTransport,
            gatewayTransport: gatewayTransport
        )
    )

    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-local-runtime-\(UUID().uuidString)")
        .appendingPathExtension("bin")
    try Data("swift-local-runtime-payload".utf8).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let zeroByteURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-local-runtime-zero-\(UUID().uuidString)")
        .appendingPathExtension("bin")
    try Data().write(to: zeroByteURL)
    defer { try? FileManager.default.removeItem(at: zeroByteURL) }

    let zeroByteError: DGWControlPlane.DataGatewayClientError? = await #expect(throws: DGWControlPlane.DataGatewayClientError.self) {
        try await client.upload(
            UploadRequest(fileURL: zeroByteURL, clientHints: ["kind": "zero-byte"], rawTags: [:], displayName: nil)
        )
    }
    #expect(zeroByteError == .zeroByteFile)

    let result = try await client.upload(
        UploadRequest(fileURL: fileURL, clientHints: ["kind": "runtime"], rawTags: ["suite": "local-stack"], displayName: "runtime")
    )
    #expect(!result.logicalUploadID.isEmpty)
    #expect(!result.uploadID.isEmpty)
    #expect(result.fileSize == UInt64(Data("swift-local-runtime-payload".utf8).count))
    #expect(!result.bucket.isEmpty)
    #expect(!result.objectKey.isEmpty)
    #expect(!result.ossObjectETag.isEmpty)

    let pending = try await client.listPendingUploads()
    #expect(!pending.contains(where: { $0.logicalUploadID == result.logicalUploadID }))

    let resumeError: DGWControlPlane.DataGatewayClientError? = await #expect(throws: DGWControlPlane.DataGatewayClientError.self) {
        try await client.resumeUpload(logicalUploadID: "missing-logical-upload-id")
    }
    switch resumeError {
    case .resumeNotPossible(let message):
        #expect(message == "local snapshot not found: missing-logical-upload-id")
    default:
        Issue.record("unexpected resume error: \(String(describing: resumeError))")
    }
}

@Test(
    .enabled(if: runtimeIntegrationEnabled)
) func localCredentialCanExchangeForBearerToken() async throws {
    let environment = LocalStackTestEnvironment()
    let clientConfig = try environment.makeClientConfig()

    let authFactory = ControlPlaneClientFactory(
        configuration: ControlPlaneTransportConfiguration(
            endpoint: clientConfig.authEndpoint,
            security: .plaintext,
            requestTimeout: clientConfig.requestTimeout
        )
    )
    let authTransport = try authFactory.makeAuthTransport()
    let authProvider = CredentialAuthProvider(
        credentialBase64: clientConfig.credentialBase64,
        refreshBefore: clientConfig.authRefreshBefore,
        requestTimeout: clientConfig.requestTimeout,
        transport: authTransport.serviceClient
    )

    let header = try await authProvider.authorizationHeader()
    #expect(header.starts(with: "Bearer "))
}

@Test(
    .enabled(if: publicDNSIntegrationEnabled && realRuntimeIntegrationEnabled)
) func publicPathCanExchangeForBearerToken() async throws {
    let environment = AliyunOSSTestEnvironment()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "public-auth")
    let harness = try makeRealGatewayHarness(clientConfig: clientConfig)
    let response = try await harness.gatewayClient.createLogicalUpload(clientHints: ["suite": "public-dns"], restartFromUploadID: nil)

    #expect(!response.logicalUploadID.isEmpty)
}

@Test(
    .enabled(if: publicDNSIntegrationEnabled && realRuntimeIntegrationEnabled)
) func publicPathRuntimeBootstrapAndControlPlaneFlow() async throws {
    try await realAliyunRuntimeUploadFlow()
}

@Test(
    .enabled(if: publicDNSIntegrationEnabled && realDeviceInitIntegrationEnabled)
) func publicPathDeviceInitThenUploadFlow() async throws {
    try await realAliyunDeviceInitReinitAndFromConfigUploadFlow()
}

@Test(
    .enabled(if: runtimeIntegrationEnabled)
) func localGatewayDeviceInitFlow() async throws {
    let environment = LocalStackTestEnvironment()
    let initConfig = try environment.makeDeviceInitConfig()
    let configURL = uniqueConfigURL(from: initConfig.configURL)
    let initializer = try ArchebaseDeviceInitializer(
        config: DeviceInitClientConfig(configURL: configURL, tls: .plaintext),
        initEndpoint: initConfig.endpoint,
        sdkVersion: "local-integration",
        platform: "ios-simulator"
    )

    let config = try await initializer.initDevice(deviceID: initConfig.deviceID)

    #expect(!config.apiKey.isEmpty)
    #expect(try await ArchebaseConfigStore(configURL: configURL).load() == config)
}

@Test(
    .enabled(if: runtimeIntegrationEnabled)
) func localGatewayDeviceInitFailsWhenUnbound() async throws {
    let environment = LocalStackTestEnvironment()
    let initConfig = try environment.makeDeviceInitConfig()
    let unboundDeviceID = try #require(initConfig.unboundDeviceID)
    let initializer = try ArchebaseDeviceInitializer(
        config: DeviceInitClientConfig(configURL: uniqueConfigURL(from: initConfig.configURL), tls: .plaintext),
        initEndpoint: initConfig.endpoint,
        sdkVersion: "local-integration",
        platform: "ios-simulator"
    )

    let error = await #expect(throws: DataGatewayClientError.self) {
        _ = try await initializer.initDevice(deviceID: unboundDeviceID)
    }

    guard case .gatewayFailed(_, let detailCode, _) = error else {
        Issue.record("unexpected init error: \(String(describing: error))")
        return
    }
    #expect(detailCode == "DATA_GATEWAY_DEVICE_NOT_READY")
}

@Test(
    .enabled(if: runtimeIntegrationEnabled)
) func localGatewayDeviceInitRejectsLegacyUuidDeviceId() async throws {
    let environment = LocalStackTestEnvironment()
    let initConfig = try environment.makeDeviceInitConfig()
    let initializer = try ArchebaseDeviceInitializer(
        config: DeviceInitClientConfig(configURL: uniqueConfigURL(from: initConfig.configURL), tls: .plaintext),
        initEndpoint: initConfig.endpoint,
        sdkVersion: "local-integration",
        platform: "ios-simulator"
    )

    let error = await #expect(throws: DataGatewayClientError.self) {
        _ = try await initializer.initDevice(deviceID: "00000000-0000-0000-0000-000000000000")
    }

    guard case .gatewayFailed(_, let detailCode, _) = error else {
        Issue.record("unexpected init error: \(String(describing: error))")
        return
    }
    #expect(detailCode == "DATA_GATEWAY_DEVICE_ID_INVALID")
}

@Test(
    .enabled(if: runtimeIntegrationEnabled)
) func localGatewayInitThenUploadFlow() async throws {
    let environment = LocalStackTestEnvironment()
    let clientConfig = try environment.makeClientConfig()
    let initConfig = try environment.makeDeviceInitConfig()
    let configURL = uniqueConfigURL(from: initConfig.configURL)
    let initializer = try ArchebaseDeviceInitializer(
        config: DeviceInitClientConfig(configURL: configURL, tls: .plaintext),
        initEndpoint: initConfig.endpoint,
        sdkVersion: "local-integration",
        platform: "ios-simulator"
    )
    _ = try await initializer.initDevice(deviceID: initConfig.deviceID)

    let client = try await DataGatewayClient.testFromArchebaseConfig(
        authEndpoint: clientConfig.authEndpoint,
        gatewayEndpoint: clientConfig.gatewayEndpoint,
        configURL: configURL,
        persistRootURL: clientConfig.persistRootURL,
        tls: .plaintext
    )
    let fileURL = clientConfig.persistRootURL
        .appendingPathComponent("swift-local-init-upload-\(UUID().uuidString)")
        .appendingPathExtension("bin")
    let payload = Data("swift-local-init-upload-payload".utf8)
    try FileManager.default.createDirectory(at: clientConfig.persistRootURL, withIntermediateDirectories: true)
    try payload.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let result = try await client.upload(
        UploadRequest(fileURL: fileURL, clientHints: ["kind": "device-init"], rawTags: [:], displayName: "device-init")
    )

    #expect(!result.logicalUploadID.isEmpty)
    #expect(result.fileSize == UInt64(payload.count))
}

@Test(
    .enabled(if: realRuntimeIntegrationEnabled)
) func realAliyunRuntimeUploadFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let expectation = try environment.remoteUploadExpectation()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "runtime")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let client = try DataGatewayClient(config: clientConfig)

    let fileURL = clientConfig.persistRootURL
        .appendingPathComponent("aliyun-real-runtime-\(UUID().uuidString)")
        .appendingPathExtension("bin")
    let payload = Data("aliyun-real-runtime-payload-\(UUID().uuidString)".utf8)
    try FileManager.default.createDirectory(at: clientConfig.persistRootURL, withIntermediateDirectories: true)
    try payload.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let result = try await client.upload(
        UploadRequest(
            fileURL: fileURL,
            clientHints: ["suite": "aliyun-real", "mode": "swift-e2e"],
            rawTags: ["suite": "aliyun-real", "runtime": "macos"],
            displayName: "aliyun-real-runtime"
        )
    )

    #expect(!result.logicalUploadID.isEmpty)
    #expect(!result.uploadID.isEmpty)
    #expect(result.fileSize == UInt64(payload.count))
    #expect(result.bucket == expectation.bucket)
    #expect(result.objectKey.hasPrefix(expectation.objectPrefix))
    #expect(!result.ossObjectETag.isEmpty)

    let pending = try await client.listPendingUploads()
    #expect(!pending.contains(where: { $0.logicalUploadID == result.logicalUploadID }))
}

@Test(
    .enabled(if: realRuntimeIntegrationEnabled)
) func realAliyunUploadEventsFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let expectation = try environment.remoteUploadExpectation()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "events")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let client = try DataGatewayClient(config: clientConfig)
    let fileURL = try writeRealPayload(
        Data("aliyun-real-events-payload-\(UUID().uuidString)".utf8),
        under: clientConfig.persistRootURL,
        name: "aliyun-real-events"
    )

    var events: [UploadEvent] = []
    for try await event in await client.uploadEvents(
        UploadRequest(
            fileURL: fileURL,
            clientHints: ["suite": "aliyun-real", "mode": "events"],
            rawTags: ["suite": "aliyun-real", "runtime": "events"],
            displayName: "aliyun-real-events"
        )
    ) {
        events.append(event)
    }

    #expect(events.contains(.preparing))
    #expect(events.contains(.authenticating))
    #expect(events.contains(.creatingLogicalUpload))
    #expect(events.contains(where: { if case .initiatingMultipart = $0 { true } else { false } }))
    #expect(events.contains(where: { if case .uploadingPart = $0 { true } else { false } }))
    #expect(events.contains(where: { if case .completingMultipart = $0 { true } else { false } }))
    #expect(events.contains(where: { if case .completingBusinessUpload = $0 { true } else { false } }))

    guard case .completed(let result) = events.last else {
        Issue.record("real Aliyun uploadEvents did not end with completed: \(events)")
        return
    }
    #expect(result.bucket == expectation.bucket)
    #expect(result.objectKey.hasPrefix(expectation.objectPrefix))
    #expect(!result.ossObjectETag.isEmpty)
}

@Test(
    .enabled(if: realRuntimeIntegrationEnabled)
) func realAliyunMultipartUploadEventsFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let expectation = try environment.remoteUploadExpectation()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "multipart")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let client = try DataGatewayClient(config: clientConfig)
    let size = realMultipartPayloadSizeBytes()
    let fileURL = try writeRealPayload(Data(repeating: 0x5A, count: size), under: clientConfig.persistRootURL, name: "aliyun-real-multipart")

    var uploadedPartCount = 0
    var completedResult: UploadResult?
    for try await event in await client.uploadEvents(
        UploadRequest(
            fileURL: fileURL,
            clientHints: ["suite": "aliyun-real", "mode": "multipart"],
            rawTags: ["suite": "aliyun-real", "runtime": "multipart"],
            displayName: "aliyun-real-multipart"
        )
    ) {
        if case .uploadingPart = event {
            uploadedPartCount += 1
        }
        if case .completed(let result) = event {
            completedResult = result
        }
    }

    let result = try #require(completedResult)
    #expect(uploadedPartCount >= 2)
    #expect(result.fileSize == UInt64(size))
    #expect(result.bucket == expectation.bucket)
    #expect(result.objectKey.hasPrefix(expectation.objectPrefix))
    #expect(!result.ossObjectETag.isEmpty)
}

@Test(
    .enabled(if: realRuntimeIntegrationEnabled)
) func realAliyunConfigStoreFromConfigAndUploadFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let expectation = try environment.remoteUploadExpectation()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "from-config")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let configURL = clientConfig.persistRootURL.appendingPathComponent("archebase-config.json")
    let store = ArchebaseConfigStore(configURL: configURL)

    let initialConfig = try ArchebaseConfig(apiKey: clientConfig.credentialBase64, tags: ["device": "aliyun-config"])
    try initialConfig.validate()
    let decodedInitialConfig = try ArchebaseConfig.decodeValidated(from: initialConfig.prettyJSONData())
    #expect(!(await store.exists()))
    try await store.initialize(decodedInitialConfig)
    #expect(await store.exists())
    #expect(await store.resolvedConfigURL() == configURL.standardizedFileURL)
    #expect(try await store.load() == decodedInitialConfig)

    let replacedConfig = try ArchebaseConfig(
        apiKey: clientConfig.credentialBase64,
        tags: ["device": "aliyun-config", "flow": "from-config"]
    )
    try await store.replaceForReinit(replacedConfig)
    #expect(try await store.load() == replacedConfig)

    let client = try await DataGatewayClient.testFromArchebaseConfig(
        authEndpoint: clientConfig.authEndpoint,
        gatewayEndpoint: clientConfig.gatewayEndpoint,
        configURL: configURL,
        persistRootURL: clientConfig.persistRootURL,
        tls: clientConfig.tls
    )
    let fileURL = try writeRealPayload(
        Data("aliyun-real-from-config-payload-\(UUID().uuidString)".utf8),
        under: clientConfig.persistRootURL,
        name: "aliyun-real-from-config"
    )

    let result = try await client.upload(
        UploadRequest(fileURL: fileURL, clientHints: ["suite": "aliyun-real"], rawTags: ["runtime": "from-config"], displayName: "from-config")
    )

    #expect(result.bucket == expectation.bucket)
    #expect(result.objectKey.hasPrefix(expectation.objectPrefix))
    #expect(!result.ossObjectETag.isEmpty)
}

@Test(
    .enabled(if: realRuntimeIntegrationEnabled)
) func realAliyunResumeUploadFromPendingSnapshotFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let expectation = try environment.remoteUploadExpectation()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "resume")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let harness = try makeRealGatewayHarness(clientConfig: clientConfig)
    let state = try await seedActiveRealUploadSnapshot(
        clientConfig: clientConfig,
        gatewayClient: harness.gatewayClient,
        payload: Data("aliyun-real-resume-payload-\(UUID().uuidString)".utf8),
        label: "resume"
    )
    let client = try DataGatewayClient(config: clientConfig)

    let pendingBeforeResume = try await client.listPendingUploads()
    #expect(pendingBeforeResume.contains(where: { $0.logicalUploadID == state.logicalUploadID && $0.uploadID == state.uploadID }))

    let result = try await client.resumeUpload(logicalUploadID: state.logicalUploadID)

    #expect(result.logicalUploadID == state.logicalUploadID)
    #expect(result.fileSize == state.fileSize)
    #expect(result.bucket == expectation.bucket)
    #expect(result.objectKey.hasPrefix(expectation.objectPrefix))
    #expect(!result.ossObjectETag.isEmpty)
    let pendingAfterResume = try await client.listPendingUploads()
    #expect(!pendingAfterResume.contains(where: { $0.logicalUploadID == state.logicalUploadID }))
}

@Test(
    .enabled(if: realRuntimeIntegrationEnabled)
) func realAliyunAbortAndDeleteLocalSnapshotFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "abort-delete")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let harness = try makeRealGatewayHarness(clientConfig: clientConfig)
    let client = try DataGatewayClient(config: clientConfig)

    let abortState = try await seedActiveRealUploadSnapshot(
        clientConfig: clientConfig,
        gatewayClient: harness.gatewayClient,
        payload: Data("aliyun-real-abort-payload-\(UUID().uuidString)".utf8),
        label: "abort"
    )
    #expect(try await client.listPendingUploads().contains(where: { $0.logicalUploadID == abortState.logicalUploadID }))
    try await client.abortUpload(logicalUploadID: abortState.logicalUploadID)
    #expect(!(try await client.listPendingUploads().contains(where: { $0.logicalUploadID == abortState.logicalUploadID })))

    let deleteState = try await seedActiveRealUploadSnapshot(
        clientConfig: clientConfig,
        gatewayClient: harness.gatewayClient,
        payload: Data("aliyun-real-delete-local-payload-\(UUID().uuidString)".utf8),
        label: "delete-local"
    )
    #expect(try await client.listPendingUploads().contains(where: { $0.logicalUploadID == deleteState.logicalUploadID }))
    try await client.deleteLocalSnapshot(logicalUploadID: deleteState.logicalUploadID)
    #expect(!(try await client.listPendingUploads().contains(where: { $0.logicalUploadID == deleteState.logicalUploadID })))

    let cleanupResponse = try await harness.gatewayClient.abortUpload(
        logicalUploadID: deleteState.logicalUploadID,
        reason: "cleanup after local snapshot deletion"
    )
    #expect(cleanupResponse.logicalUploadID == deleteState.logicalUploadID)
}

@Test(
    .enabled(if: realDeviceInitIntegrationEnabled)
) func realAliyunDeviceInitReinitAndFromConfigUploadFlow() async throws {
    let environment = AliyunOSSTestEnvironment()
    try environment.validate()
    let expectation = try environment.remoteUploadExpectation()
    let clientConfig = try uniqueRealClientConfig(from: environment.makeRemoteClientConfig(), label: "device-init")
    defer { try? FileManager.default.removeItem(at: clientConfig.persistRootURL) }
    let deviceID = try requiredValueFromEnvironment("DGW_REAL_DEVICE_ID")
    let configURL = clientConfig.persistRootURL.appendingPathComponent("archebase-config.json")
    let initializer: ArchebaseDeviceInitializer
    if publicDNSIntegrationEnabled {
        let endpointsURL = clientConfig.persistRootURL.appendingPathComponent(ArchebasePublicEndpoints.endpointsFileName)
        initializer = try ArchebaseDeviceInitializer(
            config: DeviceInitClientConfig(configURL: configURL, endpointsURL: endpointsURL)
        )
    } else {
        let initEndpoint = try requiredURLFromEnvironment("DGW_REAL_INIT_ENDPOINT")
        let initTLS: TLSMode = initEndpoint.scheme?.lowercased() == "https" ? .tls : .plaintext
        initializer = try ArchebaseDeviceInitializer(
            config: DeviceInitClientConfig(configURL: configURL, tls: initTLS),
            initEndpoint: initEndpoint,
            sdkVersion: "aliyun-e2e",
            platform: "ios-simulator"
        )
    }

    let initializedConfig = try await initializer.initDevice(deviceID: deviceID)
    #expect(!initializedConfig.apiKey.isEmpty)
    #expect(try await ArchebaseConfigStore(configURL: configURL).load() == initializedConfig)

    let reinitializedConfig = try await initializer.reinitDevice(deviceID: deviceID)
    #expect(!reinitializedConfig.apiKey.isEmpty)
    #expect(try await ArchebaseConfigStore(configURL: configURL).load() == reinitializedConfig)

    let client = try await DataGatewayClient.testFromArchebaseConfig(
        authEndpoint: clientConfig.authEndpoint,
        gatewayEndpoint: clientConfig.gatewayEndpoint,
        configURL: configURL,
        persistRootURL: clientConfig.persistRootURL,
        tls: clientConfig.tls
    )
    let fileURL = try writeRealPayload(
        Data("aliyun-real-device-init-payload-\(UUID().uuidString)".utf8),
        under: clientConfig.persistRootURL,
        name: "aliyun-real-device-init"
    )
    let result = try await client.upload(
        UploadRequest(fileURL: fileURL, clientHints: ["suite": "aliyun-real-device-init"], rawTags: ["runtime": "device-init"], displayName: "device-init")
    )

    #expect(result.bucket == expectation.bucket)
    #expect(result.objectKey.hasPrefix(expectation.objectPrefix))
    #expect(!result.ossObjectETag.isEmpty)
}

}

private func uniqueConfigURL(from baseURL: URL) -> URL {
    baseURL
        .deletingLastPathComponent()
        .appendingPathComponent("archebase-config-\(UUID().uuidString).json")
}

private struct RealGatewayHarness {
    let authTransport: ManagedControlPlaneServiceClient<any CredentialExchangeTransport>
    let gatewayTransport: ManagedControlPlaneServiceClient<Archebase_DataGateway_V1_DataGatewayService.Client<HTTP2ClientTransport.TransportServices>>
    let gatewayClient: AnyUploadCoordinatorGatewayClient
}

private func uniqueRealClientConfig(from config: DataGatewayClientConfig, label: String) throws -> DataGatewayClientConfig {
    var copy = config
    let originalPersistRoot = config.persistRootURL
    copy.persistRootURL = config.persistRootURL
        .appendingPathComponent("aliyun-real-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: copy.persistRootURL, withIntermediateDirectories: true)
    let originalEndpointsURL = originalPersistRoot.appendingPathComponent(ArchebasePublicEndpoints.endpointsFileName)
    if FileManager.default.fileExists(atPath: originalEndpointsURL.path) {
        try FileManager.default.copyItem(
            at: originalEndpointsURL,
            to: copy.persistRootURL.appendingPathComponent(ArchebasePublicEndpoints.endpointsFileName)
        )
    }
    return copy
}

private func writeRealPayload(_ payload: Data, under root: URL, name: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
        .appendingPathExtension("bin")
    try payload.write(to: fileURL)
    return fileURL
}

private func realMultipartPayloadSizeBytes() -> Int {
    if let value = ProcessInfo.processInfo.environment["DGW_REAL_MULTIPART_SIZE_BYTES"],
        let parsed = Int(value),
        parsed > 0 {
        return parsed
    }
    return 67_108_864 + 1024
}

private func makeRealGatewayHarness(clientConfig: DataGatewayClientConfig) throws -> RealGatewayHarness {
    let security: ControlPlaneTransportSecurity = switch clientConfig.tls {
    case .plaintext: .plaintext
    case .tls: .tls
    }
    let authFactory = ControlPlaneClientFactory(
        configuration: ControlPlaneTransportConfiguration(
            endpoint: clientConfig.authEndpoint,
            security: security,
            requestTimeout: clientConfig.requestTimeout
        )
    )
    let authTransport = try authFactory.makeAuthTransport()
    let authProvider = CredentialAuthProvider(
        credentialBase64: clientConfig.credentialBase64,
        refreshBefore: clientConfig.authRefreshBefore,
        requestTimeout: clientConfig.requestTimeout,
        transport: authTransport.serviceClient
    )
    let gatewayTransport = try ManagedControlPlaneServiceClient(
        configuration: ControlPlaneTransportConfiguration(
            endpoint: clientConfig.gatewayEndpoint,
            security: security,
            requestTimeout: clientConfig.requestTimeout
        )
    ) { grpcClient in
        Archebase_DataGateway_V1_DataGatewayService.Client(wrapping: grpcClient)
    }
    let gatewayClient = AnyUploadCoordinatorGatewayClient(
        authProvider: authProvider,
        gatewayServiceClient: gatewayTransport.serviceClient,
        requestTimeout: clientConfig.requestTimeout,
        retryPolicy: clientConfig.retryPolicy.controlPlane.controlPlaneValue
    )
    return RealGatewayHarness(authTransport: authTransport, gatewayTransport: gatewayTransport, gatewayClient: gatewayClient)
}

private func seedActiveRealUploadSnapshot(
    clientConfig: DataGatewayClientConfig,
    gatewayClient: AnyUploadCoordinatorGatewayClient,
    payload: Data,
    label: String
) async throws -> PersistedUploadState {
    let sourceURL = try writeRealPayload(payload, under: clientConfig.persistRootURL, name: "aliyun-real-\(label)-source")
    let fileCoordinator = FileStagingCoordinator(
        stagingRoot: clientConfig.persistRootURL
            .appendingPathComponent("data-gateway-client", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    )
    let request = UploadRequest(
        fileURL: sourceURL,
        clientHints: ["suite": "aliyun-real", "mode": label],
        rawTags: ["suite": "aliyun-real", "runtime": label],
        displayName: "aliyun-real-\(label)"
    )
    let prepared = try fileCoordinator.prepare(
        request: request,
        persistence: LocalPersistencePolicy(
            keepTerminalSnapshot: clientConfig.execution.persistence.keepTerminalSnapshot,
            keepCompletedSnapshot: clientConfig.execution.persistence.keepCompletedSnapshot,
            completedSnapshotTTL: clientConfig.execution.persistence.completedSnapshotTTL,
            terminalSnapshotTTL: clientConfig.execution.persistence.terminalSnapshotTTL,
            copyExternalFileIntoManagedStaging: false
        )
    )
    let response = try await gatewayClient.createLogicalUpload(clientHints: request.clientHints, restartFromUploadID: nil)
    let createdAt = Date()
    let state = PersistedUploadState(
        version: 1,
        logicalUploadID: response.logicalUploadID,
        uploadID: response.uploadID,
        restartCount: 0,
        multipartUploadID: nil,
        bucket: response.credentials.bucket,
        endpoint: response.credentials.endpoint,
        objectKey: response.credentials.objectKey,
        fileURLBookmarkData: prepared.bookmarkData,
        managedFileURL: prepared.managedFileURL,
        fileSize: prepared.fileSize,
        fileFingerprint: prepared.fingerprint,
        partSizeBytes: UInt64(response.credentials.partSizeBytes),
        uploadedParts: [],
        clientHints: request.clientHints,
        rawTags: request.rawTags,
        phase: .sessionCreated,
        lastKnownSTSExpireAt: Date(timeIntervalSince1970: TimeInterval(response.credentials.stsExpireAtUnix)),
        createdAt: createdAt,
        updatedAt: createdAt
    )
    try await UploadStateStore(persistRoot: clientConfig.persistRootURL).saveActive(state)
    return state
}

private func requiredValueFromEnvironment(_ key: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        throw AliyunOSSHarnessError.missingEnvironmentVariable(key)
    }
    return value
}

private func requiredURLFromEnvironment(_ key: String) throws -> URL {
    let value = try requiredValueFromEnvironment(key)
    guard let url = URL(string: value), url.host?.isEmpty == false else {
        throw LocalStackHarnessError.invalidEndpoint(key)
    }
    return url
}
