import Contacts
import EventKit
import Foundation

/// The macOS privacy mechanism that gates an integration's access. Different
/// mechanisms are granted in different System Settings panes and have very
/// different prompting behavior — only the first three can be triggered
/// programmatically; Full Disk Access can not. (pippin-uu3)
public enum PermissionMechanism: String, Codable, Sendable {
    /// System Settings > Privacy & Security > Reminders / Calendars (EventKit).
    case eventKit = "event_kit"
    /// System Settings > Privacy & Security > Contacts.
    case contacts
    /// System Settings > Privacy & Security > Automation (Apple Events).
    case automation
    /// System Settings > Privacy & Security > Full Disk Access — NOT promptable.
    case fullDiskAccess = "full_disk_access"

    /// Whether pippin can trigger an interactive OS prompt for this mechanism.
    /// Full Disk Access has no request API — the user must toggle it manually.
    public var isPromptable: Bool {
        self != .fullDiskAccess
    }
}

/// Current state of a single integration's permission.
public enum PermissionState: String, Codable, Sendable {
    /// Access granted — calls will succeed.
    case granted
    /// Explicitly denied or restricted — needs a manual grant in System Settings.
    case denied
    /// Promptable but never asked yet. Safe to resolve with one interactive
    /// `pippin permissions` run; left alone it becomes the background
    /// silent-denial trap.
    case notDetermined = "not_determined"
    /// Full Disk Access not yet granted — no prompt exists, user must toggle it.
    case manualRequired = "manual_required"
    /// The backing app isn't installed/running, so status can't be determined.
    case unavailable
    /// Unrecognized status (future macOS enum case).
    case unknown
}

/// One integration's permission, its mechanism, and how to obtain it. The
/// stable serialized shape consumed by `pippin permissions --status` /
/// `--format agent`.
public struct PermissionReport: Codable, Sendable, Equatable {
    /// Human label, e.g. "Reminders", "Mail".
    public let integration: String
    public let mechanism: PermissionMechanism
    public let state: PermissionState
    /// Whether pippin can trigger a prompt for this (mirrors `mechanism.isPromptable`).
    public let promptable: Bool
    public let detail: String
    public let remediation: Remediation?

    public init(
        integration: String,
        mechanism: PermissionMechanism,
        state: PermissionState,
        detail: String,
        remediation: Remediation? = nil
    ) {
        self.integration = integration
        self.mechanism = mechanism
        self.state = state
        promptable = mechanism.isPromptable
        self.detail = detail
        self.remediation = remediation
    }

    private enum CodingKeys: String, CodingKey {
        case integration, mechanism, state, promptable, detail, remediation
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(integration, forKey: .integration)
        try c.encode(mechanism, forKey: .mechanism)
        try c.encode(state, forKey: .state)
        try c.encode(promptable, forKey: .promptable)
        try c.encode(detail, forKey: .detail)
        // Omit (not null) when absent, matching the AgentError/Remediation shape.
        try c.encodeIfPresent(remediation, forKey: .remediation)
    }
}

/// Decision logic for whether onboarding/`permissions` may proactively trigger
/// TCC prompts. Pure and total so it can be unit-tested without a GUI.
public enum PermissionPriming {
    /// Prime (trigger prompts) ONLY when there is an interactive user at a TTY
    /// who can answer the dialog. Never under MCP, and never when emitting
    /// structured output (`--format agent|json`): triggering a prompt that
    /// can't be answered is precisely the silent-denial trap this feature
    /// exists to prevent. (pippin-dkf)
    public static func shouldPrime(
        interactive: Bool,
        isMCP: Bool,
        isStructuredOutput: Bool
    ) -> Bool {
        interactive && !isMCP && !isStructuredOutput
    }
}

// MARK: - Pure status mapping (testable without TCC)

public enum PermissionMapping {
    /// Map an EventKit authorization status to a `PermissionState`. `.writeOnly`
    /// (events) counts as `denied` — pippin needs full read access.
    public static func state(forEventKit status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted, .writeOnly:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    /// Map a Contacts authorization status to a `PermissionState`.
    public static func state(forContacts status: CNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            // Covers `.limited` (and any future case): treat as not-granted but
            // not hard-denied so the report nudges the user to re-grant.
            return .unknown
        }
    }
}
