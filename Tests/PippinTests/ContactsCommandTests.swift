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

    func testContactsCommandHasExactlyFourSubcommands() {
        XCTAssertEqual(ContactsCommand.configuration.subcommands.count, 4)
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
}
