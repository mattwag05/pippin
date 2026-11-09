import Foundation

extension MailBridge {
    /// JXA keeps sent and receipt timestamps separate. Receipt time drives
    /// operational sorting and filtering; sent time remains the message date.
    static func jsMailDates() -> String {
        """
        function usableMailDate(value) {
            if (value === null || value === undefined || !(value instanceof Date)) return null;
            var millis = value.getTime();
            return isFinite(millis) && millis > 0 ? value : null;
        }
        function mailDates(msg) {
            var sentDate = null;
            var receivedDate = null;
            try { sentDate = usableMailDate(msg.dateSent()); } catch(e) {}
            try { receivedDate = usableMailDate(msg.dateReceived()); } catch(e) {}
            var operationalDate = receivedDate || sentDate;
            return {sentDate: sentDate, receivedDate: receivedDate, operationalDate: operationalDate};
        }
        """
    }

    /// JXA declaring `bulkMailbox(mb)`: one Apple Event per property for a whole
    /// mailbox, about 0.05 ms per row against 67 ms per row one message at a time
    /// (docs/gotchas/jxa.md, pippin-25pr). Returns nil if the parallel arrays
    /// disagree or the mailbox changed mid-read, because a shifted array would
    /// pair one message's id with another's subject.
    ///
    /// `mailAttachments` and `whose()` stay out: both cost seconds in bulk.
    static func jsBulkMailbox() -> String {
        """
        function bulkMailbox(mb) {
            var spec = mb.messages;
            var b = {};
            try {
                b.ids = spec.id();
                b.received = spec.dateReceived();
                b.sent = spec.dateSent();
                b.read = spec.readStatus();
                b.subject = spec.subject();
                b.sender = spec.sender();
                b.size = spec.messageSize();
                var idsAfter = spec.id();
            } catch (e) { return null; }
            var n = b.ids.length;
            if (b.received.length !== n || b.sent.length !== n || b.read.length !== n
                || b.subject.length !== n || b.sender.length !== n || b.size.length !== n
                || idsAfter.length !== n) return null;
            for (var i = 0; i < n; i++) { if (b.ids[i] !== idsAfter[i]) return null; }
            return b;
        }
        function bulkDates(b, i) {
            var sentDate = usableMailDate(b.sent[i]);
            var receivedDate = usableMailDate(b.received[i]);
            return {sentDate: sentDate, receivedDate: receivedDate, operationalDate: receivedDate || sentDate};
        }
        // One materialization per mailbox, only when a row is actually needed:
        // `mb.messages[i]` is positional and cost about 650 ms a row on large mailboxes.
        function messageAt(mb, b, i) {
            try {
                if (!b.msgs) b.msgs = mb.messages();
                if (b.msgs.length !== b.ids.length) return null;
                var m = b.msgs[i];
                return m.id() === b.ids[i] ? m : null;
            } catch (e) { return null; }
        }
        function newestFirstThenRowId(x, y) {
            if (x.opIso < y.opIso) return 1;
            if (x.opIso > y.opIso) return -1;
            return x.rowId - y.rowId;
        }
        """
    }

    // MARK: - List Script

    static func buildListScript(
        account: String?,
        mailbox: String,
        unread: Bool,
        limit: Int,
        offset: Int = 0,
        preview: Int? = nil,
        after: String? = nil,
        before: String? = nil,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) -> String {
        let acctFilter = jsEscapeOptional(account)
        let mbName = jsEscape(mailbox)
        let afterFilter = jsEscapeOptional(after)
        let beforeFilter = jsEscapeOptional(before)
        // 0 means "preview disabled"; positive value is clamped chars for the preview.
        let previewChars = preview.map { max(0, min($0, 4000)) } ?? 0
        let safeSoftTimeoutMs = SoftTimeout.clamp(softTimeoutMs)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        \(jsFindMailboxByName())
        \(jsResolveMailbox())
        \(jsMailDates())
        \(jsBulkMailbox())
        var acctFilter = \(acctFilter);
        var mbFilter = '\(mbName)';
        var unreadOnly = \(unread ? "true" : "false");
        var limit = \(limit);
        var offset = \(offset);
        var previewChars = \(previewChars);
        var afterFilter = \(afterFilter);
        var beforeFilter = \(beforeFilter);
        var afterDate = afterFilter !== null ? new Date(afterFilter) : null;
        var beforeDate = beforeFilter !== null ? new Date(beforeFilter) : null;
        var softTimeoutMs = \(safeSoftTimeoutMs);
        // A bulk read examines the whole mailbox, so reachedMailboxEnd is always true
        // unless the scan was cut off (reported through timedOut).
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false, reachedMailboxEnd: true, oldestExaminedMs: null};
        // Soft timeout: return what we have before the ScriptRunner hard timeout
        // (and the MCP runChild 60s cap). The scan stops early enough to leave time
        // for the per-message reads of the rows that will be returned.
        var _listStart = Date.now();
        var _scanBudgetMs = Math.floor(softTimeoutMs * 0.8);

