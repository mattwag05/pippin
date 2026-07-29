import Foundation
import GRDB

/// Per-sender header fingerprint + history store (pippin-ml9, phase 2 of
/// pippin-0pk). `HeaderAnomalies` covers absolute rules (explicit auth
/// failures, Reply-To mismatch); this measures deviation from the sender's
/// OWN history — the signal that caught the 2026-07-27 phish, which passed
/// every absolute check but diverged on Date TZ offset (-0500 vs the
/// contact's invariant -0400).
///
/// Same trust stance as phase 1: matching the baseline is never evidence of
/// safety (a compromised account matches its own baseline on most
/// dimensions); deviations only ever ADD warnings.
enum SenderFingerprint {
    /// Human-readable names for warning text and `mail verify` output.
    static let dimensionNames: [String: String] = [
        "dkim_domain": "DKIM signing domain",
        "dkim_selector": "DKIM selector",
        "msgid_domain": "Message-ID domain",
        "tz_offset": "Date TZ offset",
        "auth_spf": "SPF result",
        "auth_dkim": "DKIM result",
        "auth_dmarc": "DMARC result",
    ]

    /// Extract the fingerprint dimensions from a message's `allHeaders()` dict
    /// (folded, last-value-wins; lookups case-insensitive). A missing header
    /// records the literal value "absent" so presence↔absence transitions are
    /// deviations like any other (a sender whose mail always carries SPF
    /// suddenly arriving without it is exactly the signal we want).
    static func extract(headers: [String: String]) -> [String: String] {
        var lower: [String: String] = [:]
        for (k, v) in headers {
            lower[k.lowercased()] = v
        }

        var fp: [String: String] = [:]
        let dkim = lower["dkim-signature"] ?? ""
        fp["dkim_domain"] = tagValue("d", in: dkim) ?? "absent"
        fp["dkim_selector"] = tagValue("s", in: dkim) ?? "absent"
        fp["msgid_domain"] = lower["message-id"].flatMap(HeaderAnomalies.emailDomain(in:)) ?? "absent"
        fp["tz_offset"] = lower["date"].flatMap(tzOffset(in:)) ?? "absent"

        let auth = (lower["authentication-results"] ?? "").lowercased()
        for mech in ["spf", "dkim", "dmarc"] {
            fp["auth_\(mech)"] = authVerdict(mech, in: auth) ?? "absent"
        }
        return fp
    }

    /// Value of a `tag=value` pair in a DKIM-Signature header.
    private static func tagValue(_ tag: String, in header: String) -> String? {
        guard let range = header.range(of: "(^|[;\\s])\(tag)=", options: .regularExpression) else { return nil }
        let value = header[range.upperBound...].prefix(while: { !"; \t\r\n".contains($0) })
        return value.isEmpty ? nil : value.lowercased()
    }

    /// Numeric UTC offset (e.g. "-0400") from an RFC 5322 Date header.
    private static func tzOffset(in date: String) -> String? {
        guard let range = date.range(of: "[+-][0-9]{4}", options: .regularExpression) else { return nil }
        return String(date[range])
    }

    /// Verdict for one mechanism in an Authentication-Results header.
    private static func authVerdict(_ mech: String, in auth: String) -> String? {
        guard let range = auth.range(of: "\(mech)=([a-z]+)", options: .regularExpression) else { return nil }
        return String(auth[range].dropFirst(mech.count + 1))
    }
}

/// History store for sender fingerprints at ~/.config/pippin/mail-baseline.db.
/// One row per (message, dimension) so a message's own fingerprint can be
/// excluded from its baseline comparison — repeat views of a flagged message
/// keep flagging it.
final class SenderBaselineStore: Sendable {
    /// Process-wide default. `nil` if the store can't be opened — baseline
    /// checks then silently no-op (mail show must never fail on cache I/O).
    static let shared: SenderBaselineStore? = try? SenderBaselineStore()

