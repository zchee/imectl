import Darwin

/// Thin POSIX AF_UNIX socket helpers. Raw sockets are used (not XPC) because the
/// latency-critical path is a short-lived client that reconnects per invocation:
/// a single `connect(2)` to a known path costs microseconds and needs no launchd
/// bootstrap lookup. See the project plan §5 (Phase 2) for the full rationale.
public enum UnixSocket {
    /// Build a `sockaddr_un` for `path`, invoking `body` with a pointer to it.
    /// Returns `nil` if the path is too long for `sun_path`.
    static func withSockaddr<R>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { cptr in
                for (i, b) in bytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { unPtr in
            unPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                body(saPtr, len)
            }
        }
    }

    /// Connect to a listening UNIX socket; returns the fd or `nil` if no server.
    public static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withSockaddr(path: path) { saPtr, len in
            Darwin.connect(fd, saPtr, len) == 0
        } ?? false
        if !ok {
            close(fd)
            return nil
        }
        return fd
    }

    /// Create, bind, and listen on a UNIX socket at `path` with `0600` perms.
    /// Removes a stale socket file first. Returns the listening fd or `nil`.
    public static func listen(path: String, backlog: Int32 = 16) -> Int32? {
        unlink(path) // clear stale socket; ENOENT is fine
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withSockaddr(path: path) { saPtr, len in
            Darwin.bind(fd, saPtr, len) == 0
        } ?? false
        guard bound else { close(fd); return nil }
        chmod(path, 0o600)
        guard Darwin.listen(fd, backlog) == 0 else { close(fd); return nil }
        return fd
    }

    /// Set a receive timeout (`SO_RCVTIMEO`) on `fd` so a stalled client cannot
    /// block the daemon's serial accept loop indefinitely. After the timeout a
    /// blocking `read` returns -1/EAGAIN, which `readLine` treats as end-of-input.
    public static func setReadTimeout(fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = withUnsafePointer(to: &tv) { tvPtr in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tvPtr, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// Read all bytes up to the first `\n` (or EOF) from `fd` as a String.
    public static func readLine(fd: Int32, max: Int = 64 * 1024) -> String {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while buffer.count < max {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Write `text` followed by a newline to `fd`.
    public static func writeLine(fd: Int32, _ text: String) {
        let bytes = Array((text + "\n").utf8)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
