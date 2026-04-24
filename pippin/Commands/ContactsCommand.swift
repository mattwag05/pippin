import ArgumentParser
import Foundation

public struct ContactsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Interact with Apple Contacts.",
        subcommands: [
            ListContacts.self, SearchContacts.self, ShowContact.self, ListGroups.self,
            CreateContact.self, EditContact.self, DeleteContact.self,
        ]
    )

    /// Hint surfaced when a Contacts enumeration hits its 22s soft timeout.
    /// Mirrors `NotesCommand.timedOutHint`.
    static let timedOutHint = "Contacts scan exceeded soft timeout, returning partial results — narrow with --group (list) or use --email with a more specific query"

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
            let outcome = try ContactsBridge.listContacts(group: group, fields: fieldList)
            let contacts = outcome.results
            if output.isJSON {
                try output.emit(contacts, timedOut: outcome.timedOut, timedOutHint: ContactsCommand.timedOutHint) {}
            } else if output.isAgent {
                try output.emit(contacts, timedOut: outcome.timedOut, timedOutHint: ContactsCommand.timedOutHint) {}
            } else {
                try output.emit(contacts, timedOut: outcome.timedOut, timedOutHint: ContactsCommand.timedOutHint) {
                    if contacts.isEmpty {
                        print("No contacts found.")
                    } else {
                        for contact in contacts {
                            print(formatContactLine(contact))
                        }
                    }
                }
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

        @Option(name: .long, help: "Default page size when --page-size is omitted (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
        }

        public mutating func run() async throws {
            let fieldList = parseFields(fields)
            let contacts: [ContactInfo]
            let timedOut: Bool
            if email {
                let outcome = try ContactsBridge.searchByEmail(query, fields: fieldList)
                contacts = outcome.results
                timedOut = outcome.timedOut
            } else {
                // Name search uses CNContact.predicateForContacts — the
                // Contacts framework bounds it, so no client-side timeout
                // is needed.
                contacts = try ContactsBridge.searchByName(query, fields: fieldList)
                timedOut = false
            }

            if pagination.isActive {
                let hash = Pagination.filterHash([
                    "query": query,
                    "email": email ? "1" : "0",
                ])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                let page = try Pagination.paginate(
                    all: contacts, offset: offset, pageSize: pageSize, filterHash: hash
                )
                try output.emit(page, timedOut: timedOut, timedOutHint: ContactsCommand.timedOutHint) {
                    if page.items.isEmpty {
                        print("No contacts found.")
                    } else {
                        for contact in page.items {
                            print(formatContactLine(contact))
                        }
                    }
                    if let cursor = page.nextCursor {
                        print("(more — re-run with --cursor \(cursor))")
                    }
                }
                return
            }

            try output.emit(contacts, timedOut: timedOut, timedOutHint: ContactsCommand.timedOutHint) {
                if contacts.isEmpty {
                    print("No contacts found.")
                } else {
                    for contact in contacts {
                        print(formatContactLine(contact))
                    }
                }
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
            let contact = try ContactsBridge.getContact(identifier)
            if output.isJSON {
                try printJSON(contact)
            } else if output.isAgent {
                try output.printAgent(contact)
            } else {
                printContactCard(contact)
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
            let groups = try ContactsBridge.listGroups()
            if output.isJSON {
                try printJSON(groups)
            } else if output.isAgent {
                try output.printAgent(groups)
            } else {
                if groups.isEmpty {
                    print("No contact groups found.")
                    return
                }
                for group in groups {
                    print("\(group.name) (\(group.contactCount) contacts)")
                }
            }
        }
    }

    // MARK: - Create

    public struct CreateContact: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new contact."
        )

        @Option(name: .long, help: "Given (first) name.")
        public var first: String?

        @Option(name: .long, help: "Family (last) name.")
        public var last: String?

        @Option(name: .long, help: "Email address.")
        public var email: String?

        @Option(name: .long, help: "Phone number.")
        public var phone: String?

        @Option(name: .long, help: "Organization name.")
        public var organization: String?

        @Option(name: .long, help: "Job title.")
        public var jobTitle: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            guard (first != nil && !(first!.isEmpty)) || (last != nil && !(last!.isEmpty)) else {
                throw ValidationError("At least one of --first or --last is required.")
            }
            let result = try ContactsBridge.createContact(
                givenName: first ?? "",
                familyName: last ?? "",
                email: email,
                phone: phone,
                organization: organization,
                jobTitle: jobTitle
            )
            if output.isJSON || output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Edit

    public struct EditContact: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit an existing contact by identifier."
        )

        @Argument(help: "Contact identifier (from `pippin contacts show` or `list --format json`).")
        public var identifier: String

        @Option(name: .long, help: "New given (first) name.")
        public var first: String?

        @Option(name: .long, help: "New family (last) name.")
        public var last: String?

        @Option(name: .long, help: "New email address (replaces all existing emails).")
        public var email: String?

        @Option(name: .long, help: "New phone number (replaces all existing phones).")
        public var phone: String?

        @Option(name: .long, help: "New organization name.")
        public var organization: String?

        @Option(name: .long, help: "New job title.")
        public var jobTitle: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let hasChanges = [first, last, email, phone, organization, jobTitle].contains { $0 != nil }
            guard hasChanges else {
                throw ValidationError("At least one field to update is required.")
            }
            let result = try ContactsBridge.updateContact(
                identifier: identifier,
                givenName: first,
                familyName: last,
                email: email,
                phone: phone,
                organization: organization,
                jobTitle: jobTitle
            )
            if output.isJSON || output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Delete

    public struct DeleteContact: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a contact by identifier."
        )

        @Argument(help: "Contact identifier (from `pippin contacts show` or `list --format json`).")
        public var identifier: String

        @Flag(name: .long, help: "Skip confirmation prompt.")
        public var force: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            if !force {
                print("Delete contact \(identifier)? [y/N] ", terminator: "")
                let response = readLine() ?? ""
                guard response.lowercased() == "y" || response.lowercased() == "yes" else {
                    print("Aborted.")
                    return
                }
            }
            let result = try ContactsBridge.deleteContact(identifier: identifier)
            if output.isJSON || output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }
}

