import Foundation
import Network

public final class ProviderStreamClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()

    public init(host: String, port: UInt16, queue: DispatchQueue = DispatchQueue(label: "gaze.provider.stream")) {
        self.queue = queue
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    public func start() {
        connection.start(queue: queue)
    }

    public func stop() {
        connection.cancel()
    }

    public func sendSample(_ sample: ProviderSamplePayload) {
        let payload = BinarySampleCodec.encode(sample)
        let envelope = WireEnvelope(channel: .data, kind: DataMessageKind.providerSample.rawValue, payload: payload)
        connection.send(content: envelope.encode(), completion: .contentProcessed { _ in })
    }

    public func sendControl<Payload: Codable & Sendable>(_ kind: ControlMessageKind, payload: Payload) throws {
        let message = ControlMessageEnvelope(kind: kind, payload: payload)
        let encoded = try encoder.encode(message)
        let envelope = WireEnvelope(channel: .control, kind: 1, payload: encoded)
        connection.send(content: envelope.encode(), completion: .contentProcessed { _ in })
    }
}
