import Carbon
import CoreFoundation

/// A thin, value-like wrapper over a Carbon `TISInputSource` that exposes the
/// input-source properties imectl needs.
///
/// Ownership note: `TISInputSource` is a `CFType`. Instances obtained from
/// `TISCopy*` / `TISCreateInputSourceList` are owned (`+1`) and must be released;
/// ARC handles that once the ref is held by this struct. Property reads via
/// `TISGetInputSourceProperty` return *borrowed* values (`+0`), so they are read
/// with `takeUnretainedValue()`.
public struct InputSource {
    /// The retained Carbon reference backing this input source.
    public let ref: TISInputSource

    public init(_ ref: TISInputSource) {
        self.ref = ref
    }

    /// Reads a borrowed `CFString` property and bridges it to a Swift `String`.
    private func stringProperty(_ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(ref, key) else { return nil }
        let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cf as String
    }

    /// Reads a borrowed `CFBoolean` property.
    private func boolProperty(_ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(ref, key) else { return false }
        let cf = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        return CFBooleanGetValue(cf)
    }

    /// The reverse-DNS input-source identifier, e.g. `com.apple.keylayout.ABC`.
    public var id: String? { stringProperty(kTISPropertyInputSourceID) }

    /// The user-facing localized name, e.g. `ABC` or `Hiragana`.
    public var localizedName: String? { stringProperty(kTISPropertyLocalizedName) }

    /// The category, e.g. `kTISCategoryKeyboardInputSource`.
    public var category: String? { stringProperty(kTISPropertyInputSourceCategory) }

    /// The type, e.g. `kTISTypeKeyboardLayout`, `kTISTypeKeyboardInputMode`.
    public var type: String? { stringProperty(kTISPropertyInputSourceType) }

    /// The input-mode ID for mode-enabled methods, e.g.
    /// `com.apple.inputmethod.Japanese.Hiragana`.
    public var inputModeID: String? { stringProperty(kTISPropertyInputModeID) }

    /// Whether this source can be programmatically selected.
    ///
    /// Mode-enabled parent methods report `false`; only their concrete modes are
    /// selectable.
    public var isSelectable: Bool { boolProperty(kTISPropertyInputSourceIsSelectCapable) }

    /// Whether this source is currently enabled.
    public var isEnabled: Bool { boolProperty(kTISPropertyInputSourceIsEnabled) }

    /// Whether this source is the currently selected one.
    public var isSelected: Bool { boolProperty(kTISPropertyInputSourceIsSelected) }
}
