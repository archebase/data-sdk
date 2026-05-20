import DGWControlPlane
import DGWStore
import Foundation

package protocol QiongcheDeviceProvisioning: Sendable {
    func initDevice(
        deviceID: String,
        deviceInitEndpoint: URL,
        tls: TLSMode,
        timeout: Duration
    ) async throws -> ArchebaseConfig
}

package struct QiongcheDeviceInitTransportHandle: Sendable {
    package let serviceClient: any DeviceInitTransport
    private let shutdownHandler: @Sendable () -> Void

    package init(
        serviceClient: any DeviceInitTransport,
        shutdown: @escaping @Sendable () -> Void
    ) {
        self.serviceClient = serviceClient
        self.shutdownHandler = shutdown
    }

    package func shutdown() {
        self.shutdownHandler()
    }
}

package struct DefaultQiongcheDeviceProvisioner: QiongcheDeviceProvisioning {
    private let makeTransport: @Sendable (URL, TLSMode, Duration) throws -> QiongcheDeviceInitTransportHandle

    package init(
        makeTransport: @escaping @Sendable (URL, TLSMode, Duration) throws -> QiongcheDeviceInitTransportHandle = Self.makeDefaultTransport
    ) {
        self.makeTransport = makeTransport
    }

    package func initDevice(
        deviceID: String,
        deviceInitEndpoint: URL,
        tls: TLSMode,
        timeout: Duration
    ) async throws -> ArchebaseConfig {
        try DataGatewayClientConfig.validate(endpoint: deviceInitEndpoint, tls: tls, fieldName: "deviceInitEndpoint")

        let transport = try self.makeTransport(deviceInitEndpoint, tls, timeout)
        defer {
            transport.shutdown()
        }

        do {
            return try await Self.remoteConfig(deviceID: deviceID, transport: transport.serviceClient, mode: .initDevice)
        } catch let error as DataGatewayClientError where error.isDeviceAlreadyInitialized {
            return try await Self.remoteConfig(deviceID: deviceID, transport: transport.serviceClient, mode: .reinitDevice)
        }
    }

    private static func makeDefaultTransport(
        deviceInitEndpoint: URL,
        tls: TLSMode,
        timeout: Duration
    ) throws -> QiongcheDeviceInitTransportHandle {
        let security: ControlPlaneTransportSecurity = switch tls {
        case .plaintext: .plaintext
        case .tls: .tls
        }
        let factory = ControlPlaneClientFactory(
            configuration: ControlPlaneTransportConfiguration(
                endpoint: deviceInitEndpoint,
                security: security,
                requestTimeout: timeout
            )
        )
        let managedTransport = try factory.makeDeviceInitTransport()
        return QiongcheDeviceInitTransportHandle(
            serviceClient: managedTransport.serviceClient,
            shutdown: {
                managedTransport.shutdown()
            }
        )
    }

    private static func remoteConfig(
        deviceID: String,
        transport: any DeviceInitTransport,
        mode: DeviceInitRemoteMode
    ) async throws -> ArchebaseConfig {
        do {
            let response = switch mode {
            case .initDevice:
                try await transport.initDevice(
                    deviceID: deviceID,
                    sdkVersion: DataGatewayClientModule.version,
                    platform: "ios"
                )
            case .reinitDevice:
                try await transport.reinitDevice(
                    deviceID: deviceID,
                    sdkVersion: DataGatewayClientModule.version,
                    platform: "ios"
                )
            }
            return try ArchebaseConfig(apiKey: response.apiKey, tags: response.tags)
        } catch let error as DataGatewayClientError {
            throw error
        } catch {
            throw ControlPlaneErrorMapper.map(error)
        }
    }
}

private enum DeviceInitRemoteMode {
    case initDevice
    case reinitDevice
}

private extension DataGatewayClientError {
    var isDeviceAlreadyInitialized: Bool {
        guard case .gatewayFailed(_, let detailCode, _) = self else {
            return false
        }
        return detailCode == DeviceInitGatewayDetailCode.alreadyInitialized
    }
}
