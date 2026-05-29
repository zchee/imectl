import Carbon
import CoreFoundation

/// Errors raised by input-source operations, each mapping to a distinct CLI exit
/// path and a specific diagnostic.
public enum IMEError: Error, Equatable, CustomStringConvertible {
    case noCurrentSource
    case notFound(id: String)
    case languageNotFound(language: String)
    case notSelectable(id: String)
    case notEnabled(id: String)
    case selectFailed(id: String, status: OSStatus)
    case selectUnconfirmed(id: String, observed: String?)

    public var description: String {
        switch self {
        case .noCurrentSource:
            return "no current keyboard input source"
        case .notFound(let id):
            return "input source not found: \(id)"
        case .languageNotFound(let language):
            return "no input source for language: \(language)"
        case .notSelectable(let id):
            return "input source is not selectable: \(id)"
        case .notEnabled(let id):
            return "input source is not enabled: \(id)"
        case .selectFailed(let id, let status):
            return "failed to select \(id) (OSStatus \(status))"
        case .selectUnconfirmed(let id, let observed):
            return "select of \(id) was not confirmed (current is \(observed ?? "unknown"))"
        }
    }
}

/// Namespace for the Text Input Sources (TIS / Carbon HIToolbox) operations
/// imectl performs. This is the only system API capable of reading and switching
/// the *system* keyboard input source from a headless process.
public enum TIS {
    /// The currently selected keyboard input source, or `nil` if none.
    public static func currentKeyboardSource() -> InputSource? {
        guard let ref = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return InputSource(ref)
    }

    /// All keyboard-category input sources, unfiltered.
    public static func allKeyboardSources() -> [InputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource]
        else {
            return []
        }
        return list.map(InputSource.init)
    }

    /// Keyboard sources that can actually be switched to: enabled *and*
    /// selectable. This excludes mode-enabled parent methods (whose
    /// `isSelectable` is `false`); only their concrete modes survive the filter.
    public static func selectableKeyboardSources() -> [InputSource] {
        allKeyboardSources().filter { $0.isEnabled && $0.isSelectable }
    }

    /// Select an input source by its identifier.
    ///
    /// Validates that the target is enabled and selectable, calls
    /// `TISSelectInputSource`, checks the `OSStatus`, then re-queries to confirm
    /// the system actually switched (mitigating the known TIS stale-read issue).
    @discardableResult
    public static func select(id: String) throws -> InputSource {
        let candidates = allKeyboardSources().filter { $0.id == id }
        guard let target = candidates.first else {
            throw IMEError.notFound(id: id)
        }
        guard target.isEnabled else { throw IMEError.notEnabled(id: id) }
        guard target.isSelectable else { throw IMEError.notSelectable(id: id) }
        return try select(source: target, id: id)
    }

    /// Select the input source best matching a BCP-47 language tag.
    @discardableResult
    public static func select(language: String) throws -> InputSource {
        let cfLang = language as CFString
        guard let ref = TISCopyInputSourceForLanguage(cfLang)?.takeRetainedValue() else {
            throw IMEError.languageNotFound(language: language)
        }
        let target = InputSource(ref)
        let resolvedID = target.id ?? language
        guard target.isEnabled else { throw IMEError.notEnabled(id: resolvedID) }
        guard target.isSelectable else { throw IMEError.notSelectable(id: resolvedID) }
        return try select(source: target, id: resolvedID)
    }

    /// Core selection path shared by id- and language-based selection: perform
    /// the switch and confirm it took effect.
    private static func select(source: InputSource, id: String) throws -> InputSource {
        let status = TISSelectInputSource(source.ref)
        guard status == noErr else {
            throw IMEError.selectFailed(id: id, status: status)
        }
        // Re-query to confirm. TIS can briefly report stale state, so retry a
        // few times with a short sleep before declaring failure.
        for attempt in 0..<5 {
            if let current = currentKeyboardSource(), current.id == id {
                return current
            }
            if attempt < 4 { usleep(10_000) }
        }
        throw IMEError.selectUnconfirmed(id: id, observed: currentKeyboardSource()?.id)
    }
}
