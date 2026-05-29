/// Minimal hand-built JSON string assembly for `list --json`.
///
/// We deliberately avoid `Foundation.JSONEncoder`: although Foundation is already
/// linked (TIS property bridging pulls it in), hand-rolling the tiny, fixed shape
/// we emit keeps serialization on a path we fully control and avoids JSONEncoder's
/// first-use initialization cost.
public enum JSON {
    /// Escape a string for embedding in a JSON double-quoted literal.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += "\\u" + hex4(c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Render a single input source as a JSON object string.
    public static func object(_ source: InputSource) -> String {
        var fields: [String] = []
        fields.append("\"id\":\(stringOrNull(source.id))")
        fields.append("\"localizedName\":\(stringOrNull(source.localizedName))")
        fields.append("\"category\":\(stringOrNull(source.category))")
        fields.append("\"type\":\(stringOrNull(source.type))")
        fields.append("\"selectable\":\(source.isSelectable)")
        fields.append("\"enabled\":\(source.isEnabled)")
        fields.append("\"selected\":\(source.isSelected)")
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Render an array of input sources as a JSON array string.
    public static func array(_ sources: [InputSource]) -> String {
        "[" + sources.map(object).joined(separator: ",") + "]"
    }

    private static func stringOrNull(_ s: String?) -> String {
        guard let s else { return "null" }
        return "\"\(escape(s))\""
    }

    /// Lowercase 4-digit hex for a `\uXXXX` escape, without Foundation.
    private static func hex4(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        var v = value & 0xFFFF
        var chars = [Character](repeating: "0", count: 4)
        var i = 3
        while i >= 0 {
            chars[i] = digits[Int(v & 0xF)]
            v >>= 4
            i -= 1
        }
        return String(chars)
    }
}
