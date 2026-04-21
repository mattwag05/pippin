import Contacts
import Foundation

public enum ContactsBridge {
    // MARK: - Authorization

    public static func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    // MARK: - List

    /// List all contacts, optionally filtered by group name.
    /// When `fields` is nil, returns minimal fields (id, fullName, primary email, primary phone).
    public static func listContacts(
        group: String? = nil,
        fields: [String]? = nil
    ) throws -> [ContactInfo] {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let keysToFetch = keysForFields(fields)

        if let groupName = group {
            let groups = try store.groups(matching: nil)
            guard let matchedGroup = groups.first(where: { $0.name == groupName }) else {
                throw ContactsBridgeError.groupNotFound(groupName)
            }
            let predicate = CNContact.predicateForContactsInGroup(
                withIdentifier: matchedGroup.identifier
            )
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return contacts.map { convert($0, fields: fields) }
        } else {
            var results: [ContactInfo] = []
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            try store.enumerateContacts(with: request) { contact, _ in
                results.append(convert(contact, fields: fields))
            }
            return results
        }
    }

    // MARK: - Search

    /// Search contacts by name substring.
    public static func searchByName(
        _ query: String,
        fields: [String]? = nil
    ) throws -> [ContactInfo] {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let keysToFetch = keysForFields(fields)
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        return contacts.map { convert($0, fields: fields) }
    }

    /// Search contacts by email substring or domain.
    public static func searchByEmail(
        _ query: String,
        fields: [String]? = nil
    ) throws -> [ContactInfo] {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        // CNContactStore has no built-in email predicate; enumerate and filter client-side.
        let keysToFetch = keysForFields(fields, forceEmails: true)
        let lowercasedQuery = query.lowercased()
        var results: [ContactInfo] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        try store.enumerateContacts(with: request) { contact, _ in
            let matches = contact.emailAddresses.contains { labeled in
                (labeled.value as String).lowercased().contains(lowercasedQuery)
            }
            if matches {
                results.append(convert(contact, fields: fields))
            }
        }
        return results
    }

    // MARK: - Get by identifier

