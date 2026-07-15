import Foundation

extension MailBridge {
    // MARK: - Scan Direction Probe

    /// JXA snippet declaring `var newestFirst` for a message collection.
    ///
    /// Whether `mailbox.messages()` is index-ordered oldest→newest or
    /// newest→oldest varies by account/provider (GitHub #23/#24 — Gmail All
    /// Mail returned 2018-era mail from a "newest N" window built on the wrong
    /// assumption). Instead of assuming, probe the direction with two cheap
    /// Apple Events (`dateSent()` on the first and last message) and let the
    /// caller derive its scan window/iteration order from the result.
    /// Falls back to `fallbackNewestFirst` (the script's historical
    /// assumption) on error or when the collection has fewer than 2 messages.
    static func jsProbeNewestFirst(collection: String, fallbackNewestFirst: Bool) -> String {
        """
        var newestFirst = \(fallbackNewestFirst ? "true" : "false");
        try {
            if (\(collection).length >= 2) {
                newestFirst = \(collection)[0].dateSent() >= \(collection)[\(collection).length - 1].dateSent();
            }
        } catch(e) {}
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
        var results = [];
        // reachedMailboxEnd / oldestExaminedMs drive the "scan window did not
        // reach --before" hint: the newest-N window can bottom out before
        // reaching an old --before cutoff, so an empty result is ambiguous
        // (no matches vs window too shallow) unless we know how far back we got.
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false, reachedMailboxEnd: true, oldestExaminedMs: null};
        // Soft timeout: bail out of the per-message body-fetch loop with whatever
        // we've got so the CLI returns partial results before the ScriptRunner
        // hard timeout (and the MCP runChild 60s cap) kicks in.
        var _listStart = Date.now();

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length && results.length < limit && !_meta.timedOut; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;
            _meta.accountsScanned++;

            var mb = resolveMailbox(acct, mbFilter);
            if (mb === null || results.length >= limit) continue;
            _meta.mailboxesScanned++;
            var resolvedMbName = mb.name();

            // whose({}) is invalid JXA — use messages() directly for all-messages case
            var msgs = unreadOnly ? mb.messages.whose({readStatus: false})() : mb.messages();
            if (!msgs) continue;
            var totalMsgs = msgs.length;
            \(jsProbeNewestFirst(collection: "msgs", fallbackNewestFirst: true))
            // offset/limit are positions in newest→oldest order, mapped onto the
            // collection by the probed direction (GitHub #24).
            var windowSize = Math.max(0, Math.min(limit, totalMsgs - offset));
            // Window truncated below the mailbox's remaining depth → we did not
            // scan back to its oldest message (feeds the --before shortfall hint).
            if (windowSize < totalMsgs - offset) _meta.reachedMailboxEnd = false;

            // Single-pass assembly: time-check fires per message so the
            // expensive msg.content() body fetch (when preview is on) can be
            // bounded. Preserves the metadata-then-body order so we never
            // discard partial work — if the soft cap fires mid-row, we keep
            // every row already pushed to results.
            for (var k = 0; k < windowSize && results.length < limit; k++) {
                if (Date.now() - _listStart > softTimeoutMs) { _meta.timedOut = true; break; }
                var msg = msgs[newestFirst ? offset + k : totalMsgs - 1 - offset - k];
                _meta.messagesExamined++;

                // Date range filter (cheap — no IMAP fetch)
                var msgDate = msg.dateSent();
                var _mms = msgDate.getTime();
                if (_meta.oldestExaminedMs === null || _mms < _meta.oldestExaminedMs) _meta.oldestExaminedMs = _mms;
                if (afterDate !== null && msgDate < afterDate) continue;
                if (beforeDate !== null && msgDate > beforeDate) continue;

                var msgSize = null;
                try { msgSize = msg.messageSize(); } catch(e) {}
                var msgHasAtt = false;
                try { msgHasAtt = msg.mailAttachments().length > 0; } catch(e) {}

                var row = {
                    id: acctName + '||' + resolvedMbName + '||' + msg.id(),
                    account: acctName,
                    mailbox: resolvedMbName,
                    subject: msg.subject(),
                    from: msg.sender(),
                    to: [],
                    date: msgDate.toISOString(),
                    read: msg.readStatus(),
                    body: null,
                    size: msgSize,
                    hasAttachment: msgHasAtt
                };
                // msg.content() triggers the IMAP body fetch per CLAUDE.md — only called when previewChars > 0.
                if (previewChars > 0) {
                    try {
                        var raw = msg.content();
                        if (raw != null && raw !== '') {
                            var s = String(raw);
                            row.bodyPreview = s.length > previewChars ? s.substring(0, previewChars) + '…' : s;
                        }
                    } catch (e) {}
                }
                results.push(row);
            }
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
        softTimeoutMs: Int = SoftTimeout.defaultMs
    ) -> String {
        let safeQuery = jsEscape(query)
        let acctFilter = jsEscapeOptional(account)
        let mbFilter = jsEscapeOptional(mailbox)
        let afterFilter = jsEscapeOptional(after)
        let beforeFilter = jsEscapeOptional(before)
        let toFilter = jsEscapeOptional(to)
        let fromFilter = jsEscapeOptional(from)
        // Clamp limit to prevent runaway scans; per-mailbox cap bounds scan time
        let safeLimitVal = max(1, min(limit, 500))
        let perMailboxLimit = 500
        let safeSoftTimeoutMs = SoftTimeout.clamp(softTimeoutMs)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20))
        \(jsFindMailboxByName())
        \(jsCollectAllMailboxes())
        \(jsResolveMailbox())
        var query = '\(safeQuery)'.toLowerCase();
        var acctFilter = \(acctFilter);
        var mbFilter = \(mbFilter);
        var searchBody = \(searchBody ? "true" : "false");
        var limit = \(safeLimitVal);
        var offset = \(offset);
        var perMailboxLimit = \(perMailboxLimit);
        var softTimeoutMs = \(safeSoftTimeoutMs);
        var afterFilter = \(afterFilter);
        var beforeFilter = \(beforeFilter);
        var toFilter = \(toFilter);
        var fromFilter = \(fromFilter);
        var afterDate = afterFilter !== null ? new Date(afterFilter) : null;
        var beforeDate = beforeFilter !== null ? new Date(beforeFilter) : null;
        var results = [];
        var skipped = 0;
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false, windowsShifted: 0};
        var seenMsgKeys = {};
        // Soft timeout: bail out of nested scan loops with whatever we've got so the
        // CLI returns partial results before the ScriptRunner hard timeout kicks in.
        var _searchStart = Date.now();

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length && results.length < limit && !_meta.timedOut; a++) {
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
            for (var m = 0; m < mbList.length && results.length < limit && !_meta.timedOut; m++) {
                if (Date.now() - _searchStart > softTimeoutMs) { _meta.timedOut = true; break; }
                var mb = mbList[m];
                _meta.mailboxesScanned++;
                // Cap messages scanned per mailbox. Probe the collection's index
                // order with two cheap dateSent() Apple Events so the window
                // always covers the NEWEST perMailboxLimit messages and walks
                // newest→oldest, regardless of underlying order (GitHub #23/#24).
                var allMsgs = mb.messages();
                if (!allMsgs) continue;
                var totalMsgs = allMsgs.length;
                \(jsProbeNewestFirst(collection: "allMsgs", fallbackNewestFirst: false))
                var scanCount = Math.min(totalMsgs, perMailboxLimit);
                var scanFrom = 0;
                if (beforeDate !== null && totalMsgs > 0) {
                    // --before set and the newest message is after it: binary-search
                    // dateSent() probes (one cheap Apple Event each, no content())
                    // to start the window near the date range instead of burning it
                    // on messages the date guard would skip anyway (#23).
                    try {
                        if (allMsgs[newestFirst ? 0 : totalMsgs - 1].dateSent() > beforeDate) {
                            var lo = 0, hi = totalMsgs - 1;
                            while (lo < hi) {
                                var mid = (lo + hi) >> 1;
                                var probeDate = allMsgs[newestFirst ? mid : totalMsgs - 1 - mid].dateSent();
                                if (probeDate > beforeDate) { lo = mid + 1; } else { hi = mid; }
                            }
                            scanFrom = lo;
                            _meta.windowsShifted++;
                        }
                    } catch(e) {}
                }

                // k is a newest→oldest position; map it onto the real index.
                for (var k = scanFrom; k < scanFrom + scanCount && k < totalMsgs && results.length < limit; k++) {
                    if (Date.now() - _searchStart > softTimeoutMs) { _meta.timedOut = true; break; }
                    var msg = allMsgs[newestFirst ? k : totalMsgs - 1 - k];
                    _meta.messagesExamined++;

                    // Date range filter (cheap — no IMAP fetch). The walk is
                    // newest→oldest, so the first message older than --after ends
                    // this mailbox's scan; messages newer than --before are skipped
                    // cheaply before any content() call.
                    var msgDate = msg.dateSent();
                    if (afterDate !== null && msgDate < afterDate) break;
                    if (beforeDate !== null && msgDate > beforeDate) continue;

                    var subject = msg.subject() || '';
                    var sender = msg.sender() || '';
                    if (fromFilter !== null && sender.toLowerCase().indexOf(fromFilter.toLowerCase()) === -1) continue;

                    // Check subject and sender first (fast, no body fetch needed)
                    var matched = subject.toLowerCase().indexOf(query) !== -1
                               || sender.toLowerCase().indexOf(query) !== -1;

                    // Only fetch body if explicitly requested and subject/sender didn't match
                    if (!matched && searchBody) {
                        var body = msg.content() || '';
                        matched = body.toLowerCase().indexOf(query) !== -1;
                    }

                    // Recipient filter: only fetch toRecipients() after text match (avoids overhead)
                    if (matched && toFilter !== null) {
                        var recipients = msg.toRecipients();
                        var toMatched = false;
                        for (var r = 0; r < recipients.length; r++) {
                            if (recipients[r].address().toLowerCase().indexOf(toFilter.toLowerCase()) !== -1) {
                                toMatched = true; break;
                            }
                        }
                        if (!toMatched) matched = false;
                    }

                    if (matched) {
                        // Gmail lists the same message in both INBOX and [Gmail]/All Mail.
                        var dedupKey = null;
                        try { dedupKey = msg.messageId(); } catch(e) {}
                        if (!dedupKey) dedupKey = subject + '\\x00' + sender + '\\x00' + msgDate.toISOString();
                        if (seenMsgKeys[dedupKey]) continue;
                        seenMsgKeys[dedupKey] = true;

                        if (skipped < offset) { skipped++; continue; }
                        var msgSize = null;
                        try { msgSize = msg.messageSize(); } catch(e) {}
                        var msgHasAtt = false;
                        try { msgHasAtt = msg.mailAttachments().length > 0; } catch(e) {}
                        var toAddrs = [];
                        try { toAddrs = msg.toRecipients().map(function(r) { return r.address(); }); } catch(e) {}
                        results.push({
                            id: acctName + '||' + mb.name() + '||' + msg.id(),
                            account: acctName,
                            mailbox: mb.name(),
                            subject: subject,
                            from: sender,
                            to: toAddrs,
                            date: msgDate.toISOString(),
                            read: msg.readStatus(),
                            body: null,
                            size: msgSize,
                            hasAttachment: msgHasAtt
                        });
                    }
                }
            }
        }

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
        let perMailboxLimit = 500
        let previewChars = preview.map { max(0, min($0, 4000)) } ?? 0
        let safeSoftTimeoutMs = SoftTimeout.clamp(softTimeoutMs)

        return """
        var mail = Application('Mail');
        \(jsMailReadyPoll(maxAttempts: 20))
        \(jsFindMailboxByName())
        \(jsCollectAllMailboxes())
        \(jsResolveMailbox())
        var acctFilter = \(acctFilter);
        var targetNames = \(mbNamesJS);
        var sinceRaw = \(sinceJS);
        var sinceDate = sinceRaw !== null ? new Date(sinceRaw) : null;
        var limit = \(safeLimit);
        var perMailboxLimit = \(perMailboxLimit);
        var previewChars = \(previewChars);
        var softTimeoutMs = \(safeSoftTimeoutMs);
        var results = [];
        var seenMsgKeys = {};
        var _meta = {accountsScanned: 0, mailboxesScanned: 0, messagesExamined: 0, timedOut: false};
        // Soft timeout: bail out of nested scan loops AND the post-slice preview
        // loop so the CLI returns partial results before the ScriptRunner hard
        // timeout (and the MCP runChild 60s cap) kicks in.
        var _activityStart = Date.now();

        var accounts = mail.accounts();
        for (var a = 0; a < accounts.length && !_meta.timedOut; a++) {
            var acct = accounts[a];
            var acctName = acct.name();
            if (acctFilter !== null && acctName !== acctFilter) continue;
            _meta.accountsScanned++;

            for (var t = 0; t < targetNames.length && !_meta.timedOut; t++) {
                if (Date.now() - _activityStart > softTimeoutMs) { _meta.timedOut = true; break; }
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

                // Probe the collection's index order with two cheap dateSent()
                // Apple Events so the window always covers the NEWEST
                // perMailboxLimit messages, regardless of underlying order
                // (GitHub #24 — the old last-N window grabbed the OLDEST 500
                // on accounts whose messages() is newest-first).
                var allMsgs = mb.messages();
                if (!allMsgs) continue;
                var totalMsgs = allMsgs.length;
                \(jsProbeNewestFirst(collection: "allMsgs", fallbackNewestFirst: false))
                var scanCount = Math.min(totalMsgs, perMailboxLimit);
                for (var k = 0; k < scanCount && !_meta.timedOut; k++) {
                    if (Date.now() - _activityStart > softTimeoutMs) { _meta.timedOut = true; break; }
                    var msg = allMsgs[newestFirst ? k : totalMsgs - 1 - k];
                    _meta.messagesExamined++;
                    var msgDate = msg.dateSent();
                    if (sinceDate !== null && msgDate < sinceDate) continue;

                    var subject = msg.subject() || '';
                    var sender = msg.sender() || '';

                    var dedupKey = null;
                    try { dedupKey = msg.messageId(); } catch(e) {}
                    if (!dedupKey) {
                        dedupKey = subject + '\\x00' + sender + '\\x00' + msgDate.toISOString();
                    }
                    if (seenMsgKeys[dedupKey]) continue;
                    seenMsgKeys[dedupKey] = true;

                    var msgSize = null;
                    try { msgSize = msg.messageSize(); } catch(e) {}
                    var msgHasAtt = false;
                    try { msgHasAtt = msg.mailAttachments().length > 0; } catch(e) {}
                    var toAddrs = [];
                    try { toAddrs = msg.toRecipients().map(function(r) { return r.address(); }); } catch(e) {}

                    var row = {
                        id: acctName + '||' + resolvedMbName + '||' + msg.id(),
                        account: acctName,
                        mailbox: resolvedMbName,
                        subject: subject,
                        from: sender,
                        to: toAddrs,
                        date: msgDate.toISOString(),
                        read: msg.readStatus(),
                        body: null,
                        size: msgSize,
                        hasAttachment: msgHasAtt,
                        __msg: msg
                    };
                    results.push(row);
                }
            }
        }

        // ISO 8601 lexicographic sort == chronological (descending).
        results.sort(function(a, b) {
            if (a.date < b.date) return 1;
            if (a.date > b.date) return -1;
            return 0;
        });
        if (results.length > limit) results = results.slice(0, limit);

        // Preview fetch runs AFTER slice so msg.content() only fires for survivors.
        // Time-check inside the loop so a slow IMAP fetch can't blow the budget.
        if (previewChars > 0) {
            for (var p = 0; p < results.length && !_meta.timedOut; p++) {
                if (Date.now() - _activityStart > softTimeoutMs) { _meta.timedOut = true; break; }
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
