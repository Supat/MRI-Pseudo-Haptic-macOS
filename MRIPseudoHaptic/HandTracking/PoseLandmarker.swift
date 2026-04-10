//
//  PoseLandmarker.swift
//
//  Wrapper around MediaPipe Tasks Vision PoseLandmarker. We use the pose
//  landmarker to get a reliable forearm reference (elbow → wrist), which
//  the hand landmarker alone cannot provide.
//

import Foundation
import CoreVideo
import CoreGraphics
import MediaPipeTasksVision

/// A reduced pose frame that only surfaces the upper-limb landmarks we need
/// for wrist angle estimation.
struct PoseLandmarkFrame {
    var landmarks: [CGPoint]   // normalized
    var imageSize: CGSize

    /// Pose landmark indices (subset) — see MediaPipe docs.
    enum Landmark: Int {
        case leftShoulder = 11, rightShoulder = 12
        case leftElbow = 13, rightElbow = 14
        case leftWrist = 15, rightWrist = 16
        case leftPinky = 17, rightPinky = 18
        case leftIndex = 19, rightIndex = 20
        case leftThumb = 21, rightThumb = 22
    }

    func point(_ lm: Landmark) -> CGPoint {
        landmarks[lm.rawValue]
    }
}

enum PoseLandmarkerError: LocalizedError {
    case modelFileMissing(String)
    case initializationFailed(Error)
    case detectionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelFileMissing(let name):
            return "Missing \(name). Download pose_landmarker_lite.task and add it to Models/."
        case .initializationFailed(let e):
            return "PoseLandmarker init failed: \(e.localizedDescription)"
        case .detectionFailed(let e):
            return "PoseLandmarker detect failed: \(e.localizedDescription)"
        }
    }
}

final class PoseLandmarkerService {

    private let landmarker: PoseLandmarker

    init(modelFileName: String = "pose_landmarker_lite",
         minDetectionConfidence: Float = 0.5,
         minPresenceConfidence: Float = 0.5,
         minTrackingConfidence: Float = 0.5) throws {

        guard let modelPath = Bundle.main.path(forResource: modelFileName, ofType: "task") else {
            throw PoseLandmarkerError.modelFileMissing("\(modelFileName).task")
        }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video
        options.numPoses = 1
        options.minPoseDetectionConfidence = minDetectionConfidence
        options.minPosePresenceConfidence = minPresenceConfidence
        options.minTrackingConfidence = minTrackingConfidence

        do {
            self.landmarker = try PoseLandmarker(options: options)
        } catch {
            throw PoseLandmarkerError.initializationFailed(error)
        }
    }

    func detect(pixelBuffer: CVPixelBuffer,
                timestampMs: Int) throws -> PoseLandmarkFrame? {
        let mpImage: MPImage
        do {
            mpImage = try MPImage(pixelBuffer: pixelBuffer)
        } catch {
            throw PoseLandmarkerError.detectionFailed(error)
        }

        let result: PoseLandmarkerResult
        do {
            result = try landmarker.detect(videoFrame: mpImage,
                                           timestampInMilliseconds: timestampMs)
        } catch {
            throw PoseLandmarkerError.detectionFailed(error)
        }

        guard let firstPose = result.landmarks.first else { return nil }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        let points = firstPose.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        return PoseLandmarkFrame(landmarks: points, imageSize: size)
    }
}
