import ArgumentParser
import Foundation

/// Shared `--no-contacts` / `--contacts` flags for every command that resolves
/// Mail/Messages handles to Apple Contacts names. Mirrors the `OutputOptions`
/// convention: declare once per command via `@OptionGroup` instead of repeating
/// the two `@Flag`s in each struct. Owns the resolution-precedence decision so
/// the rule lives in one place (it's contacts logic, not AI-provider logic).
public struct ContactResolutionOptions: ParsableArguments {
    @Flag(name: .customLong("no-contacts"), help: "Don't resolve handles to Apple Contacts names.")
    public var noContacts = false

    @Flag(name: .customLong("contacts"), help: "Force resolving handles to Apple Contacts names, overriding the resolveContacts config default.")
    public var contacts = false

    public init() {}

    /// Whether output should resolve handles to Apple Contacts names, honoring
    /// the configured flags. Pass the loaded `config` (or `nil`) for the default.
    public func shouldResolve(config: PippinConfig?) -> Bool {
        Self.shouldResolve(noContacts: noContacts, contacts: contacts, config: config)
    }

    /// Pure precedence rule, exposed statically so it's testable without parsing:
    /// explicit flag > `resolveContacts` config > built-in default (ON).
    ///
    /// `--no-contacts` wins over `--contacts` if both are somehow set (OFF is the
    /// safe/cheap choice). When neither flag is set the config default applies;
    /// when the config is absent or `resolveContacts` is unset, resolution is ON.
    static func shouldResolve(noContacts: Bool, contacts: Bool, config: PippinConfig?) -> Bool {
        if noContacts { return false }
        if contacts { return true }
        return config?.resolveContacts ?? true
    }
}
