import Carbon
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
