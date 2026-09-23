import SwiftUI

/// The floating pill: state dot, live waveform, streaming transcript, status line.
/// It grows with the transcript up to `maxTextHeight`, then scrolls to keep the newest words visible;
/// the measured height is reported so the panel can follow.
struct IndicatorView: View {
    @ObservedObject var model: DictationModel
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var textHeight: CGFloat = 0

    static let width: CGFloat = 520
    static let minHeight: CGFloat = 68
    static let maxTextHeight: CGFloat = 200   // about ten lines

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StateDot(state: model.state)
            WaveformBars(level: model.level, active: model.state == .listening)
                .frame(width: 54, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                transcriptBlock
                    .padding(.top, 3)   // first line sits on the controls' centre line
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
        .padding(.vertical, 14)
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight)
        .fixedSize(horizontal: false, vertical: true)   // take the ideal height, whatever the window proposes
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .background(GeometryReader { g in Color.clear.preference(key: PillHeightKey.self, value: g.size.height) })
        .onPreferenceChange(PillHeightKey.self) { onHeightChange($0) }
    }

    private var transcriptBlock: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(model.transcript.isEmpty ? placeholder : model.transcript)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in Color.clear.preference(key: TextHeightKey.self, value: g.size.height) })
                    .id("end")
            }
            .frame(height: min(max(textHeight, 20), Self.maxTextHeight))
            .mask(
                // once it scrolls, the oldest line fades out through the top instead of being cut mid-glyph
                LinearGradient(stops: [.init(color: textHeight > Self.maxTextHeight ? .clear : .black, location: 0),
                                       .init(color: .black, location: 0.14),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onPreferenceChange(TextHeightKey.self) { h in
                textHeight = h
                if h > Self.maxTextHeight { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
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

private struct PillHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
