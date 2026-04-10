//
//  WristAngleBroadcaster.swift
//
//  Lightweight TCP server that listens on the loopback interface and
//  streams newline-delimited JSON wrist angle updates to every connected
//  client. Built on Apple's Network framework.
//
//  Wire format (one line per sample):
//      {"t":1712760000.123,"angle":-12.5,"class":"Extensor","valid":true}
//

import Foundation
import Network

protocol WristAngleBroadcasterDelegate: AnyObject {
    func broadcaster(_ broadcaster: WristAngleBroadcaster, didChangeState state: String)
    func broadcaster(_ broadcaster: WristAngleBroadcaster, didChangeClientCount count: Int)
}

final class WristAngleBroadcaster {

    /// Port the loopback server listens on. Defaults to 45123; override in
    /// the UI if you need something else.
    let port: NWEndpoint.Port

    weak var delegate: WristAngleBroadcasterDelegate?

    private let queue = DispatchQueue(label: "com.mri.pseudohaptic.broadcaster")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    init(port: UInt16 = 45123) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 45123
    }

    // MARK: - Lifecycle

    /// Starts listening on 127.0.0.1:<port>.
    func start() throws {
        stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        // Bind explicitly to the loopback address so the server is never
        // reachable from outside the machine.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: port
        )

        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            let label: String
            switch state {
            case .setup: label = "Setup"
            case .waiting(let err): label = "Waiting (\(err.localizedDescription))"
            case .ready: label = "Listening on 127.0.0.1:\(self.port.rawValue)"
            case .failed(let err): label = "Failed: \(err.localizedDescription)"
            case .cancelled: label = "Cancelled"
            @unknown default: label = "Unknown"
            }
            DispatchQueue.main.async {
                self.delegate?.broadcaster(self, didChangeState: label)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }

        listener.start(queue: queue)
    }

    /// Stops the server and closes every live client.
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
            self.notifyClientCount()
        }
    }

    // MARK: - Publishing

    /// Encodes and sends the given wrist angle result to every live
    /// client. Safe to call from any thread.
    func publish(_ result: WristAngleResult) {
        let payload = AnglePayload(
            t: Date().timeIntervalSince1970,
            angle: result.angleDegrees,
            classification: result.classification.rawValue,
            valid: result.isValid
        )
        guard var data = try? encoder.encode(payload) else { return }
        data.append(0x0A)  // newline terminator

        queue.async { [weak self] in
            guard let self = self else { return }
            for connection in self.connections.values where connection.state == .ready {
                connection.send(content: data,
                                completion: .idempotent)
            }
        }
    }

    // MARK: - Private helpers

    private func accept(connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.connections[key] = connection
                    self.notifyClientCount()
                }
            case .failed, .cancelled:
                self.queue.async {
                    self.connections.removeValue(forKey: key)
                    self.notifyClientCount()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func notifyClientCount() {
        let count = connections.count
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.broadcaster(self, didChangeClientCount: count)
        }
    }

    // MARK: - Payload

    private struct AnglePayload: Encodable {
        let t: TimeInterval
        let angle: Double
        let classification: String
        let valid: Bool

        enum CodingKeys: String, CodingKey {
            case t, angle
            case classification = "class"
            case valid
        }
    }
}
