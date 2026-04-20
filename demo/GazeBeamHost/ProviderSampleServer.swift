import Foundation
import GazeProtocolKit
import Network

final class ProviderSampleServer: @unchecked Sendable {
    enum Event: Sendable {
        case listenerReady(UInt16)
        case listenerFailed(String)
        case clientConnected(String)
        case clientDisconnected(String)
        case receivedSample(ProviderSamplePayload)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "gaze.beam.host.listener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionHandler] = [:]

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
        for handler in connections.values {
            handler.stop()
        }
        connections.removeAll()
    }

    private func accept(connection: NWConnection) {
        let endpoint = connection.endpoint.debugDescription
        let handler = ConnectionHandler(connection: connection, endpoint: endpoint)
        let identifier = ObjectIdentifier(handler)
        connections[identifier] = handler

        handler.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
        handler.onTermination = { [weak self] in
            self?.connections.removeValue(forKey: identifier)
        }
        handler.start(on: queue)
    }
}

private final class ConnectionHandler: @unchecked Sendable {
    var onEvent: (@Sendable (ProviderSampleServer.Event) -> Void)?
    var onTermination: (() -> Void)?

    private let connection: NWConnection
    private let endpoint: String
    private var decoder = WireEnvelopeStreamDecoder()
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
                self.onEvent?(.clientConnected(self.endpoint))
                self.receiveNext()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        finish()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                do {
                    try self.consume(data: data)
                } catch {
                    self.finish()
                    return
                }
            }

            if isComplete || error != nil {
                self.finish()
                return
            }

            self.receiveNext()
        }
    }

    private func consume(data: Data) throws {
        decoder.append(data)
        while let envelope = try decoder.nextEnvelope() {
            guard envelope.channel == .data else {
                continue
            }
            guard envelope.kind == DataMessageKind.providerSample.rawValue else {
                continue
            }
            let sample = try BinarySampleCodec.decode(envelope.payload)
            onEvent?(.receivedSample(sample))
        }
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
