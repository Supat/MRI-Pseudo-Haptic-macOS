//
//  AppState.swift
//
//  Top-level observable that wires the Vimba camera, the FrameProcessor,
//  and the TCP broadcaster together and exposes their status to SwiftUI.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published UI state

    @Published var availableCameras: [VimbaCameraDescriptor] = []
    @Published var selectedCameraID: String?
    @Published var isStreaming: Bool = false
    @Published var statusMessage: String = "Idle"
    @Published var broadcasterStatus: String = "Stopped"
    @Published var connectedClients: Int = 0
    @Published var broadcastPort: UInt16 = 45123
    @Published var lastProcessingLatencyMs: Double = 0
    @Published var wristAngle: WristAngleResult?
    @Published var latestFrame: ProcessedFrame?

    // MARK: - Pipeline components

    let frameProcessor = FrameProcessor()
    private let camera = VimbaCamera()
    private var broadcaster: WristAngleBroadcaster?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Mirror the latest processed frame into the published wrist angle
        // so the HUD updates via SwiftUI bindings.
        frameProcessor.$latest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processed in
                guard let self = self else { return }
                self.latestFrame = processed
                self.lastProcessingLatencyMs = processed.processingLatencyMs
                if let wrist = processed.wrist {
                    self.wristAngle = wrist
                }
            }
            .store(in: &cancellables)

        frameProcessor.wristAngleSink = { [weak self] result in
            self?.broadcaster?.publish(result)
        }
    }

    // MARK: - Camera enumeration

    func refreshCameras() {
        do {
            availableCameras = try VimbaCamera.discover()
            if selectedCameraID == nil {
                selectedCameraID = availableCameras.first?.id
            }
            statusMessage = availableCameras.isEmpty
                ? "No GigE cameras discovered."
                : "Found \(availableCameras.count) camera(s)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Streaming

    func startStreaming() {
        guard !isStreaming else { return }
        guard let id = selectedCameraID,
              let descriptor = availableCameras.first(where: { $0.id == id }) else {
            statusMessage = "Select a camera first."
            return
        }

        // Frames are published on the Vimba capture thread; submit them
        // directly to the processor (which has its own serial queue) to
        // avoid a pointless main-thread round trip.
        camera.frames
            .sink { [weak self] frame in
                self?.frameProcessor.submit(frame: frame)
            }
            .store(in: &cancellables)

        camera.errors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.statusMessage = error.localizedDescription
            }
            .store(in: &cancellables)

        do {
            try camera.start(with: descriptor)
            isStreaming = true
            statusMessage = "Streaming from \(descriptor.model)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func stopStreaming() {
        camera.stop()
        isStreaming = false
        statusMessage = "Stopped"
    }

    // MARK: - Broadcaster

    func startBroadcaster() {
        let b = WristAngleBroadcaster(port: broadcastPort)
        b.delegate = BroadcasterDelegateRelay(appState: self)
        do {
            try b.start()
            broadcaster = b
        } catch {
            broadcasterStatus = "Error: \(error.localizedDescription)"
        }
    }

    func stopBroadcaster() {
        broadcaster?.stop()
        broadcaster = nil
        broadcasterStatus = "Stopped"
        connectedClients = 0
    }

    // MARK: - Teardown

    func shutdown() {
        stopStreaming()
        stopBroadcaster()
        VimbaCamera.shutdownVimbaSystem()
    }
}

/// NWListener's delegate has to be an NSObject-friendly reference type;
/// this tiny relay forwards callbacks into the MainActor AppState.
private final class BroadcasterDelegateRelay: NSObject, WristAngleBroadcasterDelegate {
    weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func broadcaster(_ broadcaster: WristAngleBroadcaster, didChangeState state: String) {
        Task { @MainActor in
            self.appState?.broadcasterStatus = state
        }
    }

    func broadcaster(_ broadcaster: WristAngleBroadcaster, didChangeClientCount count: Int) {
        Task { @MainActor in
            self.appState?.connectedClients = count
        }
    }
}