        var accounts = mail.accounts();
        var candidates = [];
        // An unreadable mailbox skips itself, and the answer is marked partial.
        var _unreadableMailbox = false;
        for (var a = 0; a < accounts.length && !_meta.timedOut; a++) {
            if (Date.now() - _listStart > _scanBudgetMs) { _meta.timedOut = true; break; }
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;
            _meta.accountsScanned++;

            var mb = resolveMailbox(acct, mbFilter);
            if (mb === null) continue;
            _meta.mailboxesScanned++;
            var resolvedMbName = mb.name();

            var b = bulkMailbox(mb);
            if (b === null) { _unreadableMailbox = true; continue; }

            // Pure JS from here: no Apple Events however large the mailbox is.
            for (var i = 0; i < b.ids.length; i++) {
                _meta.messagesExamined++;
                if (unreadOnly && b.read[i]) continue;
                var dates = bulkDates(b, i);
                var operationalDate = dates.operationalDate;
                if (operationalDate === null) continue;
                var opMs = operationalDate.getTime();
                if (_meta.oldestExaminedMs === null || opMs < _meta.oldestExaminedMs) _meta.oldestExaminedMs = opMs;
                if (afterDate !== null && operationalDate < afterDate) continue;
                if (beforeDate !== null && operationalDate > beforeDate) continue;
                candidates.push({
                    mb: mb, b: b, i: i, acct: acctName, mbName: resolvedMbName, dates: dates,
                    opIso: operationalDate.toISOString(), rowId: Number(b.ids[i])
                });
            }
        }

        if (_unreadableMailbox) _meta.timedOut = true;
        candidates.sort(newestFirstThenRowId);
        candidates = candidates.slice(offset, offset + limit);
        var results = [];
        for (var r = 0; r < candidates.length; r++) {
            var c = candidates[r];
            var row = {
                id: c.acct + '||' + c.mbName + '||' + c.b.ids[c.i],
                account: c.acct,
                mailbox: c.mbName,
                subject: c.b.subject[c.i] || '',
                from: c.b.sender[c.i] || '',
                to: [],
                date: (c.dates.sentDate || c.dates.operationalDate).toISOString(),
                receivedAt: c.dates.receivedDate === null ? null : c.dates.receivedDate.toISOString(),
                read: c.b.read[c.i],
                body: null,
                size: c.b.size[c.i],
                hasAttachment: null
            };
            // Per-message reads only for the rows being returned, while time remains.
            if (Date.now() - _listStart > softTimeoutMs) {
                _meta.timedOut = true;
            } else {
                row.__msg = messageAt(c.mb, c.b, c.i);
                if (row.__msg === null) {
                    // The mailbox changed under us: the bulk row is still right.
                    _meta.timedOut = true;
                } else {
                    try { row.hasAttachment = row.__msg.mailAttachments().length > 0; } catch (e) {}
                    if (previewChars > 0) {
                        try {
                            var raw = row.__msg.content();
                            if (raw != null && raw !== '') {
                                var s = String(raw);
                                row.bodyPreview = s.length > previewChars ? s.substring(0, previewChars) + '…' : s;
                            }
                        } catch (e) {}
                    }
                }
                delete row.__msg;
            }
            results.push(row);
        }

