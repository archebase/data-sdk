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

package struct DefaultQiongcheDeviceProvisioner: QiongcheDeviceProvisioning {
    package init() {}

    package func initDevice(
        deviceID: String,
        deviceInitEndpoint: URL,
        tls: TLSMode,
        timeout: Duration
    ) async throws -> ArchebaseConfig {
        try DataGatewayClientConfig.validate(endpoint: deviceInitEndpoint, tls: tls, fieldName: "deviceInitEndpoint")

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
        defer {
            managedTransport.shutdown()
        }

        do {
            let response = try await managedTransport.serviceClient.initDevice(
                deviceID: deviceID,
                sdkVersion: DataGatewayClientModule.version,
                platform: "ios"
            )
            return try ArchebaseConfig(apiKey: response.apiKey, tags: response.tags)
        } catch let error as DataGatewayClientError {
            throw error
        } catch {
            throw ControlPlaneErrorMapper.map(error)
        }
    }
}
