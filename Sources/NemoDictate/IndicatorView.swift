import SwiftUI

/// The floating pill: state dot, live waveform, streaming transcript, status line, sitting on an
/// animated underglow. It grows with the transcript up to `maxTextHeight`, then scrolls to keep the
/// newest words visible; the measured pill height is reported so the panel can follow.
struct IndicatorView: View {
    @ObservedObject var model: DictationModel
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var textHeight: CGFloat = 0
    @State private var appeared = false

    static let width: CGFloat = 520
    static let minHeight: CGFloat = 68
    static let maxTextHeight: CGFloat = 200   // about ten lines
    static let glowPadding: CGFloat = 72      // room around the pill for glow and shadow
    static let cornerRadius: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40, paused: !model.pillVisible)) { ctx in
            pill(t: ctx.date.timeIntervalSinceReferenceDate)
        }
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .onAppear { appeared = model.pillVisible }
        .onChange(of: model.pillVisible) { _, visible in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { appeared = visible }
        }
    }

    private func pill(t: Double) -> some View {
        let colors = model.state.colors
        let live = model.state == .listening
        let level = Double(model.level)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let breathe = 0.5 + 0.5 * sin(t * 1.6)
        return content(t: t, colors: colors, live: live)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(width: Self.width)
            .frame(minHeight: Self.minHeight)
            .fixedSize(horizontal: false, vertical: true)   // take the ideal height, whatever the window proposes
            .background(shape.fill(.regularMaterial))
            .overlay {
                // glass sheen and a slowly turning gradient rim
                shape.fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03), .clear], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                shape.strokeBorder(.white.opacity(0.10), lineWidth: 1)
                shape.strokeBorder(
                    AngularGradient(colors: [colors[0].opacity(0.95), .white.opacity(0.7), colors[1].opacity(0.9), colors[2].opacity(0.35), colors[0].opacity(0.95)],
                                    center: .center, angle: .degrees(t * 50)),
                    lineWidth: 1.5)
                    .opacity(live ? 0.95 : 0.6)
            }
            .background {
                // soft drop shadow plus the coloured underglow, both drawn here so nothing depends on the window
                shape.fill(.black.opacity(0.38)).blur(radius: 16).offset(y: 12)
                shape.fill(AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(t * 28)))
                    .blur(radius: 26)
                    .offset(y: 14)
                    .scaleEffect(x: 0.96 + 0.03 * (live ? level : breathe * 0.5), y: 1.02 + (live ? 0.16 * level : 0.05 * breathe), anchor: .top)
                    .opacity(live ? 0.55 + 0.45 * level : 0.45 + 0.15 * breathe)
            }
            .background(GeometryReader { g in Color.clear.preference(key: PillHeightKey.self, value: g.size.height) })
            .onPreferenceChange(PillHeightKey.self) { onHeightChange($0) }
    }

    private func content(t: Double, colors: [Color], live: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            StateDot(state: model.state)
            WaveformBars(level: model.level, active: live, colors: colors)
                .frame(width: 54, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                transcriptBlock(caretOn: live && Int(t * 2.2) % 2 == 0, accent: colors[0])
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
                    .overlay(Circle().strokeBorder(colors[0].opacity(live ? 0.6 : 0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.state == .loading || model.state == .finishing)
        }
    }

    private func transcriptBlock(caretOn: Bool, accent: Color) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                (Text(model.transcript.isEmpty ? placeholder : model.transcript)
                    .foregroundColor(model.transcript.isEmpty ? .secondary : .primary)
                 + Text(model.state == .listening ? "▍" : "")
                    .foregroundColor(accent.opacity(caretOn ? 1 : 0.15)))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
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
                .fill(LinearGradient(colors: [state.colors[1], color], startPoint: .top, endPoint: .bottom))
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.8), radius: state == .listening ? 8 : 3)
                .opacity(state == .loading ? (pulse ? 0.35 : 1) : 1)
                .animation(state == .loading ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
        }
        .frame(width: 26, height: 26)
        .onAppear { pulse = true }
        .onChange(of: state) { _, _ in pulse = false; DispatchQueue.main.async { pulse = true } }
    }

    private var color: Color { state.colors[0] }
}

/// Bars driven by recent input levels; idle bars settle to a thin baseline.
struct WaveformBars: View {
    let level: Float
    let active: Bool
    var colors: [Color] = [.red, .orange]
    @State private var history: [Float] = Array(repeating: 0, count: 9)

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(colors: [colors[0], colors[1]], startPoint: .bottom, endPoint: .top))
                          : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .frame(width: 3, height: max(3, CGFloat(v) * 26))
                    .shadow(color: active ? colors[0].opacity(0.7) : .clear, radius: 3)
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