    /// Fetch full contact details by CNContact identifier. Always returns all fields.
    public static func getContact(_ identifier: String) throws -> ContactInfo {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let keysToFetch = allKeys()
        do {
            let contact = try store.unifiedContact(
                withIdentifier: identifier, keysToFetch: keysToFetch
            )
            return convert(contact, fields: nil, fullDetail: true)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ContactsBridgeError.contactNotFound(identifier)
        } catch {
            throw ContactsBridgeError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Create

    /// Create a new contact. Returns a ContactActionResult with the new contact's identifier.
    public static func createContact(
        givenName: String,
        familyName: String,
        email: String? = nil,
        phone: String? = nil,
        organization: String? = nil,
        jobTitle: String? = nil
    ) throws -> ContactActionResult {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = familyName
        if let email {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString),
            ]
        }
        if let phone {
            contact.phoneNumbers = [
                CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone)),
            ]
        }
        if let organization {
            contact.organizationName = organization
        }
        if let jobTitle {
            contact.jobTitle = jobTitle
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw ContactsBridgeError.saveFailed(error.localizedDescription)
        }
        let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? "\(givenName) \(familyName)"
        return ContactActionResult(
            success: true,
            action: "create",
            details: ["id": contact.identifier, "fullName": fullName]
        )
    }

    // MARK: - Update

    /// Update fields on an existing contact by identifier. Only non-nil parameters are changed.
    public static func updateContact(
        identifier: String,
        givenName: String? = nil,
        familyName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        organization: String? = nil,
        jobTitle: String? = nil
    ) throws -> ContactActionResult {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
        ]
        let immutable: CNContact
        do {
            immutable = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ContactsBridgeError.contactNotFound(identifier)
        } catch {
            throw ContactsBridgeError.fetchFailed(error.localizedDescription)
        }

        let contact = immutable.mutableCopy() as! CNMutableContact
        if let givenName { contact.givenName = givenName }
        if let familyName { contact.familyName = familyName }
        if let email {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString),
            ]
        }
        if let phone {
            contact.phoneNumbers = [
                CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone)),
            ]
        }
        if let organization { contact.organizationName = organization }
        if let jobTitle { contact.jobTitle = jobTitle }

        let request = CNSaveRequest()
        request.update(contact)
        do {
            try store.execute(request)
        } catch {
            throw ContactsBridgeError.saveFailed(error.localizedDescription)
        }
        let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        return ContactActionResult(
            success: true,
            action: "update",
            details: ["id": identifier, "fullName": fullName]
        )
    }

    // MARK: - Delete

    /// Delete a contact by identifier.
    public static func deleteContact(identifier: String) throws -> ContactActionResult {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let immutable: CNContact
        do {
            immutable = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ContactsBridgeError.contactNotFound(identifier)
        } catch {
            throw ContactsBridgeError.fetchFailed(error.localizedDescription)
        }

        let fullName = CNContactFormatter.string(from: immutable, style: .fullName) ?? ""
        let contact = immutable.mutableCopy() as! CNMutableContact
        let request = CNSaveRequest()
        request.delete(contact)
        do {
            try store.execute(request)
        } catch {
            throw ContactsBridgeError.deleteFailed(error.localizedDescription)
        }
        return ContactActionResult(
            success: true,
            action: "delete",
            details: ["id": identifier, "fullName": fullName]
        )
    }

    // MARK: - Groups

    /// List all contact groups with contact counts.
    public static func listGroups() throws -> [ContactGroup] {
        let store = CNContactStore()
        try checkAuthorization(store: store)

        let groups = try store.groups(matching: nil)
        return try groups.map { group in
            let predicate = CNContact.predicateForContactsInGroup(
                withIdentifier: group.identifier
            )
            let contacts = try store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
            return ContactGroup(
                id: group.identifier,
                name: group.name,
                contactCount: contacts.count
            )
        }
    }

    // MARK: - Private helpers

    private static func checkAuthorization(store: CNContactStore) throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            // Attempt synchronous-style access; CNContactStore will throw if denied
            // (enumerateContacts / unifiedContacts will throw CNAuthorizationDenied).
            break
        case .denied, .restricted:
            throw ContactsBridgeError.accessDenied
        @unknown default:
            break
        }
        _ = store // suppress unused warning; store is the caller's instance
    }

    /// Keys needed for minimal field set (id, fullName, primary email, primary phone).
    private static func minimalKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
    }

    /// All keys for full detail fetch.
    private static func allKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
        ]
    }

    /// Map caller-supplied field names to the appropriate CNKeyDescriptors.
    /// Falls back to minimal keys when `fields` is nil.
    private static func keysForFields(_ fields: [String]?, forceEmails: Bool = false) -> [CNKeyDescriptor] {
        guard let fields else {
            if forceEmails {
                // Minimal + emails guaranteed for email search
                return minimalKeys()
            }
            return minimalKeys()
        }

        var keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let lowered = fields.map { $0.lowercased() }
        if lowered.contains("emails") || lowered.contains("email") || forceEmails {
            keys.append(CNContactEmailAddressesKey as CNKeyDescriptor)
        }
        if lowered.contains("phones") || lowered.contains("phone") {
            keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor)
        }
        if lowered.contains("organization") {
            keys.append(CNContactOrganizationNameKey as CNKeyDescriptor)
        }
        if lowered.contains("jobtitle") || lowered.contains("job_title") {
            keys.append(CNContactJobTitleKey as CNKeyDescriptor)
        }
        if lowered.contains("birthday") {
            keys.append(CNContactBirthdayKey as CNKeyDescriptor)
        }
        if lowered.contains("postaladdresses") || lowered.contains("postal_addresses") || lowered.contains("address") {
            keys.append(CNContactPostalAddressesKey as CNKeyDescriptor)
        }
        if lowered.contains("socialprofiles") || lowered.contains("social_profiles") || lowered.contains("social") {
            keys.append(CNContactSocialProfilesKey as CNKeyDescriptor)
        }
        return keys
    }

    /// Convert a CNContact to ContactInfo.
    /// - `fields`: nil means minimal (id, fullName, primary email/phone).
    /// - `fullDetail`: true means all fields (used by getContact).
    private static func convert(
        _ contact: CNContact,
        fields: [String]?,
        fullDetail: Bool = false
    ) -> ContactInfo {
        let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""

        // Determine which fields to populate
        let lowered = fields?.map { $0.lowercased() }
        let hasExplicitFields = lowered != nil

        func include(_ name: String) -> Bool {
            fullDetail || (hasExplicitFields && (lowered!.contains(name))) || false
        }

        let emails: [LabeledValue]
        if fullDetail || include("emails") || include("email") {
            emails = contact.emailAddresses.map { labeled in
                LabeledValue(
                    label: cleanLabel(labeled.label),
                    value: labeled.value as String
                )
            }
        } else if fields == nil {
            // Minimal: primary email only
            if let first = contact.emailAddresses.first {
                emails = [LabeledValue(label: cleanLabel(first.label), value: first.value as String)]
            } else {
                emails = []
            }
        } else {
            emails = []
        }

        let phones: [LabeledValue]
        if fullDetail || include("phones") || include("phone") {
            phones = contact.phoneNumbers.map { labeled in
                LabeledValue(
                    label: cleanLabel(labeled.label),
                    value: labeled.value.stringValue
                )
            }
        } else if fields == nil {
            // Minimal: primary phone only
            if let first = contact.phoneNumbers.first {
                phones = [LabeledValue(label: cleanLabel(first.label), value: first.value.stringValue)]
            } else {
                phones = []
            }
        } else {
            phones = []
        }

        let organization: String?
        if fullDetail || include("organization") {
            let org = contact.organizationName
            organization = org.isEmpty ? nil : org
        } else {
            organization = nil
        }

        let jobTitle: String?
        if fullDetail || include("jobtitle") || include("job_title") {
            let title = contact.jobTitle
            jobTitle = title.isEmpty ? nil : title
        } else {
            jobTitle = nil
        }

        let birthday: String?
        if fullDetail || include("birthday") {
            birthday = formatBirthday(contact.birthday)
        } else {
            birthday = nil
        }

        let postalAddresses: [PostalAddress]
        if fullDetail || include("postaladdresses") || include("postal_addresses") || include("address") {
            postalAddresses = contact.postalAddresses.map { labeled in
                let addr = labeled.value
                return PostalAddress(
                    label: cleanLabel(labeled.label),
                    street: addr.street,
                    city: addr.city,
                    state: addr.state,
                    postalCode: addr.postalCode,
                    country: addr.country
                )
            }
        } else {
            postalAddresses = []
        }

        let socialProfiles: [SocialProfile]
        if fullDetail || include("socialprofiles") || include("social_profiles") || include("social") {
            socialProfiles = contact.socialProfiles.map { labeled in
                let profile = labeled.value
                return SocialProfile(
                    service: profile.service,
                    username: profile.username,
                    urlString: profile.urlString.isEmpty ? nil : profile.urlString
                )
            }
        } else {
            socialProfiles = []
        }

        return ContactInfo(
            id: contact.identifier,
            fullName: fullName,
            givenName: contact.givenName,
            familyName: contact.familyName,
            emails: emails,
            phones: phones,
            organization: organization,
            jobTitle: jobTitle,
            birthday: birthday,
            postalAddresses: postalAddresses,
            socialProfiles: socialProfiles
        )
    }

    /// Clean a CNLabeledValue label string to a human-readable form.
    private static func cleanLabel(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }

    /// Format DateComponents birthday.
    private static func formatBirthday(_ components: DateComponents?) -> String? {
        guard let components, let month = components.month, let day = components.day else {
            return nil
        }
        let mm = String(format: "%02d", month)
        let dd = String(format: "%02d", day)
        if let year = components.year, year > 0 {
            return "\(year)-\(mm)-\(dd)"
        } else {
            return "--\(mm)-\(dd)"
        }
    }
}
