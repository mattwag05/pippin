import Foundation

/// String helpers that survived the removal of human text output
/// (pippin-xg3z): `truncate` bounds preview fields and `duration` labels memo
/// lengths in transcript sidecars.
public enum TextFormatter {
    /// Truncate a string to `maxLength` characters, adding ellipsis if needed.
    public static func truncate(_ s: String, to maxLength: Int) -> String {
        guard s.count > maxLength, maxLength > 1 else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }

    /// Format seconds as human-readable duration: "2m 15s", "1h 5m", "45s".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total < 60 {
            return "\(total)s"
        } else if total < 3600 {
            let m = total / 60
            let s = total % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        } else {
            let h = total / 3600
            let m = (total % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }
}
