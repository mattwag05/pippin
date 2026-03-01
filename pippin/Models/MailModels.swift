import Foundation

struct MailMessage: Codable {
    let id: String       // compound: "account||mailbox||messageId"
    let account: String
    let mailbox: String
    let subject: String
    let from: String
    let to: [String]
    let date: String     // ISO 8601
    let read: Bool
    let body: String?    // only populated by `read` command
}
