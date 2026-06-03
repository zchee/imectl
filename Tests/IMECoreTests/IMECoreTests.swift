import Carbon
import Darwin
import Testing
@testable import IMECore

// MARK: - JSON serialization

@Suite("JSON")
struct JSONTests {
    @Test("escape handles quotes, backslashes, and control chars")
    func escapeSpecials() {
        #expect(JSON.escape("a\"b") == "a\\\"b")
        #expect(JSON.escape("a\\b") == "a\\\\b")
        #expect(JSON.escape("a\nb") == "a\\nb")
        #expect(JSON.escape("a\tb") == "a\\tb")
        #expect(JSON.escape("\u{1}") == "\\u0001")
    }

    @Test("escape leaves multibyte text intact")
    func escapeUnicode() {
        #expect(JSON.escape("ひらがな") == "ひらがな")
    }
}

// MARK: - CLI dispatch (pure routing, no system mutation for read paths)

@Suite("CLI dispatch")
struct CLITests {
    @Test("version flag prints version on stdout, exit 0")
    func version() {
        for arg in ["--version", "-V"] {
            let out = CLI.run([arg])
            #expect(out.code == 0)
            #expect(out.stream == .out)
            #expect(out.text == CLI.version)
        }
    }

    @Test("help flag prints usage on stdout, exit 0")
    func help() {
        for arg in ["--help", "-h"] {
            let out = CLI.run([arg])
            #expect(out.code == 0)
            #expect(out.stream == .out)
            #expect(out.text.contains("USAGE"))
        }
    }

    @Test("unknown command exits 2 on stderr")
    func unknownCommand() {
        let out = CLI.run(["frobnicate"])
        #expect(out.code == 2)
        #expect(out.stream == .err)
    }

    @Test("unknown option for get exits 2")
    func unknownGetOption() {
        let out = CLI.run(["get", "--bogus"])
        #expect(out.code == 2)
        #expect(out.stream == .err)
    }

    @Test("set with no argument exits 2")
    func setNoArg() {
        let out = CLI.run(["set"])
        #expect(out.code == 2)
        #expect(out.stream == .err)
    }

    @Test("set unknown id exits 3 with a specific message")
    func setUnknownID() {
        let out = CLI.run(["set", "com.example.nonexistent.layout"])
        #expect(out.code == 3)
        #expect(out.stream == .err)
        #expect(out.text.contains("not found"))
    }

    @Test("render: silent output emits nothing on either stream")
    func renderSilent() {
        let r = CLI.render(CLI.Output("", .err, code: 0, silent: true))
        #expect(r.stdout == nil)
        #expect(r.stderr == nil)
    }

    @Test("render: empty non-silent stdout output still emits a blank line")
    func renderEmptyNonSilent() {
        // Regression: an empty `list` (zero selectable sources) must keep its
        // pre-hardening behavior of printing one blank line to stdout — only the
        // daemon's silent output is suppressed.
        let r = CLI.render(CLI.Output("", .out))
        #expect(r.stdout == "\n")
        #expect(r.stderr == nil)
    }

    @Test("render: routes text to the correct stream with one trailing newline")
    func renderStreams() {
        let out = CLI.render(CLI.Output("hello", .out))
        #expect(out.stdout == "hello\n")
        #expect(out.stderr == nil)
        let err = CLI.render(CLI.Output("boom", .err, code: 2))
        #expect(err.stdout == nil)
        #expect(err.stderr == "boom\n")
    }
}

// MARK: - --quiet global flag

@Suite("Quiet flag")
struct QuietTests {
    @Test("quieted silences success output but preserves the exit code")
    func quietedSuccess() {
        let q = CLI.Output("com.apple.keylayout.ABC", .out, code: 0).quieted()
        #expect(q.silent)
        #expect(q.code == 0)
        #expect(q.stream == .out)
        // Nothing reaches stdout once quieted.
        #expect(CLI.render(q).stdout == nil)
        #expect(CLI.render(q).stderr == nil)
    }

    @Test("quieted leaves errors untouched on stderr with their exit code")
    func quietedError() {
        let q = CLI.Output("error: not found", .err, code: 3).quieted()
        #expect(!q.silent)
        #expect(q.code == 3)
        #expect(q.stream == .err)
        #expect(CLI.render(q).stderr == "error: not found\n")
    }

    // A pure `.out` success command (no live TIS read) proves the strip ->
    // dispatch -> quieted() path silences success output, and that the flag is
    // position-independent. `--version` is used precisely because it never
    // touches Carbon, keeping these unit tests deterministic; the live `get`
    // path is covered by manual QA against the built binary.
    @Test("quiet silences a success command and is position-independent", arguments: [
        ["--version", "--quiet"], ["--quiet", "--version"], ["-q", "--version"],
    ])
    func quietSilencesSuccess(args: [String]) {
        let out = CLI.run(args)
        #expect(out.silent)
        #expect(out.code == 0)
        #expect(out.stream == .out)
    }

