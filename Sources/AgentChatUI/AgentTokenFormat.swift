import Foundation

/// Short token counts for chat chrome: 950, 1.2k, 130k, 4.5m, 1.2b.
public enum AgentTokenFormat {
    public static func compact(_ count: Int) -> String {
        let value = Double(abs(count))
        let sign = count < 0 ? "-" : ""
        let units: [(Double, String)] = [(1_000_000_000, "b"), (1_000_000, "m"), (1_000, "k")]
        for (size, suffix) in units where value >= size {
            let scaled = value / size
            // One decimal below 100 (1.2k, 45.6m); whole numbers above (130k).
            let text = scaled < 100 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
            return sign + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        return sign + String(Int(value))
    }
}
