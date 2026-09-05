import AppKit

/// Colour of a percentage by consumed quota: 0–50 green, 50–80 yellow, 80+ red.
/// Thresholds apply to used %, whichever mode is displayed.
enum UsageColor {
    static func forUsed(_ usedPercent: Double) -> NSColor {
        switch usedPercent {
        case 80...: return .systemRed
        case 50...: return .systemYellow
        default: return .systemGreen
        }
    }
}
