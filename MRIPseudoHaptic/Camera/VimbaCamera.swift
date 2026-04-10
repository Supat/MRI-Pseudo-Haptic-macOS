//
//  VimbaCamera.swift
//
//  Idiomatic Swift wrapper over the Objective-C++ `VimbaBridge`.
//  Publishes a CVPixelBuffer stream that downstream components (MediaPipe,
//  the SwiftUI preview) can subscribe to.
//

import Foundation
import CoreVideo
import CoreMedia
import Combine

/// Lightweight Swift-friendly camera description.
struct VimbaCameraDescriptor: Identifiable, Hashable {
    let id: String           // Vimba camera ID
    let model: String
    let serial: String
    let interfaceId: String

    init(info: VimbaCameraInfo) {
        self.id = info.cameraId
        self.model = info.modelName
        self.serial = info.serialNumber
        self.interfaceId = info.interfaceId
    }
}

/// A single frame emitted by the camera.
struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let width: Int
    let height: Int
}

/// Errors surfaced by the Swift camera layer.
enum VimbaCameraError: LocalizedError {
    case startupFailed(Error)
    case noCamerasFound
    case openFailed(Error)
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .startupFailed(let e): return "Vimba startup failed: \(e.localizedDescription)"
        case .noCamerasFound: return "No GigE Vision cameras were discovered."
        case .openFailed(let e): return "Failed to open camera: \(e.localizedDescription)"
        case .streamFailed(let e): return "Streaming failed: \(e.localizedDescription)"
        }
    }
}

/// Main Swift-facing camera object. Holds a single `VimbaBridge` instance
/// and re-publishes its callback-based stream as a Combine publisher.
final class VimbaCamera {

    private var bridge: VimbaBridge?
    private let frameSubject = PassthroughSubject<CameraFrame, Never>()
    private let errorSubject = PassthroughSubject<Error, Never>()

    /// Stream of frames from the currently-active camera, published on the
    /// bridge's private capture queue. Subscribers should hop to their own
    /// queue before doing expensive work.
    var frames: AnyPublisher<CameraFrame, Never> {
        frameSubject.eraseToAnyPublisher()
    }

    /// Stream of transport-layer or decoding errors.
    var errors: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    /// Enumerates all currently-visible cameras. Starts the Vimba system
    /// if necessary.
    static func discover() throws -> [VimbaCameraDescriptor] {
        do {
            try startVimbaSystem()
        } catch {
            throw VimbaCameraError.startupFailed(error)
        }
        return VimbaBridge.availableCameras().map(VimbaCameraDescriptor.init)
    }

    /// Opens the given camera and starts continuous streaming.
    func start(with descriptor: VimbaCameraDescriptor) throws {
        try Self.startVimbaSystem()

        let bridge = VimbaBridge(cameraId: descriptor.id)
        do {
            try bridge.openAndConfigure()
        } catch {
            throw VimbaCameraError.openFailed(error)
        }

        bridge.errorHandler = { [weak self] error in
            self?.errorSubject.send(error)
        }

        let handler: VimbaFrameHandler = { [weak self] pixelBuffer, pts in
            guard let self = self else { return }
            let frame = CameraFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: pts,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            self.frameSubject.send(frame)
        }

        do {
            try bridge.startStreaming(with: handler)
        } catch {
            throw VimbaCameraError.streamFailed(error)
        }

        self.bridge = bridge
    }

    /// Stops streaming and releases the underlying camera handle.
    func stop() {
        bridge?.stopStreaming()
        bridge?.close()
        bridge = nil
    }

    // MARK: - Private helpers

    private static var didStartSystem = false
    private static let startupQueue = DispatchQueue(label: "com.mri.pseudohaptic.vimba.startup")

    fileprivate static func startVimbaSystem() throws {
        try startupQueue.sync {
            guard !didStartSystem else { return }
            try VimbaBridge.startup()
            didStartSystem = true
        }
    }

    static func shutdownVimbaSystem() {
        startupQueue.sync {
            guard didStartSystem else { return }
            VimbaBridge.shutdown()
            didStartSystem = false
        }
    }
}

// MARK: - Notes on Obj-C bridging
//
// `VimbaBridge` is declared in Obj-C with `-(BOOL)…WithError:(NSError **)`
// signatures, so Swift automatically bridges them to `throws`-returning
// methods:
//     VimbaBridge.startup()                    throws
//     bridge.openAndConfigure()                throws
//     bridge.startStreaming(with: handler)     throws
// No hand-rolled wrappers are needed.
