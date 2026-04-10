//
//  WristAngleCalculator.swift
//
//  Computes the signed wrist angle (in degrees) between the forearm
//  vector and the hand vector, and classifies the motion as Flexor
//  (palmar flexion) or Extensor (dorsiflexion) activity.
//
//  Math overview
//  -------------
//  * forearm  = wrist_pose - elbow_pose            (from PoseLandmarker)
//  * hand     = middleMCP_hand - wrist_hand         (from HandLandmarker)
//  * magnitude: theta = atan2(||u×v||, u·v)         — unsigned 0…180°
//  * sign    : use the hand's palm-normal (thumb×index-to-pinky) to pick
//              flexion vs extension.
//
//  Neutral (straight) wrist corresponds to theta ≈ 180° between the two
//  vectors; we report the *deviation from neutral*, i.e.
//      deviation = 180° - theta
//  so that a neutral wrist reads 0°, full flexion reads positive, and
//  full extension reads negative.
//

import Foundation
import CoreGraphics
import simd

enum WristClassification: String {
    case neutral = "Neutral"
    case flexor = "Flexor"    // palmar flexion (fingers curl toward palm side)
    case extensor = "Extensor" // dorsiflexion (back of hand toward forearm)
}

struct WristAngleResult {
    /// Signed deviation from neutral, in degrees. Positive → flexion,
    /// negative → extension, zero → perfectly straight.
    let angleDegrees: Double

    /// Classification label derived from `angleDegrees` and `neutralZone`.
    let classification: WristClassification

    /// Unsigned angle between forearm and hand vectors, for debugging.
    let rawAngleBetweenVectors: Double

    /// `true` if we had enough information (pose + hand) to compute a
    /// trustworthy angle.
    let isValid: Bool
}

struct WristAngleCalculator {

    /// Absolute angle (in degrees) below which the wrist is considered
    /// "neutral" rather than flexed or extended.
    var neutralZoneDegrees: Double = 8.0

    /// One-pole low-pass smoothing factor in [0, 1]. 0 = no smoothing,
    /// higher = heavier smoothing. Tweak to match the camera frame rate.
    var smoothing: Double = 0.35

    private var smoothedAngle: Double = 0
    private var hasSmoothed: Bool = false

    mutating func reset() {
        smoothedAngle = 0
        hasSmoothed = false
    }

    /// Given the latest hand landmarks and (optionally) pose landmarks,
    /// returns the wrist angle and Flexor/Extensor classification.
    mutating func compute(hand: HandLandmarkFrame,
                          pose: PoseLandmarkFrame?) -> WristAngleResult {

        // --- Forearm vector (from the pose landmarker if available) -----
        let imageW = Double(hand.imageSize.width)
        let imageH = Double(hand.imageSize.height)

        let handWristPx = hand.pixelPoint(.wrist)
        let handMiddleMCPPx = hand.pixelPoint(.middleMCP)

        let handVec = SIMD2<Double>(
            Double(handMiddleMCPPx.x) - Double(handWristPx.x),
            Double(handMiddleMCPPx.y) - Double(handWristPx.y)
        )

        var forearmVec: SIMD2<Double>
        if let pose = pose {
            // Pick the arm whose pose-wrist is closest to the hand-wrist.
            let leftWrist = unnormalize(pose.point(.leftWrist), w: imageW, h: imageH)
            let rightWrist = unnormalize(pose.point(.rightWrist), w: imageW, h: imageH)
            let leftElbow = unnormalize(pose.point(.leftElbow), w: imageW, h: imageH)
            let rightElbow = unnormalize(pose.point(.rightElbow), w: imageW, h: imageH)

            let handWrist = SIMD2<Double>(Double(handWristPx.x), Double(handWristPx.y))
            let dLeft = simd_distance(leftWrist, handWrist)
            let dRight = simd_distance(rightWrist, handWrist)

            let (chosenElbow, chosenWrist) = dLeft < dRight
                ? (leftElbow, leftWrist)
                : (rightElbow, rightWrist)
            forearmVec = chosenWrist - chosenElbow
        } else {
            // Fallback: if we don't have a pose, assume the forearm
            // points from the bottom of the frame up toward the hand
            // wrist. This is a crude approximation that lets the app
            // keep working if the pose landmarker is disabled.
            forearmVec = SIMD2<Double>(0, -1)
        }

        let forearmLen = simd_length(forearmVec)
        let handLen = simd_length(handVec)
        guard forearmLen > 1e-3, handLen > 1e-3 else {
            return WristAngleResult(angleDegrees: 0,
                                    classification: .neutral,
                                    rawAngleBetweenVectors: 0,
                                    isValid: false)
        }

        let u = forearmVec / forearmLen
        let v = handVec / handLen

        // Unsigned angle between the two vectors, in degrees.
        let dot = simd_dot(u, v)
        let cross = u.x * v.y - u.y * v.x
        let rawRadians = atan2(abs(cross), dot)
        let rawDegrees = rawRadians * 180.0 / .pi

        // Deviation from a perfectly straight wrist. With u and v both
        // pointing "outward" along the arm, a straight wrist yields
        // theta ≈ 0 (hand continues the forearm direction).
        //
        // Mathematical note: we define forearm as elbow→wrist and hand as
        // wrist→middleMCP, so co-linear vectors ⇒ rawRadians ≈ 0.
        var signedDegrees = rawDegrees

        // --- Sign: flexion vs extension ---------------------------------
        // Use the palm normal to disambiguate. Palm normal is inferred
        // from the 2D cross product of the forearm vector with the hand
        // vector, biased by the thumb side (handedness).
        //
        // With MediaPipe's "mirrored" handedness, for a right hand the
        // palm-facing-camera configuration has cross > 0 when the hand is
        // flexed toward the palm side.
        let handedness = hand.handedness.lowercased()
        let signMultiplier: Double = handedness.contains("left") ? -1.0 : 1.0
        if cross * signMultiplier < 0 {
            signedDegrees = -signedDegrees
        }

        // --- Temporal smoothing ----------------------------------------
        if hasSmoothed {
            smoothedAngle = smoothing * smoothedAngle + (1.0 - smoothing) * signedDegrees
        } else {
            smoothedAngle = signedDegrees
            hasSmoothed = true
        }

        // --- Classification --------------------------------------------
        let classification: WristClassification
        if abs(smoothedAngle) < neutralZoneDegrees {
            classification = .neutral
        } else if smoothedAngle > 0 {
            classification = .flexor
        } else {
            classification = .extensor
        }

        return WristAngleResult(
            angleDegrees: smoothedAngle,
            classification: classification,
            rawAngleBetweenVectors: rawDegrees,
            isValid: true
        )
    }

    private func unnormalize(_ p: CGPoint, w: Double, h: Double) -> SIMD2<Double> {
        SIMD2<Double>(Double(p.x) * w, Double(p.y) * h)
    }
}
