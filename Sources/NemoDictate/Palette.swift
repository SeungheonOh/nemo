import SwiftUI

/// Colour triples that drive the glow, borders and waveform per state.
extension DictationState {
    var colors: [Color] {
        switch self {
        case .listening: return [Color(red: 1.00, green: 0.36, blue: 0.52), Color(red: 1.00, green: 0.62, blue: 0.22), Color(red: 0.66, green: 0.42, blue: 1.00)]
        case .standby: return [Color(red: 0.20, green: 0.85, blue: 0.80), Color(red: 0.30, green: 0.70, blue: 1.00), Color(red: 0.45, green: 0.50, blue: 1.00)]
        case .loading, .finishing: return [Color(red: 1.00, green: 0.66, blue: 0.20), Color(red: 1.00, green: 0.85, blue: 0.35), Color(red: 1.00, green: 0.45, blue: 0.55)]
        case .done: return [Color(red: 0.30, green: 0.90, blue: 0.55), Color(red: 0.45, green: 0.95, blue: 0.80), Color(red: 0.25, green: 0.75, blue: 0.85)]
        case .failed: return [Color(white: 0.55), Color(white: 0.7), Color(white: 0.55)]
        case .idle: return [Color(white: 0.5), Color(white: 0.5), Color(white: 0.5)]
        }
    }

    /// The caret effect uses cooler colours while writing so it reads as "ink", not "recording".
    var caretColors: [Color] {
        switch self {
        case .listening: return [Color(red: 0.25, green: 0.90, blue: 1.00), Color(red: 0.60, green: 0.45, blue: 1.00), Color(red: 1.00, green: 0.45, blue: 0.80)]
        default: return colors
        }
    }
}
