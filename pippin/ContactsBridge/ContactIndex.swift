import Contacts
import Foundation

/// An in-memory reverse index from a communication handle (phone number or email
/// address) to a contact's display name, so Messages/Mail output can tie a
/// sender to an Apple Contacts entry.
///
/// Built once per command — from `ContactIndexCache` when the address book is
/// unchanged, else from a single `CNContactStore` enumeration (handles in
/// one message/mail page typically number in the tens) — then queried O(1) per
/// handle. Phone numbers are normalized to digits because chat.db handles are
/// E.164-ish (`+15551234567`) while `CNPhoneNumber.stringValue` is free-form
/// (`(555) 123-4567`); matching on full-digits plus the last 10 bridges the
/// country-code difference without the false positives of shorter suffixes.
public struct ContactIndex: Sendable {
    private(set) var byPhone: [String: String] = [:]
    private(set) var byEmail: [String: String] = [:]

    public init() {}

    /// Rebuild from cached final maps (already post-first-write-wins, with
    /// normalized keys) — direct population, no re-normalization. Used by
    /// `ContactIndexCache` on a history-token hit.
    init(byPhone: [String: String], byEmail: [String: String]) {
        self.byPhone = byPhone
        self.byEmail = byEmail
    }

    /// `true` when nothing was indexed — callers can skip resolution entirely.
    public var isEmpty: Bool {
        byPhone.isEmpty && byEmail.isEmpty
    }

    /// Index one contact's handles under `name`. First write wins per key, so a
    /// later contact can't clobber an earlier exact match.
    public mutating func add(name: String, phones: [String], emails: [String]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for email in emails {
            let key = Self.normalizeEmail(email)
            if !key.isEmpty, byEmail[key] == nil { byEmail[key] = name }
        }
        for phone in phones {
            for key in Self.phoneKeys(phone) where byPhone[key] == nil {
                byPhone[key] = name
            }
        }
    }

    /// Resolve a handle (phone or email) to a contact display name, or nil.
    public func displayName(for handle: String) -> String? {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.contains("@") {
            let key = Self.normalizeEmail(handle)
            return key.isEmpty ? nil : byEmail[key]
        }
        let digits = handle.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        if let exact = byPhone[digits] { return exact }
        if digits.count > 10 { return byPhone[String(digits.suffix(10))] }
        return nil
    }

    // MARK: - Normalization (pure, testable)

    /// Lowercase, strip a `mailto:` prefix, and unwrap a `Name <addr>` header form
    /// down to the bare address.
    static func normalizeEmail(_ raw: String) -> String {
        var email = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if email.hasPrefix("mailto:") { email.removeFirst("mailto:".count) }
        if let open = email.firstIndex(of: "<"), let close = email.firstIndex(of: ">"), open < close {
            email = String(email[email.index(after: open) ..< close])
                .trimmingCharacters(in: .whitespaces)
        }
        return email
    }

    /// Digit-only keys for a phone number: the full digit string plus, when it has
    /// more than 10 digits, its last 10 (drops a leading country code).
    static func phoneKeys(_ raw: String) -> [String] {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return [] }
        var keys = [digits]
        if digits.count > 10 { keys.append(String(digits.suffix(10))) }
        return keys
    }
}

public extension ContactsBridge {
    /// Build a `ContactIndex` from one `CNContactStore` enumeration. **Best
    /// effort:** returns an empty index (never throws, never prompts) when
    /// Contacts isn't already authorized, so sender enrichment silently no-ops
    /// rather than blocking or failing a Messages/Mail command. Enumeration is
    /// synchronous/blocking — call inside `detachBlocking`. Bounded by the soft
    /// timeout so a huge address book can't blow the command's budget.
    ///
    /// Persisted via `ContactIndexCache`: when the store's history token matches
    /// the cached one, the index is rebuilt from disk with no enumeration. Any
    /// cache failure is a silent miss; only complete (non-timed-out, non-erroring)
    /// enumerations are written back.
    static func contactIndex(
        softTimeoutMs: Int = SoftTimeout.defaultMs,
        cache: ContactIndexCache? = ContactIndexCache.shared
    ) -> ContactIndex {
        guard authorizationStatus() == .authorized else { return ContactIndex() }
        let store = CNContactStore()
        let token = store.currentHistoryToken
        if let token, let cached = cache?.load(matching: token) {
            return cached
        }
        var index = ContactIndex()
        var timedOut = false
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let deadline = Date().addingTimeInterval(Double(SoftTimeout.clamp(softTimeoutMs)) / 1000.0)
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                if Date() >= deadline {
                    timedOut = true
                    stop.pointee = true
                    return
                }
                let name = CNContactFormatter.string(from: contact, style: .fullName)
                    ?? contact.organizationName
                index.add(
                    name: name,
                    phones: contact.phoneNumbers.map { $0.value.stringValue },
                    emails: contact.emailAddresses.map { $0.value as String }
                )
            }
        } catch {
            return index // possibly partial — return live results, never cache
        }
        persistIfComplete(index, timedOut: timedOut, token: token, to: cache)
        return index
    }

    /// Write a freshly-enumerated index back to the cache — unless it's partial
    /// (soft timeout hit) or there's no token to key it on, since caching a
    /// partial index would freeze incomplete data behind a current token.
    static func persistIfComplete(
        _ index: ContactIndex, timedOut: Bool, token: Data?, to cache: ContactIndexCache?
    ) {
        guard !timedOut, let token else { return }
        cache?.store(index, token: token)
    }
}
