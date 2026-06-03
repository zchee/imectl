/// Command dispatch for imectl. Hand-rolled (no swift-argument-parser) to keep
/// startup latency minimal: the command surface is tiny and the latency mandate
/// outranks parser ergonomics.
public enum CLI {
    public static let version = "0.1.0"

    public static let usage = """
    imectl — macOS keyboard input source CLI

    USAGE:
      imectl                      Print the current input source ID
      imectl get [--id|--name]    Print current source (--id default, --name localized)
      imectl list [--json]        List selectable, enabled keyboard sources
      imectl set <input-source-id>    Switch by input-source ID
      imectl set --language <tag>     Switch by BCP-47 language tag
      imectl --version, -V        Print version
      imectl --help, -h           Print this help

    GLOBAL OPTIONS:
      --quiet, -q                 Suppress success output; errors and exit codes are unaffected

    Carbon-TIS-only by design; latency-optimized. See the project README.
    """

    /// Result of running a command: text to print, a stream, and an exit code.
    ///
    /// `silent` marks a result that should emit nothing at all. Two callers set
    /// it: the `daemon` subcommand (whose work is done over the socket), and the
    /// `--quiet` global flag via `quieted()` (which suppresses success output
    /// only). It is kept distinct from an empty `text` so that a genuinely empty
    /// payload — e.g. `list` with zero selectable sources — still renders as the
    /// caller expects.
    public struct Output: Equatable {
        public enum Stream: Equatable { case out, err }
        public var text: String
        public var stream: Stream
        public var code: Int32
        public var silent: Bool

        public init(_ text: String, _ stream: Stream = .out, code: Int32 = 0, silent: Bool = false) {
            self.text = text
            self.stream = stream
            self.code = code
            self.silent = silent
        }

        /// Apply `--quiet`: suppress success output, leave errors untouched.
        ///
        /// In this CLI every stdout result is a success (code 0) and every error
        /// is routed to stderr, so "suppress success, keep errors" is exactly
        /// "silence iff `stream == .out`". Exit codes are preserved in both cases,
        /// which is what makes `set <id> --quiet` usable as a silent side effect
        /// that still fails loudly (nonzero exit) when the switch does not happen.
        public func quieted() -> Output {
            guard stream == .out else { return self }
            var copy = self
            copy.silent = true
            return copy
        }
    }

    /// Decide what a given `Output` writes to each stream, as a pure function so
    /// the print policy is unit-testable without spawning a process. Returns the
    /// exact bytes (including the trailing newline) destined for stdout/stderr,
    /// or `nil` for a stream that should receive nothing.
    public static func render(_ output: Output) -> (stdout: String?, stderr: String?) {
        guard !output.silent else { return (nil, nil) }
        let line = output.text + "\n"
        switch output.stream {
        case .out: return (line, nil)
        case .err: return (nil, line)
        }
    }

    /// Names of the global `--quiet` flag and its short alias.
    static let quietFlags: Set<String> = ["--quiet", "-q"]

    /// Pure parse+dispatch over the argument list (excluding argv[0]). Side-effecting
    /// TIS reads/writes happen inside, but the routing is deterministic and the
    /// result is returned rather than printed, so callers (and tests) decide I/O.
    ///
    /// `--quiet`/`-q` is a position-independent global flag: it is stripped here
    /// before dispatch, so subcommand parsers never see it, and applied to the
    /// result via `quieted()`. This makes `imectl --quiet set X`, `set X --quiet`,
    /// and `set --quiet X` all behave identically.
    public static func run(_ args: [String]) -> Output {
        let quiet = args.contains { quietFlags.contains($0) }
        let cleaned = args.filter { !quietFlags.contains($0) }
        let output = dispatch(cleaned)
        return quiet ? output.quieted() : output
    }

    /// Parse+dispatch over arguments that have already had global flags stripped.
    private static func dispatch(_ args: [String]) -> Output {
        guard let first = args.first else {
            return get(idMode: true) // bare `imectl` → current ID
        }

        switch first {
        case "--version", "-V":
            return Output(version)
        case "--help", "-h":
            return Output(usage)
        case "get":
            return runGet(Array(args.dropFirst()))
        case "list":
            return runList(Array(args.dropFirst()))
        case "set":
            return runSet(Array(args.dropFirst()))
        default:
            return Output("error: unknown command '\(first)'\n\n\(usage)", .err, code: 2)
        }
    }

    private static func runGet(_ args: [String]) -> Output {
        var idMode = true
        for arg in args {
            switch arg {
            case "--id": idMode = true
            case "--name": idMode = false
            default:
                return Output("error: unknown option for get: '\(arg)'", .err, code: 2)
            }
        }
        return get(idMode: idMode)
    }

    private static func get(idMode: Bool) -> Output {
        guard let current = TIS.currentKeyboardSource() else {
            return Output("error: \(IMEError.noCurrentSource)", .err, code: 1)
        }
        let value = idMode ? current.id : current.localizedName
        guard let value else {
            return Output("error: current source has no \(idMode ? "id" : "name")", .err, code: 1)
        }
        return Output(value)
    }

    private static func runList(_ args: [String]) -> Output {
        var json = false
        for arg in args {
            switch arg {
            case "--json": json = true
            default:
                return Output("error: unknown option for list: '\(arg)'", .err, code: 2)
            }
        }
        let sources = TIS.selectableKeyboardSources()
        if json {
            return Output(JSON.array(sources))
        }
        let lines = sources.map { src -> String in
            let id = src.id ?? "?"
            let name = src.localizedName ?? ""
            return name.isEmpty ? id : "\(id)\t\(name)"
        }
        return Output(lines.joined(separator: "\n"))
    }

    private static func runSet(_ args: [String]) -> Output {
        guard let first = args.first else {
            return Output("error: set requires an <input-source-id> or --language <tag>", .err, code: 2)
        }
        do {
            let result: InputSource
            if first == "--language" {
                guard args.count >= 2 else {
                    return Output("error: --language requires a tag", .err, code: 2)
                }
                result = try TIS.select(language: args[1])
            } else {
                result = try TIS.select(id: first)
            }
            return Output(result.id ?? first)
        } catch let error as IMEError {
            let code: Int32 = switch error {
            case .notFound, .languageNotFound: 3
            case .notSelectable, .notEnabled: 4
            case .selectFailed, .selectUnconfirmed: 5
            case .noCurrentSource: 1
            }
            return Output("error: \(error)", .err, code: code)
        } catch {
            return Output("error: \(error)", .err, code: 1)
        }
    }
}
