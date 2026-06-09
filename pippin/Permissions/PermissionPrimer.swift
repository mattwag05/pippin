import Contacts
import EventKit
import Foundation

/// Triggers and inventories the macOS privacy permissions each pippin app
/// integration depends on.
///
/// Two responsibilities, deliberately separated by prompting behavior:
///
/// - **Priming** (`prime*`): proactively triggers an interactive TCC prompt for
///   the promptable mechanisms (EventKit Reminders/Calendar, Contacts, and the
///   Automation prompt for Mail/Notes). Safe to call ONLY when there's a user
///   at a TTY to answer — see `PermissionPriming.shouldPrime`. Resolving every
///   prompt once, interactively, is what keeps later background/agent use from
///   hitting an unanswerable prompt.
/// - **Inventory** (`currentReports`): read-only. Reports each integration's
///   state without triggering anything. Used by `pippin permissions --status`,
///   `--format agent|json`, and the MCP path.
///
/// (pippin-uu3)
public enum PermissionPrimer {
    // MARK: - Priming (interactive — triggers prompts)

    /// Trigger the Reminders prompt if not yet determined. Returns the resulting
    /// state. Never throws — a denial is a state, not an error.
    public static func primeReminders() async -> PermissionState {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess || status == .authorized { return .granted }
        if status == .denied || status == .restricted { return .denied }
        do {
            let granted = try await EKEventStore().requestFullAccessToReminders()
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    /// Trigger the Calendar prompt if not yet determined.
    public static func primeCalendar() async -> PermissionState {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess || status == .authorized { return .granted }
        if status == .denied || status == .restricted { return .denied }
        do {
            let granted = try await EKEventStore().requestFullAccessToEvents()
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    /// Trigger the Contacts prompt if not yet determined.
    public static func primeContacts() async -> PermissionState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .granted }
        if status == .denied || status == .restricted { return .denied }
        let granted: Bool = await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        return granted ? .granted : .denied
    }

    /// Trigger the Automation (Apple Events) prompt for an app by performing a
    /// minimal read through its bridge. Best-effort: a thrown error means the
    /// app isn't reachable yet (not running, no accounts, or denied) — the
    /// inventory pass reports the precise state. Synchronous + thread-blocking
    /// (JXA); callers must run it inside `detachBlocking`.
    public static func primeMailAutomation() {
        _ = try? MailBridge.listAccounts()
    }

    public static func primeNotesAutomation() {
        _ = try? NotesBridge.listFolders()
    }

    // MARK: - Inventory (read-only — triggers nothing)

    /// The five promptable integrations plus the two Full Disk Access ones,
    /// reported without side effects. The framework permissions come from their
    /// `authorizationStatus` APIs (instant, accurate); Mail/Notes/Voice
    /// Memos/Messages reuse the doctor checks (which must attempt access to know
    /// their state). Synchronous + thread-blocking via the doctor checks;
    /// callers must run it inside `detachBlocking`.
    public static func currentReports() -> [PermissionReport] {
        [
            eventKitReport(integration: "Reminders", entity: .reminder, listCommand: "pippin reminders list"),
            eventKitReport(integration: "Calendar", entity: .event, listCommand: "pippin calendar list"),
            contactsReport(),
            report(
                from: checkMailAutomation(),
                integration: "Mail",
                mechanism: .automation,
                listCommand: "pippin mail list"
            ),
            report(
                from: checkNotesAccess(),
                integration: "Notes",
                mechanism: .automation,
                listCommand: "pippin notes folders"
            ),
            report(
                from: checkVoiceMemosDB(),
                integration: "Voice Memos",
                mechanism: .fullDiskAccess,
                listCommand: "pippin memos list"
            ),
            report(
                from: checkMessagesAccess(),
                integration: "Messages",
                mechanism: .fullDiskAccess,
                listCommand: "pippin messages list"
            ),
        ]
    }

    // MARK: - Report builders

    private static func eventKitReport(
        integration: String,
        entity: EKEntityType,
        listCommand: String
    ) -> PermissionReport {
        frameworkReport(
            integration: integration,
            mechanism: .eventKit,
            state: PermissionMapping.state(forEventKit: EKEventStore.authorizationStatus(for: entity)),
            listCommand: listCommand
        )
    }

    private static func contactsReport() -> PermissionReport {
        frameworkReport(
            integration: "Contacts",
            mechanism: .contacts,
            state: PermissionMapping.state(forContacts: CNContactStore.authorizationStatus(for: .contacts)),
            listCommand: "pippin contacts list"
        )
    }

    /// Build a report for a promptable framework permission (EventKit/Contacts)
    /// whose state came from a pure `authorizationStatus` mapping. A non-granted
    /// state always carries the matching `.privacyAccess` remediation.
    private static func frameworkReport(
        integration: String,
        mechanism: PermissionMechanism,
        state: PermissionState,
        listCommand: String
    ) -> PermissionReport {
        PermissionReport(
            integration: integration,
            mechanism: mechanism,
            state: state,
            detail: detail(for: state, integration: integration),
            remediation: state == .granted ? nil : .privacyAccess(
                permission: integration,
                listCommand: listCommand,
                doctorCheck: "\(integration) access"
            )
        )
    }

    /// Adapt a doctor `DiagnosticCheck` into a `PermissionReport`. Pure — the
    /// state mapping is driven by the check's status + detail and the mechanism.
    static func report(
        from check: DiagnosticCheck,
        integration: String,
        mechanism: PermissionMechanism,
        listCommand: String
    ) -> PermissionReport {
        let state: PermissionState
        switch check.status {
        case .ok:
            state = .granted
        case .skip:
            // Doctor uses .skip for "not yet determined" / "app never used".
            state = mechanism == .fullDiskAccess ? .unavailable : .notDetermined
        case .fail:
            let d = check.detail.lowercased()
            if d.contains("not running") || d.contains("not found") || d.contains("not installed") {
                state = .unavailable
            } else if mechanism == .fullDiskAccess {
                state = .manualRequired
            } else {
                state = .denied
            }
        }
        // Prefer the check's own remediation; fall back to a mechanism-correct
        // one so a report always tells the user how to fix a non-granted state.
        let remediation: Remediation? = {
            if state == .granted || state == .unavailable { return nil }
            if let r = check.remediation { return r }
            return mechanism == .fullDiskAccess
                ? .fullDiskAccess(integration: integration, listCommand: listCommand)
                : .privacyAccess(permission: integration, listCommand: listCommand, doctorCheck: "\(integration) access")
        }()
        return PermissionReport(
            integration: integration,
            mechanism: mechanism,
            state: state,
            detail: check.detail,
            remediation: remediation
        )
    }

    private static func detail(for state: PermissionState, integration: String) -> String {
        switch state {
        case .granted: return "granted"
        case .denied: return "permission denied — grant in System Settings"
        case .notDetermined: return "not yet granted — run `pippin permissions` to grant interactively"
        case .manualRequired: return "needs Full Disk Access (grant manually)"
        case .unavailable: return "\(integration) is unavailable"
        case .unknown: return "unknown status"
        }
    }
}
