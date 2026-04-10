//
//  HandOverlayView.swift
//
//  Draws the 21-point MediaPipe hand skeleton on top of the camera preview
//  using a SwiftUI Canvas. Connection topology comes from the published
//  hand-landmarker bone graph.
//

import SwiftUI

struct HandOverlayView: View {

    let processed: ProcessedFrame

    /// MediaPipe hand bone connections (index pairs).
    private static let handConnections: [(Int, Int)] = [
        // Thumb
        (0, 1), (1, 2), (2, 3), (3, 4),
        // Index
        (0, 5), (5, 6), (6, 7), (7, 8),
        // Middle
        (5, 9), (9, 10), (10, 11), (11, 12),
        // Ring
        (9, 13), (13, 14), (14, 15), (15, 16),
        // Pinky
        (13, 17), (0, 17), (17, 18), (18, 19), (19, 20),
    ]

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let hand = processed.hand else { return }

                // The camera preview is aspect-fit inside `size`; compute
                // the same letterboxed rect so the overlay lines up.
                let rect = aspectFitRect(
                    imageSize: processed.imageSize,
                    into: size
                )

                // Draw bones
                var path = Path()
                for (a, b) in Self.handConnections {
                    let p1 = transform(hand.landmarks[a], rect: rect)
                    let p2 = transform(hand.landmarks[b], rect: rect)
                    path.move(to: p1)
                    path.addLine(to: p2)
                }
                context.stroke(path,
                               with: .color(.green),
                               lineWidth: 2.5)

                // Draw joints
                for pt in hand.landmarks {
                    let p = transform(pt, rect: rect)
                    let dot = Path(ellipseIn: CGRect(
                        x: p.x - 3, y: p.y - 3, width: 6, height: 6
                    ))
                    context.fill(dot, with: .color(.yellow))
                }

                // Highlight the wrist joint
                let wrist = transform(hand.landmarks[0], rect: rect)
                let wristRing = Path(ellipseIn: CGRect(
                    x: wrist.x - 8, y: wrist.y - 8, width: 16, height: 16
                ))
                context.stroke(wristRing, with: .color(.red), lineWidth: 2)

                // Draw the forearm vector inferred from the pose landmarker
                if let pose = processed.pose {
                    drawForearm(context: context,
                                pose: pose,
                                hand: hand,
                                rect: rect)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Geometry helpers

    private func aspectFitRect(imageSize: CGSize, into bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width,
                        bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (bounds.width - w) * 0.5,
                      y: (bounds.height - h) * 0.5,
                      width: w, height: h)
    }

    private func transform(_ normalized: CGPoint, rect: CGRect) -> CGPoint {
        CGPoint(x: rect.origin.x + normalized.x * rect.width,
                y: rect.origin.y + normalized.y * rect.height)
    }

    private func drawForearm(context: GraphicsContext,
                             pose: PoseLandmarkFrame,
                             hand: HandLandmarkFrame,
                             rect: CGRect) {
        // Pick the elbow whose pose-wrist is closest to the hand's wrist.
        let handWrist = hand.landmarks[0]
        let lWrist = pose.point(.leftWrist)
        let rWrist = pose.point(.rightWrist)
        let dL = hypot(handWrist.x - lWrist.x, handWrist.y - lWrist.y)
        let dR = hypot(handWrist.x - rWrist.x, handWrist.y - rWrist.y)

        let elbow = dL < dR ? pose.point(.leftElbow) : pose.point(.rightElbow)
        let wrist = dL < dR ? lWrist : rWrist

        let e = transform(elbow, rect: rect)
        let w = transform(wrist, rect: rect)

        var forearmPath = Path()
        forearmPath.move(to: e)
        forearmPath.addLine(to: w)
        context.stroke(forearmPath,
                       with: .color(.cyan),
                       style: StrokeStyle(lineWidth: 3, dash: [6, 4]))

        let elbowDot = Path(ellipseIn: CGRect(
            x: e.x - 5, y: e.y - 5, width: 10, height: 10
        ))
        context.fill(elbowDot, with: .color(.cyan))
    }
}
