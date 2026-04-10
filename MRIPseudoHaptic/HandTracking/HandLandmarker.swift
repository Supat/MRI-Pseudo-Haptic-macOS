//
//  HandLandmarker.swift
//
//  Thin Swift wrapper around MediaPipe Tasks Vision HandLandmarker.
//  Depends on the `MediaPipeTasksVision` framework (distributed as an
//  xcframework). See README for how to install it.
//

import Foundation
import CoreVideo
import CoreImage
import CoreGraphics
import AppKit
import MediaPipeTasksVision

/// A single 21-point hand landmark set plus the detection metadata we care
/// about downstream (handedness, score).
struct HandLandmarkFrame {
    /// Normalized image-space coordinates (x, y in [0, 1]) for all 21
    /// MediaPipe hand landmarks.
    var landmarks: [CGPoint]

    /// Optional z components, in the same space as x and y, useful for
    /// pseudo-3D angle math.
    var depth: [CGFloat]

    /// "Left" or "Right" as labelled by MediaPipe. Note that MediaPipe
    /// reports handedness in the mirrored-image convention (i.e. treats
    /// the image as if it were a selfie), so flip if you are capturing
    /// with a non-mirrored GigE camera.
    var handedness: String

    var handednessScore: Float

    /// Size of the image the landmarks were computed on, so the caller can
    /// unnormalize back to pixel space.
    var imageSize: CGSize

    /// Convenience accessors using the MediaPipe landmark index convention.
    /// https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker
    enum Landmark: Int {
        case wrist = 0
        case thumbCMC = 1, thumbMCP = 2, thumbIP = 3, thumbTip = 4
        case indexMCP = 5, indexPIP = 6, indexDIP = 7, indexTip = 8
        case middleMCP = 9, middlePIP = 10, middleDIP = 11, middleTip = 12
        case ringMCP = 13, ringPIP = 14, ringDIP = 15, ringTip = 16
        case pinkyMCP = 17, pinkyPIP = 18, pinkyDIP = 19, pinkyTip = 20
    }

    func point(_ landmark: Landmark) -> CGPoint {
        landmarks[landmark.rawValue]
    }

    func pixelPoint(_ landmark: Landmark) -> CGPoint {
        let p = landmarks[landmark.rawValue]
        return CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)
    }
}

/// Errors surfaced by the hand landmarker.
enum HandLandmarkerError: LocalizedError {
    case modelFileMissing(String)
    case initializationFailed(Error)
    case detectionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelFileMissing(let name):
            return "Could not find \(name) in the app bundle. Download hand_landmarker.task from Google and add it to the project's Models folder."
        case .initializationFailed(let e):
            return "HandLandmarker init failed: \(e.localizedDescription)"
        case .detectionFailed(let e):
            return "HandLandmarker detect failed: \(e.localizedDescription)"
        }
    }
}

/// Wraps the MediaPipe `HandLandmarker` task. Configured for live-stream
/// video (`.video` running mode) so we can pass successive frames in order.
final class HandLandmarkerService {

    private let landmarker: HandLandmarker
    private let maxHands: Int

    init(modelFileName: String = "hand_landmarker",
         maxHands: Int = 1,
         minDetectionConfidence: Float = 0.5,
         minPresenceConfidence: Float = 0.5,
         minTrackingConfidence: Float = 0.5) throws {

        guard let modelPath = Bundle.main.path(forResource: modelFileName,
                                               ofType: "task") else {
            throw HandLandmarkerError.modelFileMissing("\(modelFileName).task")
        }

        let options = HandLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video
        options.numHands = maxHands
        options.minHandDetectionConfidence = minDetectionConfidence
        options.minHandPresenceConfidence = minPresenceConfidence
        options.minTrackingConfidence = minTrackingConfidence

        do {
            self.landmarker = try HandLandmarker(options: options)
        } catch {
            throw HandLandmarkerError.initializationFailed(error)
        }
        self.maxHands = maxHands
    }

    /// Detects hands in the given pixel buffer. `timestampMs` must be
    /// monotonically increasing between calls.
    func detect(pixelBuffer: CVPixelBuffer,
                timestampMs: Int) throws -> [HandLandmarkFrame] {

        let mpImage: MPImage
        do {
            mpImage = try MPImage(pixelBuffer: pixelBuffer)
        } catch {
            throw HandLandmarkerError.detectionFailed(error)
        }

        let result: HandLandmarkerResult
        do {
            result = try landmarker.detect(videoFrame: mpImage,
                                           timestampInMilliseconds: timestampMs)
        } catch {
            throw HandLandmarkerError.detectionFailed(error)
        }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))

        var frames: [HandLandmarkFrame] = []
        frames.reserveCapacity(result.landmarks.count)

        for (i, handLandmarks) in result.landmarks.enumerated() {
            let points = handLandmarks.map {
                CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))
            }
            let depths = handLandmarks.map { CGFloat($0.z) }

            let handednessLabel = result.handedness[safe: i]?.first?.categoryName ?? "Unknown"
            let handednessScore = result.handedness[safe: i]?.first?.score ?? 0

            frames.append(HandLandmarkFrame(
                landmarks: points,
                depth: depths,
                handedness: handednessLabel,
                handednessScore: handednessScore,
                imageSize: size
            ))
        }
        return frames
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
