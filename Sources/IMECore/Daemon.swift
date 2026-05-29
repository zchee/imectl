import Darwin

/// The resident daemon. It pays the one-time ~18 ms TIS connection cost once at
/// startup, then serves get/set/list requests over a UNIX socket with a warm
/// connection, eliminating that cost from each subsequent client invocation.
public enum Daemon {
    /// Run the daemon server loop. Blocks until terminated. Returns a process
    /// exit code (non-zero only on a fatal startup failure).
    public static func run() -> Int32 {
        let path = DaemonProtocol.socketPath()
        ensureParentDirectory(of: path)

        guard let listenFD = UnixSocket.listen(path: path) else {
            fputs("imectl daemon: failed to bind socket at \(path)\n", stderr)
            return 1
        }

        installSignalCleanup(path: path)

        // Warm the TIS connection up front so the first client request is fast.
        _ = TIS.currentKeyboardSource()

        fputs("imectl daemon: listening on \(path)\n", stderr)

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            UnixSocket.setReadTimeout(fd: clientFD, seconds: 2)
            let request = UnixSocket.readLine(fd: clientFD)
            let reply = RequestHandler.handle(request)
            UnixSocket.writeLine(fd: clientFD, reply)
            close(clientFD)
        }

        close(listenFD)
        unlink(path)
        return 0
    }

    private static func ensureParentDirectory(of path: String) {
        guard let slash = path.lastIndex(of: "/") else { return }
        let dir = String(path[path.startIndex..<slash])
        guard !dir.isEmpty else { return }
        // mkdir -p, ignoring EEXIST.
        var components: [String] = []
        var current = ""
        for part in dir.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty {
                current = "/"
                continue
            }
            current = current.hasSuffix("/") ? current + String(part) : current + "/" + String(part)
            components.append(current)
        }
        for c in components {
            mkdir(c, 0o700)
        }
    }

    /// Remove the socket file on common termination signals so a restart does not
    /// trip over a stale socket.
    private static func installSignalCleanup(path: String) {
        StaleSocket.install(path: path)
        signal(SIGINT, StaleSocket.handler)
        signal(SIGTERM, StaleSocket.handler)
    }
}

/// Holds the socket path for the C signal handler.
///
/// The handler runs in async-signal context, where touching the Swift runtime or
/// allocator (e.g. bridging a Swift `String` to a C string, which can `malloc`)
/// is undefined behavior. So the path is copied once into a heap C buffer via
/// `strdup` at install time, and the handler calls only async-signal-safe
/// functions (`unlink`, `_exit`) on that raw pointer.
enum StaleSocket {
    nonisolated(unsafe) static var pathPointer: UnsafeMutablePointer<CChar>?

    /// Snapshot the path into a C buffer before any signal can fire.
    static func install(path: String) {
        if let existing = pathPointer {
            free(existing)
            pathPointer = nil
        }
        pathPointer = path.withCString { strdup($0) }
    }

    static let handler: @convention(c) (Int32) -> Void = { _ in
        if let p = StaleSocket.pathPointer {
            unlink(p)
        }
        _exit(0)
    }
}
