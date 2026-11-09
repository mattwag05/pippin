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

    public struct ListContacts: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all contacts (name + primary email/phone)."
        )

        @Option(name: .long, help: "Filter by group name.")
        public var group: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // Contacts drives --fields server-side: fieldList selects which
            // CNContact keys are fetched (avoids reading email/phone bodies
            // across the whole store), unlike the client-side jsonData/emit
            // projection other commands use. Semantics intentionally differ.
            let fieldList = FieldProjection.parse(output.fields)
            let group = self.group
            // listContacts enumerates the full contact store (sync, can be slow
            // on large address books); hop off the cooperative pool.
            let outcome = try await detachBlocking {
                try ContactsBridge.listContacts(group: group, fields: fieldList)
            }
            return .emit(
                outcome.results,
                timedOut: outcome.timedOut,
                timedOutHint: ContactsCommand.timedOutHint
            )
        }
    }

    // MARK: - Search

    public struct SearchContacts: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search contacts by name, email, or phone."
        )

        @Argument(help: "Search query (name, or email with --email). Omit when using --phone.")
        public var query: String?

        @Flag(name: .long, help: "Search by email instead of name.")
        public var email: Bool = false

        @Option(name: .long, help: "Search by phone number (digits-only match; last 10 digits bridge a country-code difference).")
        public var phone: String?

        @Option(name: .long, help: "Maximum results to return; also the default page size when paginating (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var pagination: PaginationOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be positive.")
            }
            if phone != nil {
                guard query == nil, !email else {
                    throw ValidationError("--phone takes the number itself — don't combine it with a query or --email.")
                }
            } else if query == nil {
                throw ValidationError("Provide a search query, or --phone <number>.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let fieldList = FieldProjection.parse(output.fields)
            let query = self.query ?? ""
            let contacts: [ContactInfo]
            let timedOut: Bool
            if let phone {
                // searchByPhone enumerates the contact store (sync); hop off the pool.
                let outcome = try await detachBlocking { try ContactsBridge.searchByPhone(phone, fields: fieldList) }
                contacts = outcome.results
                timedOut = outcome.timedOut
            } else if email {
                // searchByEmail enumerates the contact store (sync); hop off the pool.
                let outcome = try await detachBlocking { try ContactsBridge.searchByEmail(query, fields: fieldList) }
                contacts = outcome.results
                timedOut = outcome.timedOut
            } else {
                // Name search uses CNContact.predicateForContacts — the
                // Contacts framework bounds it, so no client-side timeout
                // is needed; still hop off the pool (sync store fetch).
                contacts = try await detachBlocking { try ContactsBridge.searchByName(query, fields: fieldList) }
                timedOut = false
            }

            if pagination.isActive {
                let hash = Pagination.filterHash([
                    "query": query,
                    "email": email ? "1" : "0",
                    "phone": phone ?? "",
                ])
                let (offset, pageSize) = try Pagination.resolve(
                    pagination, defaultPageSize: limit, filterHash: hash
                )
                let page = try Pagination.paginate(
                    all: contacts, offset: offset, pageSize: pageSize, filterHash: hash
                )
                return .emitPage(page, timedOut: timedOut, timedOutHint: ContactsCommand.timedOutHint)
            }

            // Honor --limit in the non-paginated path too (matches calendar /
            // notes search). Previously the full result set was emitted and
            // --limit only took effect when paginating.
            let limited = Array(contacts.prefix(limit))
            return .emit(limited, timedOut: timedOut, timedOutHint: ContactsCommand.timedOutHint)
        }
    }

    // MARK: - Show

    public struct ShowContact: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show full contact details by identifier."
        )

        @Argument(help: "Contact identifier (from `pippin contacts list`).")
        public var identifier: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let contact = try ContactsBridge.getContact(identifier)
            return AgentResult(contact)
        }
    }

    // MARK: - Groups

    public struct ListGroups: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "groups",
            abstract: "List contact groups."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // listGroups reads the contact store (sync); hop off the pool.
            let groups = try await detachBlocking { try ContactsBridge.listGroups() }
            return AgentResult(groups)
        }
    }

    // MARK: - Create

    public struct CreateContact: AgentCommand {
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

        public mutating func execute() async throws -> AgentResult {
            guard (first != nil && !(first!.isEmpty)) || (last != nil && !(last!.isEmpty)) else {
                throw ValidationError("At least one of --first or --last is required.")
            }
            let first = self.first
            let last = self.last
            let email = self.email
            let phone = self.phone
            let organization = self.organization
            let jobTitle = self.jobTitle
            // createContact issues a synchronous CNSaveRequest; hop off the pool.
            let result = try await detachBlocking {
                try ContactsBridge.createContact(
                    givenName: first ?? "",
                    familyName: last ?? "",
                    email: email,
                    phone: phone,
                    organization: organization,
                    jobTitle: jobTitle
                )
            }
            return AgentResult(result)
        }
    }

    // MARK: - Edit

    public struct EditContact: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit an existing contact by identifier."
        )

        @Argument(help: "Contact identifier (from `pippin contacts show` or `list`).")
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

        public mutating func execute() async throws -> AgentResult {
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
            return AgentResult(result)
        }
    }

    // MARK: - Delete

    public struct DeleteContact: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a contact by identifier."
        )

        @Argument(help: "Contact identifier (from `pippin contacts show` or `list`).")
        public var identifier: String

        @Flag(name: .long, help: "Required: deletion cannot be undone.")
        public var force: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            // A stdin prompt would hang an agent, so refusal replaces it.
            guard force else {
                throw ValidationError("Deleting a contact cannot be undone. Pass --force to confirm.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let result = try ContactsBridge.deleteContact(identifier: identifier)
            return AgentResult(result)
        }
    }
}
