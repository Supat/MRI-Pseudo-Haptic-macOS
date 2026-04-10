//
//  StatusHUDView.swift
//
//  Floating heads-up display that shows the current wrist angle and the
//  Flexor/Extensor classification with a colour badge.
//

import SwiftUI

struct StatusHUDView: View {

    let wrist: WristAngleResult?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("Wrist Angle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))

            Text(angleString)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            Text(classificationLabel)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(classificationColor.opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var angleString: String {
        guard let wrist = wrist, wrist.isValid else { return "—" }
        return String(format: "%+.1f°", wrist.angleDegrees)
    }

    private var classificationLabel: String {
        wrist?.classification.rawValue ?? "No hand"
    }

    private var classificationColor: Color {
        switch wrist?.classification {
        case .flexor: return .orange
        case .extensor: return .blue
        case .neutral: return .green
        case .none: return .gray
        }
    }
}
