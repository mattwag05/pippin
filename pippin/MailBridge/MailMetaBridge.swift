import Foundation

/// JXA and orchestration for `MailMetaStore`.
extension MailBridge {
    private static func jsLiteral(_ value: some Encodable) -> String {
        // JSON is valid JS, and encoding escapes any quote in a mailbox name.
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "null"
    }

    private static let jsMailboxLookup = """
    var _mailboxCache = {};
    function mailboxNamed(acct, name) {
        // Direct lookup first: enumerating every mailbox costs about a second.
        try { var direct = acct.mailboxes.byName(name); direct.name(); return direct; } catch (e) {}
        var acctName = acct.name();
        if (!_mailboxCache[acctName]) {
            var all = collectAllMailboxes(acct.mailboxes(), []);
            var byName = {};
            for (var i = 0; i < all.length; i++) {
                var n = all[i].name();
                if (byName[n] === undefined) byName[n] = all[i];
            }
            _mailboxCache[acctName] = byName;
        }
        return _mailboxCache[acctName][name] || null;
    }
    function accountNamed(name) {
        try { var acct = mail.accounts.byName(name); acct.name(); return acct; } catch (e) { return null; }
    }
    function iso(d) { var u = usableMailDate(d); return u === null ? null : u.toISOString(); }
    """

    private static var jsPrelude: String {
        """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20))
        \(jsCollectAllMailboxes())
        \(jsMailDates())
        \(jsBulkMailbox())
        \(jsMailboxLookup)
        """
    }

    static func buildMetaTargetsScript(account: String?) -> String {
        """
        \(jsPrelude)
        var acctFilter = \(jsLiteral(account));
        var out = [];
        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var name = accounts[a].name();
            if (acctFilter !== null && name !== acctFilter) continue;
            var seen = {};
            var all = collectAllMailboxes(accounts[a].mailboxes(), []);
            for (var m = 0; m < all.length; m++) {
                var mbName = all[m].name();
                if (seen[mbName]) continue;
                seen[mbName] = true;
                out.push({account: name, mailbox: mbName});
            }
        }
        JSON.stringify(out);
        """
    }

    static func buildMetaFillScript(_ key: MailboxKey) -> String {
        """
        \(jsPrelude)
        var key = \(jsLiteral(key));
        var acct = accountNamed(key.account);
        var mb = acct === null ? null : mailboxNamed(acct, key.mailbox);
        if (mb === null) throw new Error('MAILBRIDGE_ERR_NOT_FOUND');
        var b = bulkMailbox(mb);
        if (b === null) throw new Error('mailbox changed during read');
        var rfc = b.ids.length === 0 ? [] : mb.messages.messageId();
        if (rfc.length !== b.ids.length) throw new Error('mailbox changed during read');
        var rows = [];
        for (var i = 0; i < b.ids.length; i++) {
            rows.push({
                compound_id: key.account + '||' + key.mailbox + '||' + b.ids[i],
                account: key.account,
                mailbox: key.mailbox,
                row_id: String(b.ids[i]),
                date_sent: iso(b.sent[i]),
                date_received: iso(b.received[i]),
                subject: b.subject[i] || '',
                sender: b.sender[i] || '',
                size: b.size[i],
                has_attachment: null,
                rfc_message_id: rfc[i] || null
            });
        }
        JSON.stringify(rows);
        """
    }

