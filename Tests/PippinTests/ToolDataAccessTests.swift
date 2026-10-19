@testable import PippinLib
import XCTest

final class ToolDataAccessTests: XCTestCase {
    func testEveryRegisteredToolIsClassified() {
        let unclassified = MCPToolRegistry.tools.map(\.name).filter { ToolDataAccess.kinds(for: $0) == nil }
        XCTAssertEqual(unclassified, [], "add these tools to ToolDataAccess.explicit")
    }

    func testCrossCuttingToolsDeclareTheAppsTheyOpen() throws {
        XCTAssertEqual(ToolDataAccess.kinds(for: "doctor"), Set(PersonalDataKind.allCases))
        let status = try XCTUnwrap(ToolDataAccess.kinds(for: "status"))
        XCTAssertTrue(status.isSuperset(of: [.mail, .calendar, .notes, .contacts]))
        XCTAssertEqual(ToolDataAccess.kinds(for: "batch"), Set(PersonalDataKind.allCases))
        XCTAssertEqual(ToolDataAccess.kinds(for: "mail_list"), [.mail, .contacts])
        XCTAssertEqual(ToolDataAccess.kinds(for: "calendar_today"), [.calendar])
    }

    func testAllowedToolsDropsEveryToolTouchingAnExcludedKind() {
        let excluded: Set<PersonalDataKind> = [.mail, .messages, .notes, .contacts, .calendar]
        let allowed = ToolDataAccess.allowedTools(MCPToolRegistry.tools, excluding: excluded)
        XCTAssertFalse(allowed.isEmpty, "the filter must leave a surface to check against")
        let names = Set(allowed.map(\.name))
        for name in ["status", "doctor", "digest", "batch", "job_run", "mail_list", "calendar_today"] {
            XCTAssertFalse(names.contains(name), "\(name) must be excluded")
        }
        XCTAssertTrue(names.contains("reminders_lists"))
        for tool in allowed {
            XCTAssertTrue(ToolDataAccess.kinds(for: tool.name)?.isDisjoint(with: excluded) == true)
        }
    }

    func testNoExclusionsKeepsFullSurface() {
        XCTAssertEqual(
            ToolDataAccess.allowedTools(MCPToolRegistry.tools, excluding: []).count,
            MCPToolRegistry.tools.count
        )
    }
}
