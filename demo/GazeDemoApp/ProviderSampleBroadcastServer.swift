import Foundation
import GazeProtocolKit
import Network

final class ProviderSampleBroadcastServer: @unchecked Sendable {
    enum Event: Sendable {
        case listenerReady(UInt16)
        case listenerFailed(String)
        case clientConnected(String)
        case clientDisconnected(String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "gaze.demo.usb.broadcast")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: BroadcastConnection] = [:]

    func start(port: UInt16) throws {
        stop()

        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onEvent?(.listenerReady(port))
            case .failed(let error):
                self?.onEvent?(.listenerFailed(error.localizedDescription))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients.values {
            client.stop()
        }
        clients.removeAll()
    }

    func broadcast(_ sample: ProviderSamplePayload) {
        let payload = BinarySampleCodec.encode(sample)
        let envelope = WireEnvelope(
            channel: .data,
            kind: DataMessageKind.providerSample.rawValue,
            payload: payload
        ).encode()

        queue.async { [weak self] in
            guard let self else {
                return
            }
            for client in self.clients.values {
                client.send(envelope)
            }
        }
    }

    private func accept(connection: NWConnection) {
        let endpoint = connection.endpoint.debugDescription
        let client = BroadcastConnection(connection: connection, endpoint: endpoint)
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client

        client.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
        client.onTermination = { [weak self] in
            self?.clients.removeValue(forKey: identifier)
        }
        client.start(on: queue)
    }
}

private final class BroadcastConnection: @unchecked Sendable {
    var onEvent: (@Sendable (ProviderSampleBroadcastServer.Event) -> Void)?
    var onTermination: (() -> Void)?

    private let connection: NWConnection
    private let endpoint: String
    private var isReady = false
    private var isStopped = false

    init(connection: NWConnection, endpoint: String) {
        self.connection = connection
        self.endpoint = endpoint
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .ready:
                self.isReady = true
                self.onEvent?(.clientConnected(self.endpoint))
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ payload: Data) {
        guard isReady, !isStopped else {
            return
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self, error != nil else {
                return
            }
            self.finish()
        })
    }

    func stop() {
        finish()
    }

    private func finish() {
        guard !isStopped else {
            return
        }
        isStopped = true
        connection.cancel()
        onEvent?(.clientDisconnected(endpoint))
        onTermination?()
    }
}
