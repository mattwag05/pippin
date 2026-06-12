@testable import PippinLib
import XCTest

final class ContactResolutionOptionsTests: XCTestCase {
    // MARK: - Pure precedence rule (flag > config > default-ON)

    func testDefaultsOnWhenConfigAbsentAndNoFlags() {
        // No config and no flags → resolution ON (non-breaking default).
        XCTAssertTrue(ContactResolutionOptions.shouldResolve(noContacts: false, contacts: false, config: nil))
    }

    func testDefaultsOnWhenConfigUnset() {
        // Config present but resolveContacts unset → ON.
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: nil)
        XCTAssertTrue(ContactResolutionOptions.shouldResolve(noContacts: false, contacts: false, config: config))
    }

    func testConfigFalseDisables() {
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: false)
        XCTAssertFalse(ContactResolutionOptions.shouldResolve(noContacts: false, contacts: false, config: config))
    }

    func testConfigTrueEnables() {
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: true)
        XCTAssertTrue(ContactResolutionOptions.shouldResolve(noContacts: false, contacts: false, config: config))
    }

    func testNoContactsFlagOverridesConfigTrue() {
        // --no-contacts wins over a config that enables resolution.
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: true)
        XCTAssertFalse(ContactResolutionOptions.shouldResolve(noContacts: true, contacts: false, config: config))
    }

    func testContactsFlagOverridesConfigFalse() {
        // --contacts wins over a config that disables resolution.
        let config = PippinConfig(ai: nil, messages: nil, resolveContacts: false)
        XCTAssertTrue(ContactResolutionOptions.shouldResolve(noContacts: false, contacts: true, config: config))
    }

    func testNoContactsBeatsContactsWhenBothSet() {
        // If both flags are somehow set, OFF (the cheap/safe choice) wins.
        XCTAssertFalse(ContactResolutionOptions.shouldResolve(noContacts: true, contacts: true, config: nil))
    }

    // MARK: - Instance method delegates to its parsed flags

    func testInstanceShouldResolveUsesItsFlags() {
        var off = ContactResolutionOptions()
        off.noContacts = true
        XCTAssertFalse(off.shouldResolve(config: PippinConfig(ai: nil, messages: nil, resolveContacts: true)))

        var on = ContactResolutionOptions()
        on.contacts = true
        XCTAssertTrue(on.shouldResolve(config: PippinConfig(ai: nil, messages: nil, resolveContacts: false)))

        // No flags set → config default applies.
        let bare = ContactResolutionOptions()
        XCTAssertFalse(bare.shouldResolve(config: PippinConfig(ai: nil, messages: nil, resolveContacts: false)))
        XCTAssertTrue(bare.shouldResolve(config: nil))
    }

    // MARK: - The flags parse from the CLI surface

    func testFlagsParse() throws {
        let off = try ContactResolutionOptions.parse(["--no-contacts"])
        XCTAssertTrue(off.noContacts)
        XCTAssertFalse(off.contacts)

        let on = try ContactResolutionOptions.parse(["--contacts"])
        XCTAssertTrue(on.contacts)
        XCTAssertFalse(on.noContacts)

        let none = try ContactResolutionOptions.parse([])
        XCTAssertFalse(none.noContacts)
        XCTAssertFalse(none.contacts)
    }
}
