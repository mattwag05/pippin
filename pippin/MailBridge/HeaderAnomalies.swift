import Foundation

/// Stateless header-anomaly detection for messages fetched by `mail show`
/// (pippin-0pk). Flags structural red flags an agent skimming tool output would
/// otherwise never see: a Reply-To that redirects replies off the sender's
/// domain, hidden-recipient (Bcc) delivery, and explicit SPF/DKIM/DMARC
/// failures.
///
/// Design constraint (from the 2026-07-27 incident that motivated this):
/// dkim/spf/dmarc **pass is never treated as evidence of safety** — a
/// compromised account signs its phish with perfectly valid DKIM. Auth results
/// only ever ADD warnings (on failure); they never suppress one.
///
/// ponytail: stateless checks only — per-contact baselining (auth-fingerprint
/// deviation, Date-TZ drift) needs a history store and lives in a follow-on
/// bead.
enum HeaderAnomalies {
    /// Returns human/agent-readable warning strings, or nil when nothing is
    /// anomalous. `headers` is the Mail.app `allHeaders()` dict (folded,
    /// last-value-wins); lookups are case-insensitive.
    static func detect(from: String, to: [String], headers: [String: String]?) -> [String]? {
        guard let headers, !headers.isEmpty else { return nil }
        var lower: [String: String] = [:]
        for (k, v) in headers {
            lower[k.lowercased()] = v
        }

        var warnings: [String] = []

        // 1. Reply-To on a different domain than From: replies silently go
        //    somewhere other than the apparent sender.
        if let replyTo = lower["reply-to"],
           let replyDomain = emailDomain(in: replyTo),
           let fromDomain = emailDomain(in: from),
           replyDomain != fromDomain {
            warnings.append(
                "Reply-To is on a different domain than the sender (reply-to: \(replyDomain), from: \(fromDomain)) — replies will not go back to the apparent sender"
            )
        }

        // 2. Hidden recipients: "To: undisclosed-recipients:;" or an empty
        //    recipient list (message arrived via Bcc). Common in phishing
        //    blasts sent from a compromised account.
        let toHeader = lower["to"] ?? ""
        if toHeader.lowercased().contains("undisclosed")
            || to.contains(where: { $0.lowercased().contains("undisclosed") })
            || (to.isEmpty && toHeader.isEmpty) {
            warnings.append("Recipients are hidden (undisclosed-recipients / Bcc delivery)")
        }

        // 3. Explicit auth failures. Pass results are deliberately ignored —
        //    never a safety signal (see type doc).
        if let auth = lower["authentication-results"]?.lowercased() {
            for mech in ["spf", "dkim", "dmarc"] {
                if let verdict = ["softfail", "fail", "permerror"].first(where: { auth.contains("\(mech)=\($0)") }) {
                    warnings.append("Authentication failure: \(mech)=\(verdict)")
                }
            }
        }
        if let spf = lower["received-spf"]?.lowercased(),
           spf.hasPrefix("fail") || spf.hasPrefix("softfail"),
           !warnings.contains(where: { $0.contains("spf=") }) {
            warnings.append("Authentication failure: SPF \(spf.hasPrefix("softfail") ? "softfail" : "fail") (Received-SPF)")
        }

        return warnings.isEmpty ? nil : warnings
    }

    /// Lowercased full email address in a header value like
    /// `"Jane Doe" <jane@example.com>` or a bare `jane@example.com`.
    /// Baseline-store sender key (pippin-ml9).
    static func emailAddress(in value: String) -> String? {
        guard let domain = emailDomain(in: value), let at = value.lastIndex(of: "@") else { return nil }
        let local = String(value[..<at].reversed().prefix(while: { !"< ,;\"".contains($0) }).reversed())
        return local.isEmpty ? nil : "\(local)@\(domain)".lowercased()
    }

    /// Lowercased domain of the (first) email address in a header value like
    /// `"Jane Doe" <jane@example.com>` or a bare `jane@example.com`.
    static func emailDomain(in value: String) -> String? {
        guard let at = value.lastIndex(of: "@") else { return nil }
        let tail = value[value.index(after: at)...]
        let domain = tail.prefix(while: { !"> ,;".contains($0) })
        return domain.isEmpty ? nil : domain.lowercased()
    }
}
