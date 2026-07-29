import Foundation

/// Full auth chain parsed from a message's raw RFC822 source (pippin-fwa).
/// The Mail.app `allHeaders()` dict is flat and last-value-wins, which destroys
/// header SETS — a message has one Received per hop, and forwarded mail carries
/// multiple Authentication-Results / a whole ARC set. `mail verify` fetches
/// `msg.source()` and parses the ordered headers to recover them.
public struct MailAuthChain: Codable, Sendable {
    /// Received headers, topmost (most recent hop) first.
    public let received: [String]
    /// Every Authentication-Results instance, topmost first.
    public let authenticationResults: [String]
    /// Every ARC-Authentication-Results instance (i=N ordering preserved as-is).
    public let arcAuthenticationResults: [String]
    /// ARC-Seal instances with signature data (b=) elided.
    public let arcSeals: [String]
    /// DKIM-Signature instances with signature data (b=/bh=) elided.
    public let dkimSignatures: [String]
}

/// RFC 5322 raw-header parsing for the `mail verify` deep auth-chain report.
enum RawHeaders {
    /// Ordered (name, value) pairs from raw message source. Values are unfolded
    /// (continuation lines joined with a single space) and trimmed. Parsing
    /// stops at the first empty line (the header/body boundary).
    static func parse(_ source: String) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        // "\r\n" is ONE grapheme cluster in Swift — splitting on the Character
        // "\n" never splits CRLF-terminated source. Normalize CRLF first.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                // Folded continuation of the previous header.
                guard !headers.isEmpty else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { headers[headers.count - 1].value += " " + trimmed }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            // RFC 5322 field names are printable US-ASCII minus colon (no spaces).
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0 > " " }) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name: name, value: value))
        }
        return headers
    }

    /// Collect the auth-chain header sets from ordered raw headers.
    static func authChain(_ headers: [(name: String, value: String)]) -> MailAuthChain {
        func all(_ name: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }
        return MailAuthChain(
            received: all("Received"),
            authenticationResults: all("Authentication-Results"),
            arcAuthenticationResults: all("ARC-Authentication-Results"),
            arcSeals: all("ARC-Seal").map(stripSignatureData),
            dkimSignatures: all("DKIM-Signature").map(stripSignatureData)
        )
    }

    /// Warnings only the full chain can surface: an explicit auth failure in ANY
    /// Authentication-Results / ARC-Authentication-Results instance (the flat
    /// dict only ever saw the last one), and a broken ARC chain (cv=fail).
    /// Auth-failure phrasing matches `HeaderAnomalies.detect` exactly so the
    /// caller can string-dedup against the flat-path warnings.
    static func deepWarnings(_ chain: MailAuthChain) -> [String] {
        var warnings: [String] = []
        for instance in chain.authenticationResults + chain.arcAuthenticationResults {
            let auth = instance.lowercased()
            for mech in ["spf", "dkim", "dmarc"] {
                for verdict in ["softfail", "fail", "permerror"] where auth.contains("\(mech)=\(verdict)") {
                    let warning = "Authentication failure: \(mech)=\(verdict)"
                    if !warnings.contains(warning) { warnings.append(warning) }
                }
            }
        }
        if chain.arcSeals.contains(where: { $0.lowercased().contains("cv=fail") }) {
            warnings.append("ARC chain validation failed (cv=fail) — an intermediary broke the authentication chain")
        }
        return warnings
    }

    /// Replace b=/bh= signature blobs with "…" so seals/signatures stay readable.
    static func stripSignatureData(_ header: String) -> String {
        header.replacingOccurrences(
            of: "(^|[;\\s])(b|bh)=[^;]*",
            with: "$1$2=…",
            options: .regularExpression
        )
    }
}
