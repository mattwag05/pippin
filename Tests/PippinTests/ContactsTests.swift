@testable import PippinLib
import XCTest

final class ContactsTests: XCTestCase {
    // MARK: - ContactInfo

    func testContactInfoRoundTrip() throws {
        let contact = ContactInfo(
            id: "contact-abc-123",
            fullName: "Alice Smith",
            givenName: "Alice",
            familyName: "Smith",
            emails: [
                LabeledValue(label: "work", value: "alice@example.com"),
                LabeledValue(label: "home", value: "alice@personal.com"),
            ],
            phones: [
                LabeledValue(label: "mobile", value: "+1 555-123-4567"),
            ],
            organization: "Acme Corp",
            jobTitle: "Engineer",
            birthday: "1990-06-15",
            postalAddresses: [
                PostalAddress(
                    label: "home",
                    street: "123 Main St",
                    city: "Springfield",
                    state: "IL",
                    postalCode: "62701",
                    country: "US"
                ),
            ],
            socialProfiles: [
                SocialProfile(service: "Twitter", username: "alice_smith", urlString: "https://twitter.com/alice_smith"),
            ]
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(ContactInfo.self, from: data)

        XCTAssertEqual(decoded.id, "contact-abc-123")
        XCTAssertEqual(decoded.fullName, "Alice Smith")
        XCTAssertEqual(decoded.givenName, "Alice")
        XCTAssertEqual(decoded.familyName, "Smith")
        XCTAssertEqual(decoded.emails.count, 2)
        XCTAssertEqual(decoded.emails[0].label, "work")
        XCTAssertEqual(decoded.emails[0].value, "alice@example.com")
        XCTAssertEqual(decoded.phones.count, 1)
        XCTAssertEqual(decoded.phones[0].value, "+1 555-123-4567")
        XCTAssertEqual(decoded.organization, "Acme Corp")
        XCTAssertEqual(decoded.jobTitle, "Engineer")
        XCTAssertEqual(decoded.birthday, "1990-06-15")
        XCTAssertEqual(decoded.postalAddresses.count, 1)
        XCTAssertEqual(decoded.postalAddresses[0].city, "Springfield")
        XCTAssertEqual(decoded.socialProfiles.count, 1)
        XCTAssertEqual(decoded.socialProfiles[0].service, "Twitter")
        XCTAssertEqual(decoded.socialProfiles[0].username, "alice_smith")
    }

    func testContactInfoWithEmptyArrays() throws {
        let contact = ContactInfo(
            id: "empty-arrays-contact",
            fullName: "Bob Jones",
            givenName: "Bob",
            familyName: "Jones",
            emails: [],
            phones: []
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(ContactInfo.self, from: data)

        XCTAssertEqual(decoded.id, "empty-arrays-contact")
        XCTAssertEqual(decoded.fullName, "Bob Jones")
        XCTAssertTrue(decoded.emails.isEmpty)
        XCTAssertTrue(decoded.phones.isEmpty)
        XCTAssertNil(decoded.organization)
        XCTAssertNil(decoded.jobTitle)
        XCTAssertNil(decoded.birthday)
        XCTAssertTrue(decoded.postalAddresses.isEmpty)
        XCTAssertTrue(decoded.socialProfiles.isEmpty)
    }

    func testContactInfoOptionalFieldsNil() throws {
        let contact = ContactInfo(
            id: "minimal",
            fullName: "Carol White",
            givenName: "Carol",
            familyName: "White",
            emails: [LabeledValue(label: nil, value: "carol@test.com")],
            phones: []
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(ContactInfo.self, from: data)
        XCTAssertNil(decoded.organization)
        XCTAssertNil(decoded.jobTitle)
        XCTAssertNil(decoded.birthday)
    }

    func testContactInfoBirthdayWithoutYear() throws {
        let contact = ContactInfo(
            id: "no-year-birthday",
            fullName: "Dan Green",
            givenName: "Dan",
            familyName: "Green",
            emails: [],
            phones: [],
            birthday: "--03-14"
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(ContactInfo.self, from: data)
        XCTAssertEqual(decoded.birthday, "--03-14")
    }

    // MARK: - LabeledValue

    func testLabeledValueRoundTrip() throws {
        let lv = LabeledValue(label: "work", value: "user@work.com")
        let data = try JSONEncoder().encode(lv)
        let decoded = try JSONDecoder().decode(LabeledValue.self, from: data)
        XCTAssertEqual(decoded.label, "work")
        XCTAssertEqual(decoded.value, "user@work.com")
    }

    func testLabeledValueNilLabel() throws {
        let lv = LabeledValue(label: nil, value: "555-0000")
        let data = try JSONEncoder().encode(lv)
        let decoded = try JSONDecoder().decode(LabeledValue.self, from: data)
        XCTAssertNil(decoded.label)
        XCTAssertEqual(decoded.value, "555-0000")
    }

    func testLabeledValueSendable() {
        let lv = LabeledValue(label: "home", value: "test@test.com")
        let _: any Sendable = lv
    }

    // MARK: - PostalAddress

    func testPostalAddressRoundTrip() throws {
        let addr = PostalAddress(
            label: "home",
            street: "456 Oak Ave",
            city: "Portland",
            state: "OR",
            postalCode: "97201",
            country: "United States"
        )
        let data = try JSONEncoder().encode(addr)
        let decoded = try JSONDecoder().decode(PostalAddress.self, from: data)
        XCTAssertEqual(decoded.label, "home")
        XCTAssertEqual(decoded.street, "456 Oak Ave")
        XCTAssertEqual(decoded.city, "Portland")
        XCTAssertEqual(decoded.state, "OR")
        XCTAssertEqual(decoded.postalCode, "97201")
        XCTAssertEqual(decoded.country, "United States")
    }

    func testPostalAddressNilLabel() throws {
        let addr = PostalAddress(
            label: nil,
            street: "789 Pine St",
            city: "Seattle",
            state: "WA",
            postalCode: "98101",
            country: "US"
        )
        let data = try JSONEncoder().encode(addr)
        let decoded = try JSONDecoder().decode(PostalAddress.self, from: data)
        XCTAssertNil(decoded.label)
        XCTAssertEqual(decoded.city, "Seattle")
    }

    func testPostalAddressSendable() {
        let addr = PostalAddress(label: nil, street: "", city: "", state: "", postalCode: "", country: "")
        let _: any Sendable = addr
    }

    // MARK: - SocialProfile

    func testSocialProfileRoundTrip() throws {
        let profile = SocialProfile(
            service: "LinkedIn",
            username: "john-doe",
            urlString: "https://linkedin.com/in/john-doe"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SocialProfile.self, from: data)
        XCTAssertEqual(decoded.service, "LinkedIn")
        XCTAssertEqual(decoded.username, "john-doe")
        XCTAssertEqual(decoded.urlString, "https://linkedin.com/in/john-doe")
    }

    func testSocialProfileNilURL() throws {
        let profile = SocialProfile(service: "Twitter", username: "jsmith")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SocialProfile.self, from: data)
        XCTAssertEqual(decoded.service, "Twitter")
        XCTAssertEqual(decoded.username, "jsmith")
        XCTAssertNil(decoded.urlString)
    }

    // MARK: - ContactGroup

    func testContactGroupRoundTrip() throws {
        let group = ContactGroup(id: "group-abc", name: "Work Colleagues", contactCount: 42)
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(ContactGroup.self, from: data)
        XCTAssertEqual(decoded.id, "group-abc")
        XCTAssertEqual(decoded.name, "Work Colleagues")
        XCTAssertEqual(decoded.contactCount, 42)
    }

    func testContactGroupZeroCount() throws {
        let group = ContactGroup(id: "empty-group", name: "Empty", contactCount: 0)
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(ContactGroup.self, from: data)
        XCTAssertEqual(decoded.contactCount, 0)
    }

    func testContactGroupSendable() {
        let group = ContactGroup(id: "x", name: "Test", contactCount: 0)
        let _: any Sendable = group
    }

    // MARK: - ContactsBridgeError

    func testContactsBridgeErrorDescriptions() throws {
        let errors: [ContactsBridgeError] = [
            .accessDenied,
            .contactNotFound("some-id-123"),
            .fetchFailed("network timeout"),
        ]
        for error in errors {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "errorDescription should not be nil for \(error)")
            XCTAssertFalse(try XCTUnwrap(desc?.isEmpty), "errorDescription should not be empty for \(error)")
        }
    }

    func testContactsBridgeErrorAccessDeniedDescription() {
        let error = ContactsBridgeError.accessDenied
        XCTAssertTrue(error.errorDescription?.contains("Contacts access denied") == true)
    }

    func testContactsBridgeErrorContactNotFoundDescription() {
        let id = "abc-123"
        let error = ContactsBridgeError.contactNotFound(id)
        XCTAssertTrue(error.errorDescription?.contains(id) == true)
    }

    func testContactsBridgeErrorFetchFailedDescription() {
        let msg = "some error message"
        let error = ContactsBridgeError.fetchFailed(msg)
        XCTAssertTrue(error.errorDescription?.contains(msg) == true)
    }
}
