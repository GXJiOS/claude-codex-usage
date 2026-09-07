import AppKit

/// Configurable consumed-quota boundaries apply in both used and remaining display modes.
enum UsageColor {
    static func forUsed(_ usedPercent: Double, thresholds: UsageColorThresholds = .default) -> NSColor {
        if usedPercent >= Double(thresholds.redFrom) { return .systemRed }
        if usedPercent >= Double(thresholds.yellowFrom) { return .systemYellow }
        return .systemGreen
    }
}
