import Darwin

/// Top-level entry point used by the `imectl` executable. Handles the `daemon`
/// subcommand, then routes get/set/list to a running daemon when one is
/// reachable, and falls back to the in-process one-shot TIS path otherwise.
public enum DaemonRouting {
    public static func run(_ args: [String]) -> CLI.Output {
        // Strip the global `--quiet`/`-q` flag before touching the daemon path so
        // `encodeRequest` (and the parity invariant it guards) only ever sees
        // clean args. `CLI.run` performs the identical strip itself, so the
        // in-process fallback below is handed the original args untouched.
        let quiet = args.contains { CLI.quietFlags.contains($0) }
        let cleaned = args.filter { !CLI.quietFlags.contains($0) }

        if cleaned.first == "daemon" {
            let code = Daemon.run()
            return CLI.Output("", .err, code: code, silent: true)
        }

        // Try the warm daemon path: a single non-blocking connect. If anything
        // about the daemon path is unavailable, fall straight through to the
        // in-process implementation — same observable behavior, just slower.
        if let request = DaemonProtocol.encodeRequest(cleaned),
           let reply = tryDaemon(request: request) {
            let output = decode(reply: reply, args: cleaned)
            return quiet ? output.quieted() : output
        }

        return CLI.run(args)
    }

    /// Attempt a daemon round-trip; returns the reply line or `nil` if no daemon.
    private static func tryDaemon(request: String) -> String? {
        let path = DaemonProtocol.socketPath()
        guard let fd = UnixSocket.connect(path: path) else { return nil }
        defer { close(fd) }
        UnixSocket.writeLine(fd: fd, request)
        let reply = UnixSocket.readLine(fd: fd)
        return reply.isEmpty ? nil : reply
    }

    /// Translate a daemon reply line back into CLI output, mirroring CLI.run's
    /// streams and exit codes.
    private static func decode(reply: String, args: [String]) -> CLI.Output {
        if reply.hasPrefix("err ") {
            let body = String(reply.dropFirst(4))
            let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
            let code = Int32(parts.first ?? "1") ?? 1
            let message = parts.count > 1 ? parts[1] : "error"
            return CLI.Output("error: \(message)", .err, code: code)
        }

        let verb = args.first ?? "get"
        switch verb {
        case "list":
            if args.dropFirst().contains("--json") {
                return CLI.Output(reply)
            }
            let rows = reply.components(separatedBy: DaemonProtocol.rowSeparator)
            return CLI.Output(rows.joined(separator: "\n"))
        case "set":
            // Daemon replies `ok <id>` for set; strip the prefix.
            let id = reply.hasPrefix("ok ") ? String(reply.dropFirst(3)) : reply
            return CLI.Output(id)
        default:
            return CLI.Output(reply)
        }
    }
}

private extension String {
    /// Split on a separator string (Foundation-free).
    func components(separatedBy separator: String) -> [String] {
        guard !separator.isEmpty else { return [self] }
        var result: [String] = []
        var current = ""
        var i = startIndex
        let sepFirst = separator.first!
        while i < endIndex {
            if self[i] == sepFirst, self[i...].hasPrefix(separator) {
                result.append(current)
                current = ""
                i = index(i, offsetBy: separator.count)
            } else {
                current.append(self[i])
                i = index(after: i)
            }
        }
        result.append(current)
        return result
    }
}
