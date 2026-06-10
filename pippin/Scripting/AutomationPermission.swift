import CoreServices
import Foundation

/// Pre-flight check for whether the current process may control a target app via
/// Automation (Apple Events), used to fast-fail JXA scripts instead of letting
/// `osascript` block to the soft-timeout when the grant is missing.
///
/// Why this exists: once pippin disclaims TCC responsibility (pippin-0vr) it runs
/// under its OWN identity for Apple Events too. Until that identity is granted
/// Automation control of Mail/Notes/Messages, a JXA call BLOCKS to the 22s
/// soft-timeout in a non-interactive context (the Apple-Events analog of the
/// EventKit hang fixed in pippin-0vr). `AEDeterminePermissionToAutomateTarget`
/// answers "would this be permitted?" immediately, so we can throw a fast
/// `access_denied` instead of hanging. (pippin-qjf)
public enum AutomationPermission {
    /// Whether a JXA script targeting an app should run or fast-fail.
    public enum Decision: Sendable, Equatable {
        /// Proceed — authorized, target not running yet, or an unexpected status
        /// we'd rather not block on.
        case allow
        /// Fast-fail — the OS reported an explicit denial or an undetermined
        /// status it couldn't (or wasn't allowed to) resolve via a prompt.
        case deny
    }

    /// Pure mapping from an `AEDeterminePermissionToAutomateTarget` result to a
    /// run/deny decision. ONLY an explicit denial (`errAEEventNotPermitted`) or
    /// an undetermined-but-unpromptable result (`errAEEventWouldRequireUserConsent`)
    /// fast-fails. Everything else — authorized (`noErr`), target not running
    /// (`procNotFound`), or any unexpected code — proceeds, so a surprise status
    /// never regresses a working setup. Testable without TCC.
    public static func decision(for status: OSStatus) -> Decision {
        switch status {
        case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent):
            return .deny
        default:
            return .allow
        }
    }

    /// Ask macOS whether the current (disclaimed) process may send Apple Events
    /// to `bundleID`. `askUserIfNeeded` must be true ONLY when an interactive
    /// user can answer the prompt (see `PermissionPriming.canRequestAccess`) —
    /// otherwise the call returns immediately with a non-authorized status rather
    /// than blocking on a dialog that can't appear.
    public static func rawStatus(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        guard let data = bundleID.data(using: .utf8) else { return noErr }
        var target = AEAddressDesc()
        let createStatus = data.withUnsafeBytes { raw -> OSStatus in
            OSStatus(AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &target))
        }
        // If we can't even build the target descriptor, don't block — let the
        // normal script path run (it will surface any real failure itself).
        guard createStatus == noErr else { return noErr }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    /// Live checker injected into `ScriptRunner.run`: the pure `decision` layered
    /// over the real `AEDeterminePermissionToAutomateTarget` call.
    public static let liveCheck: @Sendable (String, Bool) -> Decision = { bundleID, canPrompt in
        decision(for: rawStatus(bundleID: bundleID, askUserIfNeeded: canPrompt))
    }
}
