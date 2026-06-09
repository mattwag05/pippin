import Contacts
import EventKit
@testable import PippinLib
import XCTest

final class PermissionsTests: XCTestCase {
    // MARK: - Priming gate (pippin-dkf)

    /// The whole feature's safety hinges on this: only prime when a human at a
    /// TTY can answer the dialog. Every other combination must NOT prime.
    func testShouldPrimeOnlyWhenInteractiveAndNotStructuredAndNotMCP() {
        XCTAssertTrue(PermissionPriming.shouldPrime(interactive: true, isMCP: false, isStructuredOutput: false))

        // Any single disqualifier flips it off.
        XCTAssertFalse(PermissionPriming.shouldPrime(interactive: false, isMCP: false, isStructuredOutput: false))
        XCTAssertFalse(PermissionPriming.shouldPrime(interactive: true, isMCP: true, isStructuredOutput: false))
        XCTAssertFalse(PermissionPriming.shouldPrime(interactive: true, isMCP: false, isStructuredOutput: true))
        // …and combinations.
        XCTAssertFalse(PermissionPriming.shouldPrime(interactive: false, isMCP: true, isStructuredOutput: true))
    }

    // MARK: - Mechanism promptability

    func testFullDiskAccessIsNotPromptable() {
        XCTAssertFalse(PermissionMechanism.fullDiskAccess.isPromptable)
        XCTAssertTrue(PermissionMechanism.eventKit.isPromptable)
        XCTAssertTrue(PermissionMechanism.contacts.isPromptable)
        XCTAssertTrue(PermissionMechanism.automation.isPromptable)
    }

    // MARK: - Status mapping (pure, no TCC)

    func testEventKitStatusMapping() {
        XCTAssertEqual(PermissionMapping.state(forEventKit: .fullAccess), .granted)
        XCTAssertEqual(PermissionMapping.state(forEventKit: .notDetermined), .notDetermined)
        XCTAssertEqual(PermissionMapping.state(forEventKit: .denied), .denied)
        XCTAssertEqual(PermissionMapping.state(forEventKit: .restricted), .denied)
        // write-only (events) is insufficient — pippin needs full read.
        XCTAssertEqual(PermissionMapping.state(forEventKit: .writeOnly), .denied)
    }

    func testContactsStatusMapping() {
        XCTAssertEqual(PermissionMapping.state(forContacts: .authorized), .granted)
        XCTAssertEqual(PermissionMapping.state(forContacts: .notDetermined), .notDetermined)
        XCTAssertEqual(PermissionMapping.state(forContacts: .denied), .denied)
        XCTAssertEqual(PermissionMapping.state(forContacts: .restricted), .denied)
    }

    // MARK: - DiagnosticCheck → PermissionReport adapter (pure)

    func testAdapterGrantedFromOK() {
        let r = PermissionPrimer.report(
            from: DiagnosticCheck(name: "Mail automation", status: .ok, detail: "granted"),
            integration: "Mail", mechanism: .automation, listCommand: "pippin mail list"
        )
        XCTAssertEqual(r.state, .granted)
        XCTAssertNil(r.remediation, "granted reports carry no remediation")
    }

    func testAdapterAppNotRunningIsUnavailable() {
        let r = PermissionPrimer.report(
            from: DiagnosticCheck(name: "Notes automation", status: .fail, detail: "Notes.app is not running"),
            integration: "Notes", mechanism: .automation, listCommand: "pippin notes folders"
        )
        XCTAssertEqual(r.state, .unavailable)
        XCTAssertNil(r.remediation, "unavailable (app not running) isn't a permission problem")
    }

    func testAdapterAutomationDeniedIsDenied() {
        let r = PermissionPrimer.report(
            from: DiagnosticCheck(name: "Mail automation", status: .fail, detail: "permission denied"),
            integration: "Mail", mechanism: .automation, listCommand: "pippin mail list"
        )
        XCTAssertEqual(r.state, .denied)
        XCTAssertNotNil(r.remediation)
    }

    func testAdapterFullDiskAccessFailIsManualRequired() {
        let r = PermissionPrimer.report(
            from: DiagnosticCheck(name: "Messages access", status: .fail, detail: "permission denied"),
            integration: "Messages", mechanism: .fullDiskAccess, listCommand: "pippin messages list"
        )
        XCTAssertEqual(r.state, .manualRequired)
        XCTAssertTrue(try XCTUnwrap(r.remediation).humanHint.contains("Full Disk Access"))
    }

    func testAdapterFullDiskAccessDbNotFoundIsUnavailable() {
        let r = PermissionPrimer.report(
            from: DiagnosticCheck(name: "Messages access", status: .skip, detail: "no Messages database"),
            integration: "Messages", mechanism: .fullDiskAccess, listCommand: "pippin messages list"
        )
        XCTAssertEqual(r.state, .unavailable)
    }

    func testAdapterEventKitSkipIsNotDetermined() {
        let r = PermissionPrimer.report(
            from: DiagnosticCheck(name: "Reminders access", status: .skip, detail: "not yet granted"),
            integration: "Reminders", mechanism: .eventKit, listCommand: "pippin reminders list"
        )
        XCTAssertEqual(r.state, .notDetermined)
        XCTAssertNotNil(r.remediation)
    }

    // MARK: - JSON shape

    func testPermissionReportJSONSnakeCaseAndOmitsNilRemediation() throws {
        let granted = PermissionReport(
            integration: "Mail", mechanism: .automation, state: .granted, detail: "granted"
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(granted), encoding: .utf8))
        XCTAssertTrue(json.contains("\"mechanism\":\"automation\""))
        XCTAssertTrue(json.contains("\"state\":\"granted\""))
        XCTAssertTrue(json.contains("\"promptable\":true"))
        XCTAssertFalse(json.contains("remediation"), "nil remediation must be omitted, got: \(json)")
    }

    func testPermissionReportJSONEncodesMechanismRawValues() throws {
        let fda = PermissionReport(
            integration: "Voice Memos", mechanism: .fullDiskAccess, state: .manualRequired, detail: "x"
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(fda), encoding: .utf8))
        XCTAssertTrue(json.contains("\"mechanism\":\"full_disk_access\""))
        XCTAssertTrue(json.contains("\"state\":\"manual_required\""))
        XCTAssertTrue(json.contains("\"promptable\":false"))
    }

    func testPermissionReportRoundTrips() throws {
        let original = PermissionReport(
            integration: "Reminders", mechanism: .eventKit, state: .notDetermined, detail: "x",
            remediation: .privacyAccess(permission: "Reminders", listCommand: "pippin reminders list", doctorCheck: "Reminders access")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PermissionReport.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Doctor Messages check (pippin-0jx)

    /// `checkMessagesAccess` must exist and report under the "Messages access"
    /// name so `pippin doctor` covers the Messages integration.
    func testDoctorIncludesMessagesCheck() {
        let names = runAllChecks().map(\.name)
        XCTAssertTrue(names.contains("Messages access"), "doctor must include a Messages access check, got: \(names)")
    }

    // MARK: - FDA remediation factory

    func testFullDiskAccessRemediationNamesIntegration() {
        let r = Remediation.fullDiskAccess(integration: "Messages", listCommand: "pippin messages list")
        XCTAssertTrue(r.humanHint.contains("Full Disk Access"))
        XCTAssertTrue(r.humanHint.contains("Messages"))
        XCTAssertEqual(r.doctorCheck, "Messages access")
    }
}
