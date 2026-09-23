import SwiftUI

/// The floating pill: state dot, live waveform, streaming transcript, status line.
struct IndicatorView: View {
    @ObservedObject var model: DictationModel

    var body: some View {
        HStack(spacing: 14) {
            StateDot(state: model.state)
            WaveformBars(level: model.level, active: model.state == .listening)
                .frame(width: 54, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.transcript.isEmpty ? placeholder : model.transcript)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(model.statusLine)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: model.toggle) {
                Image(systemName: buttonIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .disabled(model.state == .loading || model.state == .finishing)
        }
        .padding(.horizontal, 18)
        .frame(width: 520, height: 68)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    private var placeholder: String {
        switch model.state {
        case .loading: return "Loading Nemotron…"
        case .standby: return "Standing by"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .failed: return "Something went wrong"
        default: return ""
        }
    }

    private var buttonIcon: String {
        switch model.state {
        case .listening: return "stop.fill"
        case .standby: return "waveform"
        case .done: return "checkmark"
        case .failed: return "xmark"
        default: return "mic.fill"
        }
    }
}

struct StateDot: View {
    let state: DictationState
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .listening {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.7), radius: state == .listening ? 8 : 0)
                .opacity(state == .loading ? (pulse ? 0.35 : 1) : 1)
                .animation(state == .loading ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
        }
        .frame(width: 26, height: 26)
        .onAppear { pulse = true }
        .onChange(of: state) { _, _ in pulse = false; DispatchQueue.main.async { pulse = true } }
    }

    private var color: Color {
        switch state {
        case .listening: return .red
        case .standby: return .teal
        case .loading, .finishing: return .orange
        case .done: return .green
        case .failed: return .gray
        case .idle: return .secondary
        }
    }
}

/// Bars driven by recent input levels; idle bars settle to a thin baseline.
struct WaveformBars: View {
    let level: Float
    let active: Bool
    @State private var history: [Float] = Array(repeating: 0, count: 9)

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? Color.red.opacity(0.85) : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: max(3, CGFloat(v) * 26))
            }
        }
        .onChange(of: level) { _, new in
            var h = history
            h.removeFirst()
            h.append(active ? new : 0)
            withAnimation(.easeOut(duration: 0.12)) { history = h }
        }
        .onChange(of: active) { _, on in
            if !on { withAnimation(.easeOut(duration: 0.3)) { history = Array(repeating: 0, count: 9) } }
        }
    }
}
