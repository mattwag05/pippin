import ArgumentParser
import Foundation

public struct ContactsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Interact with Apple Contacts.",
        subcommands: [
            ListContacts.self, SearchContacts.self, ShowContact.self, ListGroups.self,
        ]
    )

    public init() {}

    // MARK: - List

    public struct ListContacts: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all contacts (name + primary email/phone)."
        )

        @Option(name: .long, help: "Filter by group name.")
        public var group: String?

        @Option(name: .long, help: "Comma-separated fields to include (e.g. id,fullName,emails).")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let fieldList = parseFields(fields)
            do {
                let contacts = try ContactsBridge.listContacts(group: group, fields: fieldList)
                if output.isJSON {
                    try printJSON(contacts)
                } else if output.isAgent {
                    try printAgentJSON(contacts)
                } else {
                    if contacts.isEmpty {
                        print("No contacts found.")
                        return
                    }
                    for contact in contacts {
                        print(formatContactLine(contact))
                    }
                }
            } catch let error as ContactsBridgeError {
                throw ContactsCommandError(message: error.errorDescription ?? "Contacts access denied.")
            }
        }
    }

    // MARK: - Search

    public struct SearchContacts: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search contacts by name or email."
        )

        @Argument(help: "Search query.")
        public var query: String

        @Flag(name: .long, help: "Search by email instead of name.")
        public var email: Bool = false

        @Option(name: .long, help: "Comma-separated fields to include (e.g. id,fullName,emails).")
        public var fields: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let fieldList = parseFields(fields)
            do {
                let contacts: [ContactInfo]
                if email {
                    contacts = try ContactsBridge.searchByEmail(query, fields: fieldList)
                } else {
                    contacts = try ContactsBridge.searchByName(query, fields: fieldList)
                }
                if output.isJSON {
                    try printJSON(contacts)
                } else if output.isAgent {
                    try printAgentJSON(contacts)
                } else {
                    if contacts.isEmpty {
                        print("No contacts found.")
                        return
                    }
                    for contact in contacts {
                        print(formatContactLine(contact))
                    }
                }
            } catch let error as ContactsBridgeError {
                throw ContactsCommandError(message: error.errorDescription ?? "Contacts access denied.")
            }
        }
    }

    // MARK: - Show

    public struct ShowContact: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full contact details by identifier."
        )

        @Argument(help: "Contact identifier (from `pippin contacts list --format json`).")
        public var identifier: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            do {
                let contact = try ContactsBridge.getContact(identifier)
                if output.isJSON {
                    try printJSON(contact)
                } else if output.isAgent {
                    try printAgentJSON(contact)
                } else {
                    printContactCard(contact)
                }
            } catch let error as ContactsBridgeError {
                switch error {
                case .accessDenied:
                    throw ContactsCommandError(message: error.errorDescription ?? "Contacts access denied.")
                case .contactNotFound:
                    throw ContactsCommandError(message: error.errorDescription ?? "Contact not found.")
                case .fetchFailed:
                    throw ContactsCommandError(message: error.errorDescription ?? "Failed to fetch contact.")
                }
            }
        }
    }

    // MARK: - Groups

    public struct ListGroups: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "groups",
            abstract: "List contact groups."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            do {
                let groups = try ContactsBridge.listGroups()
                if output.isJSON {
                    try printJSON(groups)
                } else if output.isAgent {
                    try printAgentJSON(groups)
                } else {
                    if groups.isEmpty {
                        print("No contact groups found.")
                        return
                    }
                    for group in groups {
                        print("\(group.name) (\(group.contactCount) contacts)")
                    }
                }
            } catch let error as ContactsBridgeError {
                throw ContactsCommandError(message: error.errorDescription ?? "Contacts access denied.")
            }
        }
    }
}

// MARK: - Shared helpers

private struct ContactsCommandError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

private func parseFields(_ fields: String?) -> [String]? {
    guard let fields else { return nil }
    return fields.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
}

private func formatContactLine(_ contact: ContactInfo) -> String {
    let name = contact.fullName.isEmpty ? "(no name)" : contact.fullName
    let emailPart = contact.emails.first.map { " <\($0.value)>" } ?? ""
    let phonePart = contact.phones.first.map { "  \($0.value)" } ?? ""
    return "\(name)\(emailPart)\(phonePart)"
}

private func printContactCard(_ contact: ContactInfo) {
    var cardFields: [(String, String)] = [
        ("ID", contact.id),
        ("Name", contact.fullName.isEmpty ? "(no name)" : contact.fullName),
    ]
    if !contact.givenName.isEmpty { cardFields.append(("Given Name", contact.givenName)) }
    if !contact.familyName.isEmpty { cardFields.append(("Family Name", contact.familyName)) }
    if let org = contact.organization { cardFields.append(("Organization", org)) }
    if let title = contact.jobTitle { cardFields.append(("Job Title", title)) }
    if let birthday = contact.birthday { cardFields.append(("Birthday", birthday)) }
    if !contact.emails.isEmpty {
        let emailStr: String = contact.emails.map { (lv: LabeledValue) -> String in
            let labelPart: String = lv.label.map { "[\($0)] " } ?? ""
            return labelPart + lv.value
        }.joined(separator: "\n")
        cardFields.append(("Emails", emailStr))
    }
    if !contact.phones.isEmpty {
        let phoneStr: String = contact.phones.map { (lv: LabeledValue) -> String in
            let labelPart: String = lv.label.map { "[\($0)] " } ?? ""
            return labelPart + lv.value
        }.joined(separator: "\n")
        cardFields.append(("Phones", phoneStr))
    }
    if !contact.postalAddresses.isEmpty {
        let addrStr: String = contact.postalAddresses.map { (addr: PostalAddress) -> String in
            let parts = [addr.street, addr.city, addr.state, addr.postalCode, addr.country]
                .filter { !$0.isEmpty }
            let labelPart: String = addr.label.map { "[\($0)] " } ?? ""
            return labelPart + parts.joined(separator: ", ")
        }.joined(separator: "\n")
        cardFields.append(("Addresses", addrStr))
    }
    if !contact.socialProfiles.isEmpty {
        let socialStr: String = contact.socialProfiles.map { (sp: SocialProfile) -> String in
            sp.service + ": " + sp.username
        }.joined(separator: "\n")
        cardFields.append(("Social", socialStr))
    }
    print(TextFormatter.card(fields: cardFields))
}