        JSON.stringify({results: results, meta: _meta});
        """
    }

    // MARK: - Accounts Script

    static func buildAccountsScript() -> String {
        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        var accounts = mail.accounts();
        var results = [];
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            var emails = [];
            try { emails = acct.emailAddresses(); } catch(e) {}
            var emailStr = (Array.isArray(emails) && emails.length > 0) ? emails[0] : '';
            var acctId = '';
            try { acctId = String(acct.id()); } catch(e) {}
            results.push({
                name: acct.name(),
                email: emailStr,
                id: acctId
            });
        }
        JSON.stringify(results);
        """
    }

    // MARK: - Mailboxes Script

    static func buildMailboxesScript(account: String?) -> String {
        let acctFilter = jsEscapeOptional(account)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        var acctFilter = \(acctFilter);
        var results = [];
        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;
            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                var msgCount = 0;
                var unreadCount = 0;
                try { msgCount = mb.messages().length; } catch(e) {}
                try { unreadCount = mb.unreadCount(); } catch(e) {}
                results.push({
                    name: mb.name(),
                    account: acctName,
                    messageCount: msgCount,
                    unreadCount: unreadCount
                });
            }
        }
        JSON.stringify(results);
        """
    }

    // MARK: - Search Script

    static func buildSearchScript(
        query: String,
        account: String?,
        mailbox: String? = nil,
        searchBody: Bool = false,
        limit: Int,
        offset: Int = 0,
        after: String? = nil,
        before: String? = nil,
        to: String? = nil,
        from: String? = nil,
        softTimeoutMs: Int = SoftTimeout.defaultMs,
        preview: Int? = nil
    ) -> String {
        let safeQuery = jsEscape(query)
        let acctFilter = jsEscapeOptional(account)
        let mbFilter = jsEscapeOptional(mailbox)
        let afterFilter = jsEscapeOptional(after)
        let beforeFilter = jsEscapeOptional(before)
        let toFilter = jsEscapeOptional(to)
        let fromFilter = jsEscapeOptional(from)
        // Clamp limit to prevent runaway scans; the per-mailbox cap bounds body fetches
        let safeLimitVal = max(1, min(limit, 500))
        let perMailboxLimit = 500
        let safeSoftTimeoutMs = SoftTimeout.clamp(softTimeoutMs)
        // Snippet length for body-matched hits (the body is already fetched for
        // the match test — capturing a preview costs nothing extra).
        let previewChars = max(1, min(preview ?? 200, 4000))

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20))
        \(jsFindMailboxByName())
        \(jsCollectAllMailboxes())
        \(jsResolveMailbox())
        \(jsMailDates())
        \(jsBulkMailbox())
        var query = '\(safeQuery)'.toLowerCase();
        var acctFilter = \(acctFilter);
        var mbFilter = \(mbFilter);
        var searchBody = \(searchBody ? "true" : "false");
        var limit = \(safeLimitVal);
        var offset = \(offset);
        var perMailboxLimit = \(perMailboxLimit);
        var softTimeoutMs = \(safeSoftTimeoutMs);
        var previewChars = \(previewChars);
        var afterFilter = \(afterFilter);
        var beforeFilter = \(beforeFilter);
        var toFilter = \(toFilter);
        var fromFilter = \(fromFilter);
        var afterDate = afterFilter !== null ? new Date(afterFilter) : null;
        var beforeDate = beforeFilter !== null ? new Date(beforeFilter) : null;
        var results = [];
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false};
        var seenMsgKeys = {};
        // Soft timeout: bail out of nested scan loops with whatever we've got so the
        // CLI returns partial results before the ScriptRunner hard timeout kicks in.
        var _searchStart = Date.now();
        var _scanBudgetMs = Math.floor(softTimeoutMs * 0.8);

        var accounts = mail.accounts();
        var candidates = [];
        // An unreadable mailbox skips itself, and the answer is marked partial.
        var _unreadableMailbox = false;
        for (var a = 0; a < accounts.length && !_meta.timedOut; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;
            _meta.accountsScanned++;

            var mbList;
            if (mbFilter !== null) {
                var resolvedMb = resolveMailbox(acct, mbFilter);
                mbList = resolvedMb !== null ? [resolvedMb] : [];
            } else {
                mbList = collectAllMailboxes(acct.mailboxes(), []);
            }
            for (var m = 0; m < mbList.length && !_meta.timedOut; m++) {
                if (Date.now() - _searchStart > _scanBudgetMs) { _meta.timedOut = true; break; }
                var mb = mbList[m];
                _meta.mailboxesScanned++;
                var mbName = mb.name();
                var b = bulkMailbox(mb);
                if (b === null) { _unreadableMailbox = true; continue; }

                // Subject and sender match over the whole mailbox with no Apple
                // Events, so old mail is reachable without Full Disk Access.
                var inRange = [];
                for (var i = 0; i < b.ids.length; i++) {
                    _meta.messagesExamined++;
                    var dates = bulkDates(b, i);
                    var operationalDate = dates.operationalDate;
                    if (operationalDate === null) continue;
                    if (afterDate !== null && operationalDate < afterDate) continue;
                    if (beforeDate !== null && operationalDate > beforeDate) continue;
                    var sender = b.sender[i] || '';
                    if (fromFilter !== null && sender.toLowerCase().indexOf(fromFilter.toLowerCase()) === -1) continue;
                    inRange.push({
                        mb: mb, b: b, i: i, acct: acctName, mbName: mbName, dates: dates,
                        opIso: operationalDate.toISOString(), rowId: Number(b.ids[i]), bodyPrev: null
                    });
                }
                // content() is per-message, so spend that budget on the newest mail.
                if (searchBody) inRange.sort(newestFirstThenRowId);
                var bodyFetches = 0;
                for (var j = 0; j < inRange.length; j++) {
                    var c = inRange[j];
                    var subject = (c.b.subject[c.i] || '');
                    var from = (c.b.sender[c.i] || '');
                    var matched = subject.toLowerCase().indexOf(query) !== -1
                               || from.toLowerCase().indexOf(query) !== -1;
                    if (!matched && searchBody && bodyFetches < perMailboxLimit) {
                        if (Date.now() - _searchStart > _scanBudgetMs) { _meta.timedOut = true; break; }
                        bodyFetches++;
                        var bodyMsg = messageAt(c.mb, c.b, c.i);
                        if (bodyMsg === null) { _unreadableMailbox = true; continue; }
                        var body = '';
                        try { body = String(bodyMsg.content() || ''); } catch (e) { _unreadableMailbox = true; continue; }
                        if (body.toLowerCase().indexOf(query) !== -1) {
                            matched = true;
                            c.bodyPrev = body.length > previewChars ? body.substring(0, previewChars) + '…' : body;
                        }
                    }
                    if (matched) candidates.push(c);
                }
            }
        }

        if (_unreadableMailbox) _meta.timedOut = true;
        candidates.sort(newestFirstThenRowId);
        // Per-message reads, newest first, only until the page is full.
        for (var k = 0; k < candidates.length && results.length < offset + limit; k++) {
            var c2 = candidates[k];
            var subject2 = c2.b.subject[c2.i] || '';
            var sender2 = c2.b.sender[c2.i] || '';
            var opDate = c2.dates.operationalDate;
            var msg = null;
            if (Date.now() - _searchStart > softTimeoutMs) {
                _meta.timedOut = true;
                // A recipient filter cannot be honored without reading recipients.
                if (toFilter !== null) break;
            } else {
                msg = messageAt(c2.mb, c2.b, c2.i);
                if (msg === null) {
                    // The mailbox changed under us: the bulk row is still right,
                    // but an unverifiable recipient filter must not pass it.
                    _meta.timedOut = true;
                    if (toFilter !== null) continue;
                }
            }
            var toAddrs = [];
            if (msg !== null) {
                try { toAddrs = msg.toRecipients().map(function(r) { return r.address(); }); } catch(e) {}
                if (toFilter !== null) {
                    var toLower = toFilter.toLowerCase();
                    if (!toAddrs.some(function(addr) { return addr.toLowerCase().indexOf(toLower) !== -1; })) continue;
                }
            }
            // Gmail lists the same message in both INBOX and [Gmail]/All Mail.
            var dedupKey = null;
            if (msg !== null) { try { dedupKey = msg.messageId(); } catch(e) {} }
            if (!dedupKey) dedupKey = subject2 + '\\x00' + sender2 + '\\x00' + opDate.toISOString();
            if (seenMsgKeys[dedupKey]) continue;
            seenMsgKeys[dedupKey] = true;
            var msgHasAtt = null;
            if (msg !== null) { try { msgHasAtt = msg.mailAttachments().length > 0; } catch(e) {} }
            results.push({
                id: c2.acct + '||' + c2.mbName + '||' + c2.b.ids[c2.i],
                account: c2.acct,
                mailbox: c2.mbName,
                subject: subject2,
                from: sender2,
                to: toAddrs,
                date: (c2.dates.sentDate || opDate).toISOString(),
                receivedAt: c2.dates.receivedDate === null ? null : c2.dates.receivedDate.toISOString(),
                read: c2.b.read[c2.i],
                body: null,
                bodyPreview: c2.bodyPrev,
                size: c2.b.size[c2.i],
                hasAttachment: msgHasAtt
            });
        }
        results = results.slice(offset, offset + limit);

        JSON.stringify({results: results, meta: _meta});
        """
    }

    // MARK: - Activity Script (combined multi-mailbox recent scan)

    static func buildActivityScript(
        account: String?,
        mailboxes: [String],
        since: Date?,
        limit: Int,
        preview: Int?,
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) -> String {
        let acctFilter = jsEscapeOptional(account)
        let mbNamesJS = jsStringArray(mailboxes)
        let sinceJS = since.map { "'\(formatEventDate($0))'" } ?? "null"
        let safeLimit = max(1, min(limit, 500))
        let previewChars = preview.map { max(0, min($0, 4000)) } ?? 0
        let safeSoftTimeoutMs = SoftTimeout.clamp(softTimeoutMs)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20))
        \(jsFindMailboxByName())
        \(jsCollectAllMailboxes())
        \(jsResolveMailbox())
        \(jsMailDates())
        \(jsBulkMailbox())
        var acctFilter = \(acctFilter);
        var targetNames = \(mbNamesJS);
        var sinceRaw = \(sinceJS);
        var sinceDate = sinceRaw !== null ? new Date(sinceRaw) : null;
        var limit = \(safeLimit);
        var previewChars = \(previewChars);
        var softTimeoutMs = \(safeSoftTimeoutMs);
        var results = [];
        var seenMsgKeys = {};
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false};
        // Soft timeout: bail out of nested scan loops AND the post-slice preview
        // loop so the CLI returns partial results before the ScriptRunner hard
        // timeout (and the MCP runChild 60s cap) kicks in.
        var _activityStart = Date.now();
        var _scanBudgetMs = Math.floor(softTimeoutMs * 0.8);

        var accounts = mail.accounts();
        var candidates = [];
        // An unreadable mailbox skips itself, and the answer is marked partial.
        var _unreadableMailbox = false;
        for (var a = 0; a < accounts.length && !_meta.timedOut; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;
            _meta.accountsScanned++;

            for (var t = 0; t < targetNames.length && !_meta.timedOut; t++) {
                if (Date.now() - _activityStart > _scanBudgetMs) { _meta.timedOut = true; break; }
                var targetName = targetNames[t];
                var mb = resolveMailbox(acct, targetName);
                if (mb === null) {
                    var all = collectAllMailboxes(acct.mailboxes(), []);
                    for (var k = 0; k < all.length; k++) {
                        if (all[k].name().toLowerCase() === targetName.toLowerCase()) { mb = all[k]; break; }
                    }
                    if (mb === null) continue;
                }
                _meta.mailboxesScanned++;
                var resolvedMbName = mb.name();
                var b = bulkMailbox(mb);
                if (b === null) { _unreadableMailbox = true; continue; }

                for (var i = 0; i < b.ids.length; i++) {
                    _meta.messagesExamined++;
                    var dates = bulkDates(b, i);
                    var operationalDate = dates.operationalDate;
                    if (operationalDate === null) continue;
                    if (sinceDate !== null && operationalDate < sinceDate) continue;
                    candidates.push({
                        mb: mb, b: b, i: i, acct: acctName, mbName: resolvedMbName, dates: dates,
                        opIso: operationalDate.toISOString(), rowId: Number(b.ids[i])
                    });
                }
            }
        }

        if (_unreadableMailbox) _meta.timedOut = true;
        candidates.sort(newestFirstThenRowId);
        // Per-message reads, newest first, only until the page is full.
        for (var q = 0; q < candidates.length && results.length < limit; q++) {
            var c = candidates[q];
            var subject = c.b.subject[c.i] || '';
            var sender = c.b.sender[c.i] || '';
            var opDate = c.dates.operationalDate;
            var msg = null;
            if (Date.now() - _activityStart > softTimeoutMs) {
                _meta.timedOut = true;
            } else {
                msg = messageAt(c.mb, c.b, c.i);
                if (msg === null) _meta.timedOut = true; // Mailbox changed; the bulk row is still right.
            }
            // INBOX and Sent can overlap on labeled accounts such as Gmail.
            var dedupKey = null;
            if (msg !== null) { try { dedupKey = msg.messageId(); } catch(e) {} }
            if (!dedupKey) dedupKey = subject + '\\x00' + sender + '\\x00' + opDate.toISOString();
            if (seenMsgKeys[dedupKey]) continue;
            seenMsgKeys[dedupKey] = true;
            var msgHasAtt = null;
            var toAddrs = [];
            if (msg !== null) {
                try { msgHasAtt = msg.mailAttachments().length > 0; } catch(e) {}
                try { toAddrs = msg.toRecipients().map(function(r) { return r.address(); }); } catch(e) {}
            }
            results.push({
                id: c.acct + '||' + c.mbName + '||' + c.b.ids[c.i],
                account: c.acct,
                mailbox: c.mbName,
                subject: subject,
                from: sender,
                to: toAddrs,
                date: (c.dates.sentDate || opDate).toISOString(),
                receivedAt: c.dates.receivedDate === null ? null : c.dates.receivedDate.toISOString(),
                read: c.b.read[c.i],
                body: null,
                size: c.b.size[c.i],
                hasAttachment: msgHasAtt,
                __msg: msg
            });
        }

        // Preview fetch runs last so msg.content() only fires for returned rows,
        // and is time-checked so a slow IMAP fetch can't blow the budget.
        if (previewChars > 0) {
            for (var p = 0; p < results.length && !_meta.timedOut; p++) {
                if (Date.now() - _activityStart > softTimeoutMs) { _meta.timedOut = true; break; }
                if (results[p].__msg === null) continue;
                try {
                    var raw = results[p].__msg.content();
                    if (raw != null && raw !== '') {
                        var s = String(raw);
                        results[p].bodyPreview = s.length > previewChars ? s.substring(0, previewChars) + '…' : s;
                    }
                } catch (e) {}
            }
        }
        for (var p2 = 0; p2 < results.length; p2++) { delete results[p2].__msg; }

        JSON.stringify({results: results, meta: _meta});
        """
    }

    // MARK: - Move Script

    static func buildMoveScript(
        account: String,
        mailbox: String,
        messageId: String,
        toMailbox: String,
        dryRun: Bool
    ) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        let safeTarget = jsEscape(toMailbox)
        let safeMsgId = jsEscape(messageId)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20, errorMessage: "MAILBRIDGE_ERR_NOT_READY"))
        \(jsFindMailboxByName())
        \(jsResolveMailbox())
        var isDryRun = \(dryRun ? "true" : "false");
        var sourceMsg = null;
        var targetMb = null;
        var fromName = '\(safeMailbox)';

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();

            // Find source message in the specified source mailbox
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() === '\(safeMailbox)') {
                    var msgs = mb.messages.whose({id: \(safeMsgId)})();
                    if (msgs.length === 0) throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND');
                    sourceMsg = msgs[0];
                    break;
                }
            }

            // Find target mailbox — resolves provider aliases (Trash, Sent, etc.) and nested folders
            targetMb = resolveMailbox(acct, '\(safeTarget)');
            break;
        }

        if (sourceMsg === null) { throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND'); }
        if (targetMb === null) { throw new Error('MAILBRIDGE_ERR_TARGET_NOT_FOUND'); }

        if (!isDryRun) {
            mail.move(sourceMsg, {to: targetMb});
        }

        JSON.stringify({
            success: true,
            action: 'move',
            details: {
                messageId: '\(safeAccount)||\(safeMailbox)||\(safeMsgId)',
                from: fromName,
                to: '\(safeTarget)',
                dryRun: String(isDryRun)
            }
        });
        """
    }

    // MARK: - Send Script

    static func buildSendScript(
        to: [String],
        subject: String,
        body: String,
        cc: [String] = [],
        bcc: [String] = [],
        from accountName: String? = nil,
        attachmentPaths: [String] = [],
        dryRun: Bool
    ) -> String {
        let safeTo = jsStringArray(to)
        let safeSubject = jsEscape(subject)
        let safeBody = jsEscape(body)
        let safeCc = jsStringArray(cc)
        let safeBcc = jsStringArray(bcc)
        let safeFrom = jsEscapeOptional(accountName)
        let safeAttachPaths = jsStringArray(attachmentPaths)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20, errorMessage: "MAILBRIDGE_ERR_NOT_READY"))
        var isDryRun = \(dryRun ? "true" : "false");

        var msg = mail.OutgoingMessage({
            subject: '\(safeSubject)',
            content: '\(safeBody)',
            visible: false
        });
        mail.outgoingMessages.push(msg);

        try {
            var toAddrs = \(safeTo);
            for (var ti = 0; ti < toAddrs.length; ti++) {
                msg.toRecipients.push(mail.Recipient({address: toAddrs[ti]}));
            }

            var ccAddrs = \(safeCc);
            for (var ci = 0; ci < ccAddrs.length; ci++) {
                msg.ccRecipients.push(mail.CcRecipient({address: ccAddrs[ci]}));
            }

            var bccAddrs = \(safeBcc);
            for (var bi = 0; bi < bccAddrs.length; bi++) {
                msg.bccRecipients.push(mail.BccRecipient({address: bccAddrs[bi]}));
            }

            var fromAcct = \(safeFrom);
            if (fromAcct !== null) {
                var acctFound = false;
                var accounts = mail.accounts();
                for (var a = 0; a < accounts.length; a++) {
                    if (accounts[a].name() === fromAcct) {
                        acctFound = true;
                        var emails = [];
                        try { emails = accounts[a].emailAddresses(); } catch(e) {}
                        if (Array.isArray(emails) && emails.length > 0) {
                            msg.sender = emails[0];
                        } else {
                            throw new Error('MAILBRIDGE_ERR_ACCT_NO_EMAIL');
                        }
                        break;
                    }
                }
                if (!acctFound) { throw new Error('MAILBRIDGE_ERR_ACCT_NOT_FOUND'); }
            }

            var attachPaths = \(safeAttachPaths);
            for (var ai = 0; ai < attachPaths.length; ai++) {
                var att = mail.Attachment({fileName: Path(attachPaths[ai])});
                msg.attachments.push(att);
            }
            // Verify all attachments were accepted
            if (attachPaths.length > 0 && msg.attachments().length !== attachPaths.length) {
                throw new Error('MAILBRIDGE_ERR_ATTACH_FAILED');
            }

            if (!isDryRun) {
                // msg.send() throws on SMTP rejection; success means accepted for delivery.
                msg.send();
            } else {
                // Dry-run: delete by object reference to avoid deleting wrong draft
                try { msg.delete(); } catch(e) {}
            }
        } catch(err) {
            // Cleanup: remove orphaned OutgoingMessage on any failure path
            try { msg.delete(); } catch(e) {}
            throw err;
        }

        JSON.stringify({
            success: true,
            action: 'send',
            details: {
                to: toAddrs.join(', '),
                subject: '\(safeSubject)',
                dryRun: String(isDryRun)
            }
        });
        """
    }

    // MARK: - Save Attachments Script

    static func buildSaveAttachmentsScript(
        account: String,
        mailbox: String,
        messageId: String,
        saveDir: String?
    ) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        let safeMsgId = messageId
        let safeSaveDir = jsEscapeOptional(saveDir)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        \(jsFindMailboxByName())
        \(jsCollectAllMailboxes())
        \(jsResolveMailbox())
        var saveDir = \(safeSaveDir);
        var result = [];

        // Gmail labels (e.g. "Important", "Starred") are not addressable as mailboxes in Mail.app
        // — a message whose compound id embeds a label returns -1728 from the label lookup, but
        // lives in INBOX or [Gmail]/All Mail. Scan all mailboxes by id as a fallback.
        function findMessageById(acct, mbHint, msgId) {
            var mb = resolveMailbox(acct, mbHint);
            if (mb !== null) {
                try {
                    var direct = mb.messages.whose({id: msgId})();
                    if (direct.length > 0) return direct[0];
                } catch(e) {}
            }
            var all = collectAllMailboxes(acct.mailboxes(), []);
            for (var i = 0; i < all.length; i++) {
                if (mb !== null && all[i] === mb) continue; // already tried
                try {
                    var found = all[i].messages.whose({id: msgId})();
                    if (found.length > 0) return found[0];
                } catch(e) {}
            }
            return null;
        }

        // 'save {to: Path(dest)}' errors -10000 ("Can't get POSIX file ...") unless the target
        // file already exists. Pre-create an empty file so AppleScript can resolve the path.
        var _sa = Application.currentApplication();
        _sa.includeStandardAdditions = true;
        function prepareSaveTarget(path) {
            var escaped = "'" + path.replace(/'/g, "'\\\\''") + "'";
            _sa.doShellScript('/usr/bin/touch ' + escaped);
        }

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var msg = findMessageById(acct, '\(safeMailbox)', \(safeMsgId));
            if (msg === null) throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND');

            // Reading .source() forces Mail to fetch the full RFC822 body from IMAP, which pulls
            // in attachment binaries. .content() only guarantees the text body — mail attachments
            // can stay as metadata stubs, causing 'save' to fail with -10000.
            try { msg.source(); } catch(e) {
                try { msg.content(); } catch(e2) {}
            }

            var atts = [];
            try { atts = msg.mailAttachments(); } catch(e) {}

            for (var i = 0; i < atts.length; i++) {
                var att = atts[i];
                var attName = 'attachment_' + i;
                try { attName = att.name(); } catch(e) {}
                // mimeType() raises "AppleEvent handler failed" (-10000) on some IMAP-backed
                // attachments (e.g. Gmail PDFs) even when the attachment is otherwise usable.
                var attMime = 'application/octet-stream';
                try { var m = att.mimeType(); if (m) attMime = m; } catch(e) {}
                var attSize = 0;
                try { attSize = att.fileSize(); } catch(e) {
                    try { attSize = att.downloadedSize(); } catch(e2) {}
                }
                var savedPath = null;
                if (saveDir !== null) {
                    var dest = saveDir + '/' + attName;
                    prepareSaveTarget(dest);
                    // AppleScript 'save a in POSIX file path' → JXA uses the preposition as the
                    // key: {in: Path(dest)}. {to: ...} errors 'Some data was the wrong type' (-10000).
                    att.save({in: Path(dest)});
                    savedPath = dest;
                }
                result.push({name: attName, mimeType: attMime, size: attSize, savedPath: savedPath});
            }
            break;
        }

        JSON.stringify(result);
        """
    }

    // MARK: - Mark Script

    static func buildMarkScript(
        account: String,
        mailbox: String,
        messageId: String,
        read: Bool,
        dryRun: Bool
    ) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        // messageId validated as numeric by caller; jsEscape is defense-in-depth
        let safeMsgId = jsEscape(messageId)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20, errorMessage: "MAILBRIDGE_ERR_NOT_READY"))
        var targetRead = \(read ? "true" : "false");
        var isDryRun = \(dryRun ? "true" : "false");
        var found = false;

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== '\(safeMailbox)') continue;

                var msgs = mb.messages.whose({id: \(safeMsgId)})();
                if (msgs.length === 0) throw new Error('MAILBRIDGE_ERR_MSG_NOT_FOUND');

                if (!isDryRun) {
                    msgs[0].readStatus = targetRead;
                    // Verify setter took effect (silent no-op on evicted/server-only messages)
                    if (msgs[0].readStatus() !== targetRead) {
                        throw new Error('MAILBRIDGE_ERR_SETTER_FAILED');
                    }
                }
                found = true;
                break;
            }
            if (found) break;
        }

        if (!found) { throw new Error('MAILBRIDGE_ERR_NOT_FOUND'); }

        JSON.stringify({
            success: true,
            action: 'mark',
            details: {
                messageId: '\(safeAccount)||\(safeMailbox)||\(safeMsgId)',
                readStatus: String(targetRead),
                dryRun: String(isDryRun)
            }
        });
        """
    }

    // MARK: - Read Script

    static func buildReadScript(account: String, mailbox: String, messageId: String) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        // messageId is pre-validated numeric by parseCompoundId — jsEscape is defense-in-depth
        let safeMsgId = messageId

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        \(jsMailDates())
        var result = null;

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== '\(safeMailbox)') continue;

                var msgs = mb.messages.whose({id: \(safeMsgId)})();
                if (msgs.length === 0) break;

                var msg = msgs[0];

                \(jsExtractMessageRow())
                result = __row;
                break;
            }
            if (result !== null) break;
        }

        if (result === null) { throw new Error('Message not found'); }
        JSON.stringify(result);
        """
    }

    /// Raw RFC822 source for one message (`mail verify` deep auth-chain parse,
    /// pippin-fwa). `msg.source()` forces the full body download from IMAP, but
    /// verify runs after `readMessage` already pulled `content()`, so the
    /// incremental cost is normally small. `source: null` (not an error) when
    /// Mail can't produce it — verify degrades to the flat-header report.
    static func buildSourceScript(account: String, mailbox: String, messageId: String) -> String {
        let safeAccount = jsEscape(account)
        let safeMailbox = jsEscape(mailbox)
        let safeMsgId = messageId

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        var result = null;

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length; a++) {
            var acct = accounts[a];
            if (acct.name() !== '\(safeAccount)') continue;

            var mailboxes = acct.mailboxes();
            for (var m = 0; m < mailboxes.length; m++) {
                var mb = mailboxes[m];
                if (mb.name() !== '\(safeMailbox)') continue;

                var msgs = mb.messages.whose({id: \(safeMsgId)})();
                if (msgs.length === 0) break;

                var src = null;
                try { src = msgs[0].source(); } catch(e) {}
                result = { source: src };
                break;
            }
            if (result !== null) break;
        }

        if (result === null) { throw new Error('Message not found'); }
        JSON.stringify(result);
        """
    }

    /// Group of miss compound ids sharing an account + mailbox, injected into
    /// `buildBatchBodiesScript` so each mailbox is resolved once (the efficiency
    /// win over N single-message `readMessage` spawns).
    struct BatchBodyGroup: Encodable {
        let account: String
        let mailbox: String
        let ids: [String]
    }

    /// Fetch full message rows (body + htmlBody + headers + attachments) for a
    /// specific set of compound ids in ONE osascript pass. Used by
    /// `listMessagesCached` (pass 3) to fill bodies for cache misses; the result
    /// rows decode as `MailMessage` and are written through `MailBodyCache` so a
    /// later `mail show` gets a first-class hit (not a body-only entry).
    ///
    /// Mirrors `buildReadScript`'s per-message extraction but:
    ///  - loops the explicit miss ids, grouped by (account, mailbox), resolving
    ///    each mailbox once,
    ///  - self-bounds with the documented soft-timeout idiom (see
    ///    docs/gotchas/jxa.md) — ids not reached before the cap are simply absent
    ///    from the result, treated by the assembler as "no preview",
    ///  - shares `buildReadScript`'s per-message extraction (`jsExtractMessageRow`,
    ///    including its `delay(0.5)` htmlContent retry) so a batch-warmed entry is
    ///    byte-for-byte as complete as a `mail show` fetch. The compounded delay
    ///    is bounded by `softTimeoutMs` — a large miss batch that overruns leaves
    ///    later ids for the next run.
    static func buildBatchBodiesScript(compoundIds: [String], softTimeoutMs: Int = SoftTimeout.defaultMs) -> String {
        // Group ids by (account, mailbox), preserving first-seen order, so each
        // mailbox is resolved once. Ids that don't parse are dropped (defense-in-
        // depth; callers pass ids straight from a prior enumeration).
        var order: [String] = []
        var idsByKey: [String: [String]] = [:]
        var metaByKey: [String: (account: String, mailbox: String)] = [:]
        for cid in compoundIds {
            guard let parsed = try? parseCompoundId(cid) else { continue }
            let key = parsed.account + "||" + parsed.mailbox
            if idsByKey[key] == nil {
                order.append(key)
                metaByKey[key] = (parsed.account, parsed.mailbox)
            }
            idsByKey[key, default: []].append(parsed.messageId)
        }
        let ordered = order.map { key in
            BatchBodyGroup(account: metaByKey[key]!.account, mailbox: metaByKey[key]!.mailbox, ids: idsByKey[key]!)
        }
        let groupsJSON = (try? String(decoding: JSONEncoder().encode(ordered), as: UTF8.self)) ?? "[]"
        let safeSoftTimeoutMs = SoftTimeout.clamp(softTimeoutMs)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 8))
        \(jsMailDates())
        var groups = \(groupsJSON);
        var softTimeoutMs = \(safeSoftTimeoutMs);
        var _start = Date.now();
        var results = [];
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false};

        var accounts = mail.accounts();
        for (var g = 0; g < groups.length && !_meta.timedOut; g++) {
            var grp = groups[g];
            var acct = null;
            for (var a = 0; a < accounts.length; a++) {
                if (accounts[a].name() === grp.account) { acct = accounts[a]; break; }
            }
            if (acct === null) continue;
            _meta.accountsScanned++;

            var mbs = acct.mailboxes();
            var mb = null;
            for (var m = 0; m < mbs.length; m++) {
                if (mbs[m].name() === grp.mailbox) { mb = mbs[m]; break; }
            }
            if (mb === null) continue;
            _meta.mailboxesScanned++;

            for (var i = 0; i < grp.ids.length; i++) {
                if (Date.now() - _start > softTimeoutMs) { _meta.timedOut = true; break; }
                _meta.messagesExamined++;
                var msgs = mb.messages.whose({id: grp.ids[i]})();
                if (msgs.length === 0) continue;
                var msg = msgs[0];

                \(jsExtractMessageRow())
                results.push(__row);
            }
        }

        JSON.stringify({results: results, meta: _meta});
        """
    }

    // MARK: - Reply / Forward Helpers

    static func buildReplyQuote(date: String, from: String, body: String) -> String {
        let quotedLines = body.components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "On \(date), \(from) wrote:\n\(quotedLines)"
    }

    static func buildForwardPrefix(from: String, date: String, subject: String, to: [String], body: String) -> String {
        let toLine = to.joined(separator: ", ")
        return """
        ---------- Forwarded message ----------
        From: \(from)
        Date: \(date)
        Subject: \(subject)
        To: \(toLine)

        \(body)
        """
    }

    static func buildReplySubject(_ subject: String) -> String {
        let stripped = subject.replacingOccurrences(of: #"^(Re:\s*)+"#, with: "", options: .regularExpression)
        return "Re: \(stripped)"
    }

    static func buildForwardSubject(_ subject: String) -> String {
        let stripped = subject.replacingOccurrences(of: #"^(Fwd?:\s*)+"#, with: "", options: .regularExpression)
        return "Fwd: \(stripped)"
    }
}
