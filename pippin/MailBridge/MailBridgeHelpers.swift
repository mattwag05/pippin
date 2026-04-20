import Foundation

extension MailBridge {
    // MARK: - JS Escape Helpers

    static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func jsEscapeOptional(_ s: String?) -> String {
        s.map { "'\(jsEscape($0))'" } ?? "null"
    }

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
