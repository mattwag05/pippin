import Foundation

extension MailBridge {
    // MARK: - JS Escape Helpers

    static func jsStringArray(_ items: [String]) -> String {
        let escaped = items.map { "'\(jsEscape($0))'" }.joined(separator: ", ")
        return "[\(escaped)]"
    }

    // MARK: - JXA Snippet Generators

    static func jsMailReadyPoll(
        maxAttempts: Int,
        errorMessage: String = "Mail not ready: no accounts visible after startup"
    ) -> String {
        """
        var ready = false;
        for (var attempt = 0; attempt < \(maxAttempts); attempt++) {
            if (mail.accounts().length > 0) { ready = true; break; }
            delay(0.5);
        }
        if (!ready) { throw new Error('\(errorMessage)'); }
        """
    }

    static func jsFindMailboxByName() -> String {
        """
        function findMailboxByName(mailboxes, name) {
            for (var i = 0; i < mailboxes.length; i++) {
                if (mailboxes[i].name() === name) return mailboxes[i];
                try {
                    var sub = mailboxes[i].mailboxes();
                    var found = findMailboxByName(sub, name);
                    if (found !== null) return found;
                } catch(e) {}
            }
            return null;
        }
        """
    }

    /// Gmail IMAP nests message-bearing mailboxes (`[Gmail]/All Mail`, `[Gmail]/Sent Mail`) under
    /// a top-level `[Gmail]` container, so `acct.mailboxes()` alone misses them.
    static func jsCollectAllMailboxes() -> String {
        """
        function collectAllMailboxes(mailboxes, accum) {
            for (var i = 0; i < mailboxes.length; i++) {
                accum.push(mailboxes[i]);
                try {
                    var sub = mailboxes[i].mailboxes();
                    if (sub && sub.length > 0) collectAllMailboxes(sub, accum);
                } catch(e) {}
            }
            return accum;
        }
        """
    }

    /// Extract a full message row from a JXA `msg` handle (with `acct`/`mb` in
    /// scope) into a local `__row` object: triggers the IMAP body download via
    /// `content()`, then `htmlContent()` with a `delay(0.5)` retry, parses
    /// `allHeaders()`, walks attachments, and grabs `messageSize()`.
    ///
    /// Shared by `buildReadScript` (single message) and `buildBatchBodiesScript`
    /// (the `mail list --preview` cache-miss batch) so a cache-warmed entry is
    /// byte-for-byte identical to a `mail show` fetch — the cache-coherence
    /// invariant is enforced by construction, not by keeping two copies in sync.
    /// The `delay(0.5)` html retry is load-bearing: HTML mail returns null
    /// htmlBody on the first attempt right after `content()`.
    static func jsExtractMessageRow() -> String {
        """
        // Trigger IMAP download by accessing plain-text content first
        var bodyText = null;
        try { bodyText = msg.content(); } catch(e) {}

        // Attempt htmlContent (IMAP body should now be available)
        var htmlBody = null;
        try { htmlBody = msg.htmlContent(); } catch(e) {}
        // Retry once after short delay if still null
        if (htmlBody === null) {
            delay(0.5);
            try { htmlBody = msg.htmlContent(); } catch(e) {}
        }

        var headerDict = {};
        try {
            var allHeaders = msg.allHeaders() || '';
            var lines = allHeaders.split('\\n');
            var currentKey = '';
            for (var h = 0; h < lines.length; h++) {
                var line = lines[h];
                if (/^[A-Za-z0-9-]+:/.test(line)) {
                    var colonIdx = line.indexOf(':');
                    currentKey = line.substring(0, colonIdx);
                    headerDict[currentKey] = line.substring(colonIdx + 1).trim();
                } else if (currentKey && /^[ \\t]/.test(line)) {
                    headerDict[currentKey] += ' ' + line.trim();
                }
            }
        } catch(e) {}

        // See docs/gotchas/jxa.md — per-attachment try/catch required.
        var attachList = [];
        var msgHasAtt = false;
        var atts = [];
        try { atts = msg.mailAttachments(); msgHasAtt = atts.length > 0; } catch(e) {}
        for (var ai = 0; ai < atts.length; ai++) {
            var att = atts[ai];
            var attName = 'attachment_' + ai;
            try { attName = att.name(); } catch(e) {}
            var attMime = 'application/octet-stream';
            try { var m = att.mimeType(); if (m) attMime = m; } catch(e) {}
            var attSize = 0;
            try { attSize = att.fileSize(); } catch(e) {
                try { attSize = att.downloadedSize(); } catch(e2) {}
            }
            attachList.push({ name: attName, mimeType: attMime, size: attSize });
        }

        var msgSize = null;
        try { msgSize = msg.messageSize(); } catch(e) {}

        var __row = {
            id: acct.name() + '||' + mb.name() + '||' + String(msg.id()),
            account: acct.name(),
            mailbox: mb.name(),
            subject: msg.subject(),
            from: msg.sender(),
            to: msg.toRecipients().map(function(r) { return r.address(); }),
            date: msg.dateSent().toISOString(),
            read: msg.readStatus(),
            body: bodyText,
            size: msgSize,
            hasAttachment: msgHasAtt,
            htmlBody: htmlBody,
            headers: headerDict,
            attachments: attachList
        };
        """
    }

    static func jsResolveMailbox() -> String {
        """
        function resolveMailbox(acct, name) {
            var lc = name.toLowerCase();
            try {
                if (lc === 'trash' || lc === 'deleted' || lc === 'deleted messages' || lc === 'deleted items' || lc === 'bin') {
                    return acct.trash();
                }
            } catch(e) {}
            try {
                if (lc === 'junk' || lc === 'spam') { return acct.junk(); }
            } catch(e) {}
            try {
                if (lc === 'sent' || lc === 'sent messages' || lc === 'sent mail' || lc === 'sent items') { return acct.sent(); }
            } catch(e) {}
            try {
                if (lc === 'drafts' || lc === 'draft') { return acct.drafts(); }
            } catch(e) {}
            if (lc === 'inbox') {
                var mbs = acct.mailboxes();
                for (var i = 0; i < mbs.length; i++) {
                    if (mbs[i].name().toLowerCase() === 'inbox') return mbs[i];
                }
            }
            return findMailboxByName(acct.mailboxes(), name);
        }
        """
    }
}
