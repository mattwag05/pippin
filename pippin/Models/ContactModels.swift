import Foundation

public struct ContactInfo: Codable, Sendable {
    public let id: String
    public let fullName: String
    public let givenName: String
    public let familyName: String
    public let emails: [LabeledValue]
    public let phones: [LabeledValue]
    public let organization: String?
    public let jobTitle: String?
    public let birthday: String? // "YYYY-MM-DD" if year known, "--MM-DD" if year unknown
    public let postalAddresses: [PostalAddress]
    public let socialProfiles: [SocialProfile]

    public init(
        id: String,
        fullName: String,
        givenName: String,
        familyName: String,
        emails: [LabeledValue],
        phones: [LabeledValue],
        organization: String? = nil,
        jobTitle: String? = nil,
        birthday: String? = nil,
        postalAddresses: [PostalAddress] = [],
        socialProfiles: [SocialProfile] = []
    ) {
        self.id = id
        self.fullName = fullName
        self.givenName = givenName
        self.familyName = familyName
        self.emails = emails
        self.phones = phones
        self.organization = organization
        self.jobTitle = jobTitle
        self.birthday = birthday
        self.postalAddresses = postalAddresses
        self.socialProfiles = socialProfiles
    }
}

public struct LabeledValue: Codable, Sendable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

public struct PostalAddress: Codable, Sendable {
    public let label: String?
    public let street: String
    public let city: String
    public let state: String
    public let postalCode: String
    public let country: String

    public init(
        label: String?,
        street: String,
        city: String,
        state: String,
        postalCode: String,
        country: String
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
    }
}

public struct SocialProfile: Codable, Sendable {
    public let service: String
    public let username: String
    public let urlString: String?

    public init(service: String, username: String, urlString: String? = nil) {
        self.service = service
        self.username = username
        self.urlString = urlString
    }
}

public struct ContactGroup: Codable, Sendable {
    public let id: String
    public let name: String
    public let contactCount: Int

    public init(id: String, name: String, contactCount: Int) {
        self.id = id
        self.name = name
        self.contactCount = contactCount
    }
}

public enum ContactsBridgeError: LocalizedError, Sendable {
    case accessDenied
    case contactNotFound(String)
    case fetchFailed(String)
    case groupNotFound(String)
    case saveFailed(String)
    case deleteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return """
            Contacts access denied.
            → Run `pippin permissions` once in a terminal, or enable pippin under
              System Settings > Privacy & Security > Contacts. The grant belongs
              to pippin itself at its installed path (e.g. ~/.local/bin/pippin),
              not to the launching app, because pippin relaunches as its own
              responsible process; a background agent that can't show the prompt
              needs `pippin contacts list` run once in a terminal first. With
              PIPPIN_NO_DISCLAIM=1, or when that relaunch is unavailable, the
              grant attaches to the launching app (your terminal, or the MCP/agent
              client) instead. Then retry.
            """
        case let .contactNotFound(id):
            return "Contact not found: \(id)"
        case let .fetchFailed(msg):
            return "Failed to fetch contacts: \(msg)"
        case let .groupNotFound(name):
            return "Contact group not found: \(name)"
        case let .saveFailed(msg):
            return "Failed to save contact: \(msg)"
        case let .deleteFailed(msg):
            return "Failed to delete contact: \(msg)"
        }
    }
}

extension ContactsBridgeError: RemediableError {
    public var remediation: Remediation? {
        switch self {
        case .accessDenied:
            return .privacyAccess(
                permission: "Contacts",
                listCommand: "pippin contacts list",
                doctorCheck: "Contacts access"
            )
        default:
            return nil
        }
    }
}
