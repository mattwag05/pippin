@testable import PippinLib
import XCTest

final class ContactsCommandTests: XCTestCase {
    // MARK: - ContactsCommand Configuration

    func testContactsCommandName() {
        XCTAssertEqual(ContactsCommand.configuration.commandName, "contacts")
    }

    func testContactsCommandHasListSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("list"))
    }

    func testContactsCommandHasSearchSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("search"))
    }

    func testContactsCommandHasShowSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("show"))
    }

    func testContactsCommandHasGroupsSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("groups"))
    }

    func testContactsCommandHasCreateSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("create"))
    }

    func testContactsCommandHasEditSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("edit"))
    }

    func testContactsCommandHasDeleteSubcommand() {
        let subcommands = ContactsCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("delete"))
    }

    func testContactsCommandHasExactlySevenSubcommands() {
        XCTAssertEqual(ContactsCommand.configuration.subcommands.count, 7)
    }

    // MARK: - Subcommand Names

    func testListContactsCommandName() {
        XCTAssertEqual(ContactsCommand.ListContacts.configuration.commandName, "list")
    }

    func testSearchContactsCommandName() {
        XCTAssertEqual(ContactsCommand.SearchContacts.configuration.commandName, "search")
    }

    func testShowContactCommandName() {
        XCTAssertEqual(ContactsCommand.ShowContact.configuration.commandName, "show")
    }

    func testListGroupsCommandName() {
        XCTAssertEqual(ContactsCommand.ListGroups.configuration.commandName, "groups")
    }

    // MARK: - ListContacts Parse Tests

    func testListContactsParseNoArgs() {
        XCTAssertNoThrow(try ContactsCommand.ListContacts.parse([]))
    }

    func testListContactsGroupDefault() throws {
        let cmd = try ContactsCommand.ListContacts.parse([])
        XCTAssertNil(cmd.group)
    }

    func testListContactsFieldsDefault() throws {
        let cmd = try ContactsCommand.ListContacts.parse([])
        XCTAssertNil(cmd.fields)
    }

    func testListContactsGroupOption() throws {
        let cmd = try ContactsCommand.ListContacts.parse(["--group", "Family"])
        XCTAssertEqual(cmd.group, "Family")
    }

    func testListContactsFieldsOption() throws {
        let cmd = try ContactsCommand.ListContacts.parse(["--fields", "name,email"])
        XCTAssertEqual(cmd.fields, "name,email")
    }

    func testListContactsGroupAndFieldsTogether() throws {
        let cmd = try ContactsCommand.ListContacts.parse(["--group", "Work", "--fields", "email,phone"])
        XCTAssertEqual(cmd.group, "Work")
        XCTAssertEqual(cmd.fields, "email,phone")
    }

    // MARK: - SearchContacts Parse Tests

    func testSearchContactsRequiresQuery() {
        XCTAssertThrowsError(try ContactsCommand.SearchContacts.parse([]))
    }

    func testSearchContactsParseWithQuery() {
        XCTAssertNoThrow(try ContactsCommand.SearchContacts.parse(["John"]))
    }

    func testSearchContactsQueryValue() throws {
        let cmd = try ContactsCommand.SearchContacts.parse(["Jane Doe"])
        XCTAssertEqual(cmd.query, "Jane Doe")
    }

    func testSearchContactsEmailFlagDefaultFalse() throws {
        let cmd = try ContactsCommand.SearchContacts.parse(["query"])
        XCTAssertFalse(cmd.email)
    }

    func testSearchContactsEmailFlagSetTrue() throws {
        let cmd = try ContactsCommand.SearchContacts.parse(["query", "--email"])
        XCTAssertTrue(cmd.email)
    }

    func testSearchContactsFieldsDefault() throws {
        let cmd = try ContactsCommand.SearchContacts.parse(["query"])
        XCTAssertNil(cmd.fields)
    }

    func testSearchContactsFieldsOption() throws {
        let cmd = try ContactsCommand.SearchContacts.parse(["query", "--fields", "name,phone"])
        XCTAssertEqual(cmd.fields, "name,phone")
    }

    func testSearchContactsAllOptions() throws {
        let cmd = try ContactsCommand.SearchContacts.parse(["Alice", "--email", "--fields", "email"])
        XCTAssertEqual(cmd.query, "Alice")
        XCTAssertTrue(cmd.email)
        XCTAssertEqual(cmd.fields, "email")
    }

    // MARK: - ShowContact Parse Tests

    func testShowContactRequiresIdentifier() {
        XCTAssertThrowsError(try ContactsCommand.ShowContact.parse([]))
    }

    func testShowContactParseWithIdentifier() {
        XCTAssertNoThrow(try ContactsCommand.ShowContact.parse(["abc-123"]))
    }

    func testShowContactIdentifierValue() throws {
        let cmd = try ContactsCommand.ShowContact.parse(["contact-id-456"])
        XCTAssertEqual(cmd.identifier, "contact-id-456")
    }

    // MARK: - ListGroups Parse Tests

    func testListGroupsParseNoArgs() {
        XCTAssertNoThrow(try ContactsCommand.ListGroups.parse([]))
    }

    // MARK: - CreateContact Parse Tests

    func testCreateContactCommandName() {
        XCTAssertEqual(ContactsCommand.CreateContact.configuration.commandName, "create")
    }

    func testCreateContactParseNoArgs() {
        XCTAssertNoThrow(try ContactsCommand.CreateContact.parse([]))
    }

    func testCreateContactFirstOption() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--first", "Alice"])
        XCTAssertEqual(cmd.first, "Alice")
    }

    func testCreateContactLastOption() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--last", "Smith"])
        XCTAssertEqual(cmd.last, "Smith")
    }

    func testCreateContactEmailOption() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--first", "Alice", "--email", "alice@example.com"])
        XCTAssertEqual(cmd.email, "alice@example.com")
    }

    func testCreateContactPhoneOption() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--first", "Alice", "--phone", "+15551234567"])
        XCTAssertEqual(cmd.phone, "+15551234567")
    }

    func testCreateContactOrganizationOption() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--first", "Alice", "--organization", "Acme"])
        XCTAssertEqual(cmd.organization, "Acme")
    }

    func testCreateContactJobTitleOption() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--first", "Alice", "--job-title", "Engineer"])
        XCTAssertEqual(cmd.jobTitle, "Engineer")
    }

    func testCreateContactEmailDefaultNil() throws {
        let cmd = try ContactsCommand.CreateContact.parse(["--first", "Alice"])
        XCTAssertNil(cmd.email)
    }

    func testCreateContactFirstDefaultNil() throws {
        let cmd = try ContactsCommand.CreateContact.parse([])
        XCTAssertNil(cmd.first)
    }

    func testCreateContactLastDefaultNil() throws {
        let cmd = try ContactsCommand.CreateContact.parse([])
        XCTAssertNil(cmd.last)
    }

    // MARK: - EditContact Parse Tests

    func testEditContactCommandName() {
        XCTAssertEqual(ContactsCommand.EditContact.configuration.commandName, "edit")
    }

    func testEditContactRequiresIdentifier() {
        XCTAssertThrowsError(try ContactsCommand.EditContact.parse([]))
    }

    func testEditContactParseWithIdentifier() {
        XCTAssertNoThrow(try ContactsCommand.EditContact.parse(["abc-123", "--first", "Bob"]))
    }

    func testEditContactIdentifierValue() throws {
        let cmd = try ContactsCommand.EditContact.parse(["contact-xyz", "--last", "Jones"])
        XCTAssertEqual(cmd.identifier, "contact-xyz")
    }

    func testEditContactFirstOption() throws {
        let cmd = try ContactsCommand.EditContact.parse(["id-1", "--first", "Carol"])
        XCTAssertEqual(cmd.first, "Carol")
    }

    func testEditContactAllOptionsNilByDefault() throws {
        let cmd = try ContactsCommand.EditContact.parse(["id-1", "--first", "Carol"])
        XCTAssertNil(cmd.last)
        XCTAssertNil(cmd.email)
        XCTAssertNil(cmd.phone)
        XCTAssertNil(cmd.organization)
        XCTAssertNil(cmd.jobTitle)
    }

    // MARK: - DeleteContact Parse Tests

    func testDeleteContactCommandName() {
        XCTAssertEqual(ContactsCommand.DeleteContact.configuration.commandName, "delete")
    }

    func testDeleteContactRequiresIdentifier() {
        XCTAssertThrowsError(try ContactsCommand.DeleteContact.parse([]))
    }

    func testDeleteContactParseWithIdentifier() {
        XCTAssertNoThrow(try ContactsCommand.DeleteContact.parse(["abc-123"]))
    }

    func testDeleteContactIdentifierValue() throws {
        let cmd = try ContactsCommand.DeleteContact.parse(["contact-to-delete"])
        XCTAssertEqual(cmd.identifier, "contact-to-delete")
    }

    func testDeleteContactForceFlagDefaultFalse() throws {
        let cmd = try ContactsCommand.DeleteContact.parse(["some-id"])
        XCTAssertFalse(cmd.force)
    }

    func testDeleteContactForceFlagSetTrue() throws {
        let cmd = try ContactsCommand.DeleteContact.parse(["some-id", "--force"])
        XCTAssertTrue(cmd.force)
    }

    // MARK: - ContactActionResult Tests

    func testContactActionResultRoundTrip() throws {
        let result = ContactActionResult(
            success: true,
            action: "create",
            details: ["id": "abc-123", "fullName": "Alice Smith"]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ContactActionResult.self, from: data)

        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.action, "create")
        XCTAssertEqual(decoded.details["id"], "abc-123")
        XCTAssertEqual(decoded.details["fullName"], "Alice Smith")
    }

    func testContactActionResultDeleteAction() {
        let result = ContactActionResult(
            success: true,
            action: "delete",
            details: ["id": "xyz-789", "fullName": "Bob Jones"]
        )
        XCTAssertEqual(result.action, "delete")
        XCTAssertTrue(result.success)
    }
}
