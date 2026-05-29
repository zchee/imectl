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

    Carbon-TIS-only by design; latency-optimized. See the project README.
    """

    /// Result of running a command: text to print, a stream, and an exit code.
    public struct Output: Equatable {
        public enum Stream: Equatable { case out, err }
        public var text: String
        public var stream: Stream
        public var code: Int32

        public init(_ text: String, _ stream: Stream = .out, code: Int32 = 0) {
            self.text = text
            self.stream = stream
            self.code = code
        }
    }

    /// Pure parse+dispatch over the argument list (excluding argv[0]). Side-effecting
    /// TIS reads/writes happen inside, but the routing is deterministic and the
    /// result is returned rather than printed, so callers (and tests) decide I/O.
    public static func run(_ args: [String]) -> Output {
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