    /// Minimum prior messages before an invariant dimension is trusted enough
    /// to flag deviations. ponytail: fixed constant; make configurable only if
    /// real-world noise demands it.
    static let minBaselineCount = 3

    static func defaultStorePath() -> String {
        "\(NSHomeDirectory())/.config/pippin/mail-baseline.db"
    }

    private let dbQueue: DatabaseQueue

    init(dbPath: String? = nil) throws {
        dbQueue = try openCacheQueue(path: dbPath ?? Self.defaultStorePath())
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS fingerprints (
                compound_id TEXT NOT NULL,
                sender TEXT NOT NULL,
                dimension TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (compound_id, dimension)
            );
            CREATE INDEX IF NOT EXISTS idx_fingerprints_sender ON fingerprints(sender, dimension);
            """)
        }
    }

    /// A dimension deviates when the sender's prior history is invariant (one
    /// value across >= minBaselineCount messages) and the current value differs.
    static func isDeviation(prior: [String: Int], current: String) -> Bool {
        guard prior.count == 1, let (value, count) = prior.first else { return false }
        return count >= minBaselineCount && value != current
    }

    /// Compare `fingerprint` against the sender's history (excluding this
    /// message's own prior recording), then record it. Returns warning strings;
    /// empty on any store error — never blocks the read path.
    func checkAndRecord(compoundId: String, sender: String, fingerprint: [String: String]) -> [String] {
        (try? dbQueue.write { db -> [String] in
            let warnings = try Self.deviationWarnings(
                db: db, compoundId: compoundId, sender: sender, fingerprint: fingerprint
            )
            for (dim, value) in fingerprint {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO fingerprints (compound_id, sender, dimension, value) VALUES (?, ?, ?, ?)",
                    arguments: [compoundId, sender, dim, value]
                )
            }
            return warnings
        }) ?? []
    }

    /// Compare-only variant (pippin-fwa): list/search/activity anomaly
    /// surfacing must never mutate the baseline store — only `mail show`/
    /// `verify` reads (full headers) record fingerprints.
    func check(compoundId: String, sender: String, fingerprint: [String: String]) -> [String] {
        (try? dbQueue.read { db in
            try Self.deviationWarnings(db: db, compoundId: compoundId, sender: sender, fingerprint: fingerprint)
        }) ?? []
    }

    private static func deviationWarnings(
        db: Database, compoundId: String, sender: String, fingerprint: [String: String]
    ) throws -> [String] {
        var warnings: [String] = []
        for (dim, current) in fingerprint.sorted(by: { $0.key < $1.key }) {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT value, COUNT(*) AS n FROM fingerprints WHERE sender = ? AND dimension = ? AND compound_id <> ? GROUP BY value",
                arguments: [sender, dim, compoundId]
            )
            var prior: [String: Int] = [:]
            for row in rows {
                prior[row["value"]] = row["n"]
            }
            if isDeviation(prior: prior, current: current), let (base, count) = prior.first {
                let name = SenderFingerprint.dimensionNames[dim] ?? dim
                warnings.append(
                    "Sender baseline deviation: \(name) is \(current) but all \(count) prior messages from \(sender) were \(base)"
                )
            }
        }
        return warnings
    }

    /// Full baseline for `mail verify` reporting: dimension -> value -> count,
    /// excluding the message under inspection.
    func baseline(sender: String, excluding compoundId: String) -> [String: [String: Int]] {
        (try? dbQueue.read { db -> [String: [String: Int]] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT dimension, value, COUNT(*) AS n FROM fingerprints WHERE sender = ? AND compound_id <> ? GROUP BY dimension, value",
                arguments: [sender, compoundId]
            )
            var result: [String: [String: Int]] = [:]
            for row in rows {
                result[row["dimension"], default: [:]][row["value"]] = row["n"]
            }
            return result
        }) ?? [:]
    }
}
