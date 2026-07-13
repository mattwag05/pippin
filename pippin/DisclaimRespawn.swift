import Foundation

/// Decides whether pippin should re-exec itself as its own TCC responsible
/// process (pippin-0vr). Pure and testable; the actual posix_spawn lives in the
/// `CDisclaimSpawn` C target and is wired up at the `@main` entry point.
///
/// macOS keys EventKit / Contacts / Automation consent on the *responsible*
/// (launching) process, not pippin's own binary — so a grant approved under one
/// launcher (Terminal) doesn't apply when pippin is spawned by another (Codex,
/// the [agent-runtime] gateway, launchd). Re-execing disclaimed makes pippin its own
/// responsible process, so a single grant to `com.mattwag05.pippin` works
/// everywhere.
public enum DisclaimRespawn {
    /// Set on the re-exec'd child so neither it nor any pippin it spawns re-execs
    /// again — one disclaim per process tree (descendants inherit pippin's
    /// responsibility).
    public static let guardKey = "PIPPIN_DISCLAIMED"

    /// Opt-out hatch for debugging or environments where the extra spawn is
    /// unwanted. Set to `1`/`true` to run in-process.
    public static let optOutKey = "PIPPIN_NO_DISCLAIM"

    /// True when this process should re-exec disclaimed: only the first pippin in
    /// a tree, and only when not explicitly opted out.
    public static func shouldRespawn(environment: [String: String]) -> Bool {
        if environment[guardKey] != nil { return false }
        if let optOut = environment[optOutKey],
           optOut == "1" || optOut.lowercased() == "true" {
            return false
        }
        return true
    }
}
