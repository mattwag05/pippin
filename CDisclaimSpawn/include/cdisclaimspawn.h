#ifndef CDISCLAIMSPAWN_H
#define CDISCLAIMSPAWN_H

/// Re-exec the current executable as its own TCC "responsible process" (pippin-0vr).
///
/// Uses posix_spawn with the private `responsibility_spawnattrs_setdisclaim` SPI
/// (resolved via dlsym so it degrades gracefully if absent) so the spawned copy
/// is detached from the parent's TCC responsibility. macOS then keys
/// EventKit / Contacts / Automation consent on this binary's own code identity
/// (com.mattwag05.pippin) instead of whatever app happened to launch it
/// (Terminal, Codex, the Hermes gateway, launchd) — so one grant to pippin works
/// under every launcher.
///
/// argv/stdio/environ are inherited, so the re-exec is transparent to callers,
/// including the MCP JSON-RPC stdio pipe. Termination signals are forwarded to
/// the child.
///
/// Return value:
///   >= 0  the child ran to completion; this is its exit status. The caller
///         should `exit(status)` immediately.
///   -1    spawn failed; the caller should continue running in-process.
///   -2    the disclaim SPI is unavailable on this OS — no child was spawned;
///         the caller should continue in-process (re-exec would be a pointless
///         double-spawn that changes no responsibility).
int pippin_respawn_disclaimed(char *const argv[]);

#endif /* CDISCLAIMSPAWN_H */
