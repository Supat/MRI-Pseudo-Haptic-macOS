//
//  FrameProcessor.swift
//
//  Glue layer that consumes CameraFrames from the VimbaCamera publisher,
//  runs hand + pose landmarking on a dedicated serial queue, computes the
//  wrist angle, and republishes the combined result to the UI and the
//  TCP broadcaster.
//

import Foundation
import CoreVideo
import Combine
import QuartzCore

/// Everything the UI needs to render a single processed frame.
struct ProcessedFrame {
    let pixelBuffer: CVPixelBuffer
    let imageSize: CGSize
    let hand: HandLandmarkFrame?
    let pose: PoseLandmarkFrame?
    let wrist: WristAngleResult?
    let processingLatencyMs: Double
}

/// Drives the detection pipeline for incoming camera frames.
final class FrameProcessor: ObservableObject {

    @Published private(set) var latest: ProcessedFrame?
    @Published private(set) var lastError: String?

    /// Set this to receive wrist angle updates on the main actor. Used by
    /// the network broadcaster.
    var wristAngleSink: ((WristAngleResult) -> Void)?

    private let processingQueue = DispatchQueue(
        label: "com.mri.pseudohaptic.frameprocessor",
        qos: .userInteractive
    )
    private var handService: HandLandmarkerService?
    private var poseService: PoseLandmarkerService?
    private var calculator = WristAngleCalculator()

    // Serializes `inFlight` access because `submit` is called from the
    // Vimba capture thread while the completion side runs on our
    // processing queue.
    private let inFlightLock = NSLock()
    private var inFlight = false

    init() {
        do {
            self.handService = try HandLandmarkerService(maxHands: 1)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = error.localizedDescription
            }
        }
        do {
            self.poseService = try PoseLandmarkerService()
        } catch {
            // Pose landmarker is optional — if it's missing we fall back
            // to the crude "forearm points up" assumption.
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Pose landmarker unavailable: \(error.localizedDescription)"
            }
        }
    }

    /// Submit a new camera frame. Drops frames if the previous one is
    /// still being processed so we never back up.
    func submit(frame: CameraFrame) {
        inFlightLock.lock()
        if inFlight {
            inFlightLock.unlock()
            return
        }
        inFlight = true
        inFlightLock.unlock()

        // Retain the pixel buffer explicitly across the queue hop.
        let pixelBuffer = frame.pixelBuffer

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.inFlightLock.lock()
                self.inFlight = false
                self.inFlightLock.unlock()
            }

            let started = CACurrentMediaTime()
            let timestampMs = Int(frame.presentationTime.seconds * 1000.0)
            let size = CGSize(width: frame.width, height: frame.height)

            var hand: HandLandmarkFrame?
            var pose: PoseLandmarkFrame?

            do {
                hand = try self.handService?.detect(pixelBuffer: pixelBuffer,
                                                    timestampMs: timestampMs).first
            } catch {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
            }

            do {
                pose = try self.poseService?.detect(pixelBuffer: pixelBuffer,
                                                    timestampMs: timestampMs)
            } catch {
                // Non-fatal: keep the hand-only path alive.
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
            }

            var wristResult: WristAngleResult?
            if let hand = hand {
                wristResult = self.calculator.compute(hand: hand, pose: pose)
            } else {
                self.calculator.reset()
            }

            let elapsedMs = (CACurrentMediaTime() - started) * 1000.0
            let processed = ProcessedFrame(
                pixelBuffer: pixelBuffer,
                imageSize: size,
                hand: hand,
                pose: pose,
                wrist: wristResult,
                processingLatencyMs: elapsedMs
            )

            DispatchQueue.main.async {
                self.latest = processed
                if let wrist = wristResult, wrist.isValid {
                    self.wristAngleSink?(wrist)
                }
            }
        }
    }
}