// MARK: - Shared helpers

private func parseFields(_ fields: String?) -> [String]? {
    guard let fields else { return nil }
    return fields.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Mask an email address to avoid logging it in cleartext while retaining some identifiability.
/// Examples:
///   "alice@example.com" -> "a***@e*****.com"
private func maskEmail(_ email: String) -> String {
    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        // Fallback: mask all but first and last character if not a standard email format.
        guard email.count > 2 else { return String(repeating: "*", count: email.count) }
        let first = email.first!
        let last = email.last!
        let maskedCount = email.count - 2
        return "\(first)\(String(repeating: "*", count: maskedCount))\(last)"
    }
    let localPart = String(parts[0])
    let domainPart = String(parts[1])

    // Mask local part: keep first character if available.
    let maskedLocal: String
    if localPart.count <= 1 {
        maskedLocal = String(repeating: "*", count: max(localPart.count, 1))
    } else {
        let first = localPart.first!
        maskedLocal = "\(first)\(String(repeating: "*", count: localPart.count - 1))"
    }

    // Split domain into name and TLD, mask most of the name.
    let domainComponents = domainPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard domainComponents.count == 2 else {
        // Non-standard domain, fully mask.
        return "\(maskedLocal)@\(String(repeating: "*", count: max(domainPart.count, 1)))"
    }
    let domainName = String(domainComponents[0])
    let tld = String(domainComponents[1])

    let maskedDomainName: String
    if domainName.count <= 1 {
        maskedDomainName = String(repeating: "*", count: max(domainName.count, 1))
    } else {
        let first = domainName.first!
        maskedDomainName = "\(first)\(String(repeating: "*", count: domainName.count - 1))"
    }

    return "\(maskedLocal)@\(maskedDomainName).\(tld)"
}

/// Mask a phone number to avoid logging it in cleartext, keeping only the last few digits.
/// Examples:
///   "+1 415 555 1234" -> "**********1234"
private func maskPhone(_ phone: String) -> String {
    // Remove whitespace to determine length, but preserve original non-space characters' count.
    let digitsOnly = phone.filter { !$0.isWhitespace }
    guard digitsOnly.count > 4 else {
        return String(repeating: "*", count: digitsOnly.count)
    }
    let visibleCount = 4
    let maskedCount = max(digitsOnly.count - visibleCount, 0)
    let visibleSuffix = digitsOnly.suffix(visibleCount)
    return String(repeating: "*", count: maskedCount) + String(visibleSuffix)
}

private func formatContactLine(_ contact: ContactInfo) -> String {
    let name = contact.fullName.isEmpty ? "(no name)" : contact.fullName
    let emailPart = contact.emails.first.map { " <\(maskEmail($0.value))>" } ?? ""
    let phonePart = contact.phones.first.map { "  \(maskPhone($0.value))" } ?? ""
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
