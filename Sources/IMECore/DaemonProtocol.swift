import Darwin

/// Shared socket-path resolution and line protocol for the daemon and its
/// clients. The protocol is intentionally trivial: one request line in, one
/// reply line out, then the connection closes.
///
/// Request grammar (single line, `\n`-terminated):
///   `get`            → reply: the current input source ID
///   `get-name`       → reply: the current localized name
///   `list`           → reply: tab+newline encoded id\tname rows joined by `\u{1}`
///   `list-json`      → reply: JSON array
///   `set <id>`       → reply: `ok <id>` on success
///   `set-lang <tag>` → reply: `ok <id>` on success
///
/// Reply grammar:
///   success → payload line (no `err ` prefix)
///   error   → `err <code> <message>`
public enum DaemonProtocol {
    /// Resolve the daemon socket path: `$XDG_RUNTIME_DIR/imectl.sock` when set,
    /// otherwise `~/Library/Application Support/imectl/imectl.sock`.
    public static func socketPath() -> String {
        if let xdg = environment("XDG_RUNTIME_DIR"), !xdg.isEmpty {
            return xdg + "/imectl.sock"
        }
        let home = environment("HOME") ?? "/tmp"
        return home + "/Library/Application Support/imectl/imectl.sock"
    }

    /// Encode a CLI invocation into a single request line, or `nil` if the
    /// command is not one the daemon serves (e.g. `--help`, `daemon`).
    public static func encodeRequest(_ args: [String]) -> String? {
        guard let first = args.first else { return "get" } // bare imectl
        switch first {
        case "get":
            // Defer to the in-process path on any unrecognized flag so it remains
            // the single source of argument-validation truth (matching exit codes
            // whether or not a daemon is running).
            let rest = Array(args.dropFirst())
            let known: Set<String> = ["--id", "--name"]
            guard rest.allSatisfy(known.contains) else { return nil }
            return rest.contains("--name") ? "get-name" : "get"
        case "list":
            let rest = Array(args.dropFirst())
            guard rest.allSatisfy({ $0 == "--json" }) else { return nil }
            return rest.contains("--json") ? "list-json" : "list"
        case "set":
            let rest = Array(args.dropFirst())
            guard let target = rest.first else { return nil }
            if target == "--language" {
                // Missing tag: defer to the in-process path so it produces the
                // same "requires a tag" / exit-2 diagnostic as the one-shot path.
                guard rest.count >= 2 else { return nil }
                return "set-lang \(rest[1])"
            }
            return "set \(target)"
        default:
            return nil
        }
    }

    /// Field separator used to pack multi-line `list` output into a single reply
    /// line (control char U+0001, which never appears in source IDs or names).
    public static let rowSeparator = "\u{1}"

    private static func environment(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        return String(cString: raw)
    }
}
