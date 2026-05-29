/// Translates a single daemon-protocol request line into a reply line by
/// performing the corresponding TIS operation. Shared by the daemon server; the
/// in-process fast path uses `CLI.run` directly instead.
public enum RequestHandler {
    public static func handle(_ line: String) -> String {
        let trimmed = line.trimmingTrailingNewline()
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""

        switch verb {
        case "get":
            guard let current = TIS.currentKeyboardSource(), let id = current.id else {
                return errorReply(.noCurrentSource)
            }
            return id
        case "get-name":
            guard let current = TIS.currentKeyboardSource(), let name = current.localizedName else {
                return errorReply(.noCurrentSource)
            }
            return name
        case "list":
            let rows = TIS.selectableKeyboardSources().map { src -> String in
                let id = src.id ?? "?"
                let name = src.localizedName ?? ""
                return name.isEmpty ? id : "\(id)\t\(name)"
            }
            return rows.joined(separator: DaemonProtocol.rowSeparator)
        case "list-json":
            return JSON.array(TIS.selectableKeyboardSources())
        case "set":
            return performSet(fallbackID: arg) { try TIS.select(id: arg) }
        case "set-lang":
            return performSet(fallbackID: arg) { try TIS.select(language: arg) }
        default:
            return "err 2 unknown request: \(verb)"
        }
    }

    private static func performSet(
        fallbackID: String,
        _ op: () throws -> InputSource
    ) -> String {
        do {
            let result = try op()
            return "ok " + (result.id ?? fallbackID)
        } catch let error as IMEError {
            return errorReply(error)
        } catch {
            return "err 1 \(error)"
        }
    }

    private static func errorReply(_ error: IMEError) -> String {
        let code: Int32 = switch error {
        case .notFound, .languageNotFound: 3
        case .notSelectable, .notEnabled: 4
        case .selectFailed, .selectUnconfirmed: 5
        case .noCurrentSource: 1
        }
        return "err \(code) \(error)"
    }
}

extension String {
    /// Drop a single trailing `\n` if present.
    func trimmingTrailingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
