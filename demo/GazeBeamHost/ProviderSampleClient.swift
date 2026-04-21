import Foundation
import GazeProtocolKit
import Network

final class ProviderSampleClient: @unchecked Sendable {
    enum Event: Sendable {
        case stateChanged(String)
        case connecting(String)
        case connected(String)
        case connectionFailed(String)
        case disconnected(String)
        case receivedSample(ProviderSamplePayload)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let endpoint: String
    private var decoder = WireEnvelopeStreamDecoder()
    private var isStopped = false

    init(host: String, port: UInt16, queue: DispatchQueue = DispatchQueue(label: "gaze.beam.host.usb.client")) {
        self.queue = queue
        endpoint = "\(host):\(port)"
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func start() {
        onEvent?(.connecting(endpoint))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .setup:
                self.onEvent?(.stateChanged("setup \(self.endpoint)"))
            case .preparing:
                self.onEvent?(.stateChanged("preparing \(self.endpoint)"))
            case .waiting(let error):
                self.onEvent?(.stateChanged("waiting on \(self.endpoint): \(error.localizedDescription)"))
            case .ready:
                self.onEvent?(.connected(self.endpoint))
                self.receiveNext()
            case .failed(let error):
                self.onEvent?(.connectionFailed(error.localizedDescription))
                self.finish(notifyDisconnect: false)
            case .cancelled:
                self.onEvent?(.stateChanged("cancelled \(self.endpoint)"))
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
                    self.onEvent?(.stateChanged("sample decode failed from \(self.endpoint): \(error.localizedDescription)"))
                    self.finish()
                    return
                }
            }

            if let error {
                self.onEvent?(.stateChanged("receive error from \(self.endpoint): \(error.localizedDescription)"))
            }
            if isComplete {
                self.onEvent?(.stateChanged("stream completed from \(self.endpoint)"))
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

    private func finish(notifyDisconnect: Bool = true) {
        guard !isStopped else {
            return
        }
        isStopped = true
        connection.cancel()
        if notifyDisconnect {
            onEvent?(.disconnected(endpoint))
        }
    }
}
