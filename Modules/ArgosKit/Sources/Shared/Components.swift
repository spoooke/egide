import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

func scoreColor(_ score: Int) -> Color {
    score >= 85 ? .green : score >= 60 ? .orange : .red
}

func statusColor(_ s: CheckStatus) -> Color {
    switch s {
    case .pass: .green
    case .warn: .orange
    case .fail: .red
    case .unknown: .gray
    }
}

/// « il y a 5 min », « à l'instant »…
func ago(_ date: Date) -> String {
    Date().timeIntervalSince(date) < 60 ? "à l'instant"
        : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(Locale(identifier: "fr_FR")))
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size / 10)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(scoreColor(score), style: StrokeStyle(lineWidth: size / 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Score \(score) sur 100")
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.6)))
    }
}

/// « ● En ligne », « Hors ligne · vu il y a 2 h » ou « Vérifié il y a 3 j ».
struct PresenceText: View {
    let isManual: Bool
    let online: Bool
    let lastSeen: Date

    var body: some View {
        if isManual {
            Text("Vérifié \(ago(lastSeen))")
        } else {
            HStack(spacing: 5) {
                Circle().fill(online ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(online ? "En ligne" : "Hors ligne · vu \(ago(lastSeen))")
            }
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