    // The error-passthrough invariant itself is proven purely by `quietedError`;
    // here we confirm it through the real dispatch path on inputs that error
    // *before* any TIS access, so the assertion stays hermetic.
    @Test("quiet does not silence argument errors", arguments: [
        ["set", "--quiet"],          // missing <id>: exit 2
        ["get", "--bogus", "--quiet"], // unknown option: exit 2
        ["--quiet", "set"],          // flag before subcommand, still exit 2
    ])
    func quietDoesNotSilenceErrors(args: [String]) {
        let out = CLI.run(args)
        #expect(!out.silent)
        #expect(out.code == 2)
        #expect(out.stream == .err)
    }

    @Test("quiet is stripped, not consumed as a positional argument")
    func quietNotConsumedAsTarget() {
        // `set --quiet` with no id must be an argument error (exit 2), proving
        // the flag was removed before parsing rather than taken as the <id>.
        // If quiet were consumed as the target it would attempt `set --quiet`
        // and fail not-found (exit 3) instead.
        let out = CLI.run(["set", "--quiet"])
        #expect(out.code == 2)
        #expect(out.stream == .err)
    }
}

// MARK: - Daemon protocol encoding

@Suite("Daemon protocol")
struct DaemonProtocolTests {
    @Test("encodeRequest maps CLI args to protocol lines")
    func encodeRequests() {
        #expect(DaemonProtocol.encodeRequest([]) == "get")
        #expect(DaemonProtocol.encodeRequest(["get"]) == "get")
        #expect(DaemonProtocol.encodeRequest(["get", "--name"]) == "get-name")
        #expect(DaemonProtocol.encodeRequest(["list"]) == "list")
        #expect(DaemonProtocol.encodeRequest(["list", "--json"]) == "list-json")
        #expect(DaemonProtocol.encodeRequest(["set", "com.apple.keylayout.ABC"]) == "set com.apple.keylayout.ABC")
        #expect(DaemonProtocol.encodeRequest(["set", "--language", "ja"]) == "set-lang ja")
    }

    @Test("encodeRequest returns nil for non-served commands")
    func encodeNonServed() {
        #expect(DaemonProtocol.encodeRequest(["daemon"]) == nil)
        #expect(DaemonProtocol.encodeRequest(["--help"]) == nil)
        #expect(DaemonProtocol.encodeRequest(["set"]) == nil)
    }

    @Test("malformed/unknown-flag invocations defer to in-process (nil)")
    func encodeDefersToInProcessOnBadArgs() {
        // Regression: the daemon path must not be more permissive than CLI.run,
        // or the same argv yields a different exit code depending on whether a
        // daemon is running. These must route in-process (nil) for consistent
        // exit-2 argument errors.
        #expect(DaemonProtocol.encodeRequest(["set", "--language"]) == nil)
        #expect(DaemonProtocol.encodeRequest(["get", "--bogus"]) == nil)
        #expect(DaemonProtocol.encodeRequest(["list", "--bogus"]) == nil)
        // Valid flags still encode normally.
        #expect(DaemonProtocol.encodeRequest(["get", "--id"]) == "get")
        #expect(DaemonProtocol.encodeRequest(["get", "--name"]) == "get-name")
    }
}

// MARK: - UnixSocket helpers

@Suite("UnixSocket")
struct UnixSocketTests {
    @Test("setReadTimeout sets SO_RCVTIMEO on the socket")
    func readTimeoutIsApplied() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        UnixSocket.setReadTimeout(fd: fd, seconds: 2)

        var tv = timeval()
        var len = socklen_t(MemoryLayout<timeval>.size)
        let rc = getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, &len)
        #expect(rc == 0)
        #expect(tv.tv_sec == 2)
        #expect(tv.tv_usec == 0)
    }
}

// MARK: - InputSource against the live system (read-only)

@Suite("InputSource (live)")
struct InputSourceTests {
    @Test("the current keyboard source has an id and is enabled+selected")
    func currentSource() throws {
        let current = try #require(TIS.currentKeyboardSource())
        #expect(current.id != nil)
        #expect(current.isEnabled)
        #expect(current.isSelected)
    }

    @Test("selectable sources are all enabled and selectable")
    func selectableInvariant() {
        let sources = TIS.selectableKeyboardSources()
        for src in sources {
            #expect(src.isEnabled)
            #expect(src.isSelectable)
            #expect(src.category == (kTISCategoryKeyboardInputSource as String))
        }
    }

    @Test("JSON array round-trips the live source list shape")
    func jsonArrayShape() {
        let json = JSON.array(TIS.selectableKeyboardSources())
        #expect(json.hasPrefix("["))
        #expect(json.hasSuffix("]"))
    }
}