    static func buildMetaVolatileScript(_ keys: [MailboxKey]) -> String {
        """
        \(jsPrelude)
        var keys = \(jsLiteral(keys));
        var out = [];
        for (var k = 0; k < keys.length; k++) {
            var acct = accountNamed(keys[k].account);
            var mb = acct === null ? null : mailboxNamed(acct, keys[k].mailbox);
            if (mb === null) continue;
            var spec = mb.messages;
            if (spec.length === 0) {
                out.push({account: keys[k].account, mailbox: keys[k].mailbox, ids: [], dates: [], read: []});
                continue;
            }
            var ids = spec.id(), received = spec.dateReceived(), sent = spec.dateSent(), read = spec.readStatus();
            var after = spec.id();
            var aligned = ids.length === received.length && ids.length === sent.length
                && ids.length === read.length && ids.length === after.length;
            for (var c = 0; aligned && c < ids.length; c++) { if (ids[c] !== after[c]) aligned = false; }
            if (!aligned) continue;
            var dates = [];
            for (var i = 0; i < ids.length; i++) { dates.push(iso(received[i]) || iso(sent[i])); }
            out.push({account: keys[k].account, mailbox: keys[k].mailbox, ids: ids.map(String), dates: dates, read: read});
        }
        JSON.stringify(out);
        """
    }

    static func buildMetaFactsScript(_ compoundIds: [String]) -> String {
        """
        \(jsPrelude)
        var wanted = \(jsLiteral(compoundIds));
        var out = {};
        var byMailbox = {};
        for (var w = 0; w < wanted.length; w++) {
            var parts = wanted[w].split('||');
            var group = parts[0] + '||' + parts[1];
            (byMailbox[group] = byMailbox[group] || {account: parts[0], mailbox: parts[1], ids: []}).ids.push(parts[2]);
        }
        for (var g in byMailbox) {
            var entry = byMailbox[g];
            var acct = accountNamed(entry.account);
            var mb = acct === null ? null : mailboxNamed(acct, entry.mailbox);
            if (mb === null) continue;
            var ids = mb.messages.id();
            var msgs = mb.messages();
            if (ids.length !== msgs.length) continue;
            var position = {};
            for (var i = 0; i < ids.length; i++) position[String(ids[i])] = i;
            for (var n = 0; n < entry.ids.length; n++) {
                var at = position[entry.ids[n]];
                if (at === undefined) continue;
                var m = msgs[at];
                if (String(m.id()) !== entry.ids[n]) continue;
                var fact = {hasAttachment: null, messageId: null, dateSent: null};
                try { fact.hasAttachment = m.mailAttachments().length > 0; } catch (e) {}
                try { fact.messageId = m.messageId() || null; } catch (e) {}
                try { fact.dateSent = iso(m.dateSent()); } catch (e) {}
                out[entry.account + '||' + entry.mailbox + '||' + entry.ids[n]] = fact;
            }
        }
        JSON.stringify(out);
        """
    }

    static func liveMetaFacts(_ compoundIds: [String]) throws -> [String: MailLiveFacts] {
        guard !compoundIds.isEmpty else { return [:] }
        let json = try runScript(buildMetaFactsScript(compoundIds), timeoutSeconds: mcpHardTimeout(30), idempotent: true)
        return try decode([String: MailLiveFacts].self, from: json)
    }

    private static func liveMailboxRows(_ key: MailboxKey) throws -> [MailMetaRow] {
        let json = try runScript(buildMetaFillScript(key), timeoutSeconds: mcpHardTimeout(45), idempotent: true)
        return try decode([MailMetaRow].self, from: json)
    }

    /// `PIPPIN_MAIL_STORE=0` turns the store off, as e2e parity checks need.
    static func metaReader(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> MailMetaReader? {
        guard env["PIPPIN_MAIL_STORE"] != "0", let store = MailMetaStore.shared else { return nil }
        return MailMetaReader(
            store: store,
            volatile: { keys in
                let json = try runScript(buildMetaVolatileScript(keys), timeoutSeconds: mcpHardTimeout(45), idempotent: true)
                return try decode([MailLiveMailbox].self, from: json)
            },
            refresh: { try liveMailboxRows($0) },
            pageFacts: { try liveMetaFacts($0) }
        )
    }

    /// Compare with `toISOString()` rows, whose text sorts chronologically.
    private static func isoBound(_ raw: String?) -> (ok: Bool, value: String?) {
        guard let raw else { return (true, nil) }
        guard let date = parseCalendarDate(raw) else { return (false, nil) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (true, formatter.string(from: date))
    }

    private static func inRange(_ row: MailMetaRow, after: String?, before: String?) -> Bool {
        guard let date = row.operationalDate else { return false }
        if let after, date < after { return false }
        if let before, date > before { return false }
        return true
    }

    static func listFromStore(
        account: String?, mailbox: String, unread: Bool, limit: Int, offset: Int,
        after: String?, before: String?
    ) -> [MailMessage]? {
        let lower = isoBound(after), upper = isoBound(before)
        guard lower.ok, upper.ok, let reader = metaReader(),
              let scope = try? reader.scope(account: account, mailbox: mailbox)
        else { return nil }
        return (try? reader.answer(scope: scope, limit: limit, offset: offset) { row, read in
            (!unread || !read) && inRange(row, after: lower.value, before: upper.value)
        }) ?? nil
    }

    static func searchFromStore(
        query: String, account: String?, mailbox: String?, limit: Int, offset: Int,
        after: String?, before: String?, from: String?
    ) -> [MailMessage]? {
        let lower = isoBound(after), upper = isoBound(before)
        guard lower.ok, upper.ok, let reader = metaReader(),
              let scope = try? reader.scope(account: account, mailbox: mailbox)
        else { return nil }
        let needle = query.lowercased()
        let fromNeedle = from?.lowercased()
        return (try? reader.answer(scope: scope, limit: limit, offset: offset) { row, _ in
            guard inRange(row, after: lower.value, before: upper.value) else { return false }
            let sender = row.sender.lowercased()
            if let fromNeedle, !sender.contains(fromNeedle) { return false }
            return row.subject.lowercased().contains(needle) || sender.contains(needle)
        }) ?? nil
    }

    struct MetaFillSummary: Codable, Sendable {
        let filled: Int
        let skipped: Int
        let failed: Int
        let messages: Int
    }

    /// Fill or refresh the store. One instance at a time; resumes by skipping
    /// mailboxes finished within `maxAge`.
    static func fillMetaStore(account: String?, maxAge: TimeInterval) throws -> MetaFillSummary {
        guard let store = MailMetaStore.shared else {
            throw MailBridgeError.scriptFailed("Could not open the mail metadata store.")
        }
        let lockPath = (MailMetaStore.defaultStorePath() as NSString).deletingLastPathComponent + "/mail-meta.lock"
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        defer { if lock >= 0 { close(lock) } }
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MailBridgeError.fillInProgress }

        let targets = try decode(
            [MailboxKey.Decoded].self,
            from: runScript(buildMetaTargetsScript(account: account), timeoutSeconds: 60, idempotent: true)
        ).map(\.key)
        let finished = try Set(store.scans().filter { $0.complete && Date().timeIntervalSince($0.updatedAt) < maxAge }.map(\.key))

        var filled = 0, skipped = 0, failed = 0, messages = 0
        for key in targets {
            if finished.contains(key) {
                skipped += 1
                continue
            }
            do {
                let rows = try liveMailboxRows(key)
                try store.replaceMailbox(key, rows: rows)
                filled += 1
                messages += rows.count
            } catch MailBridgeError.accessDenied {
                throw MailBridgeError.accessDenied
            } catch {
                try? store.markIncomplete(key)
                failed += 1
                // Goes to the job's stderr log; the summary only counts.
                fputs("mail cache fill: \(key.account)/\(key.mailbox): \(error)\n", stderr)
            }
        }
        return MetaFillSummary(filled: filled, skipped: skipped, failed: failed, messages: messages)
    }
}

extension MailboxKey {
    struct Decoded: Decodable {
        let account: String
        let mailbox: String
        var key: MailboxKey { MailboxKey(account: account, mailbox: mailbox) }
    }
}
