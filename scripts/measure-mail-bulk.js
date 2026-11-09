// Measures Mail.app Apple Event read strategies for one mailbox (pippin-25pr).
// Usage: osascript -l JavaScript scripts/measure-mail-bulk.js <account> <mailbox> [repeats] [loopRows]
// Prints one JSON object. Records timings and alignment checks only, never subjects or senders.
function run(argv) {
    var acctName = argv[0], mbName = argv[1];
    var repeats = Number(argv[2] || 3), loopRows = Number(argv[3] || 200);
    var mail = Application('Mail');
    var acct = mail.accounts.byName(acctName);
    // byName misses nested mailboxes such as Gmail's [Gmail]/All Mail, so match by enumeration.
    var mb = null, all = acct.mailboxes();
    for (var i0 = 0; i0 < all.length; i0++) if (all[i0].name() === mbName) { mb = all[i0]; break; }
    if (mb === null) throw new Error('mailbox not found: ' + mbName);
    var spec = mb.messages;
    var total = spec.length;
    var out = {account: acctName, accountType: String(acct.accountType()), mailbox: mbName, total: total,
               loopRows: loopRows, repeats: repeats, bulk: {}, loop: null, whose30d: null, alignment: {}, errors: []};

    function timed(fn) {
        var t0 = Date.now(); var v = fn(); return {ms: Date.now() - t0, value: v};
    }
    function median(xs) { var s = xs.slice().sort(function(a, b) { return a - b; }); return s[Math.floor(s.length / 2)]; }

    // Bulk plural-specifier getters, one Apple Event per property.
    var props = ['id', 'dateReceived', 'dateSent', 'readStatus', 'subject', 'sender', 'messageSize', 'messageId'];
    var bulkValues = {};
    for (var p = 0; p < props.length; p++) {
        var name = props[p], times = [], len = null;
        for (var r = 0; r < repeats; r++) {
            try {
                var t = timed(function() { return spec[name](); });
                times.push(t.ms); len = t.value.length; bulkValues[name] = t.value;
            } catch (e) { out.errors.push('bulk ' + name + ': ' + String(e)); break; }
        }
        if (times.length) out.bulk[name] = {medianMs: median(times), length: len, msPerRow: total ? median(times) / total : null};
    }
    try {
        var ta = timed(function() { return spec.mailAttachments(); });
        out.bulk.mailAttachments = {medianMs: ta.ms, length: ta.value.length};
    } catch (e) { out.errors.push('bulk mailAttachments: ' + String(e)); }

    // Alignment: id read again after the other properties, plus spot checks per message.
    try {
        var idsAgain = spec.id();
        var same = idsAgain.length === bulkValues.id.length;
        for (var i = 0; same && i < idsAgain.length; i++) if (idsAgain[i] !== bulkValues.id[i]) same = false;
        out.alignment.idStableAcrossReads = same;
        var lengths = {}; for (var k in bulkValues) lengths[k] = bulkValues[k].length;
        out.alignment.lengths = lengths;
        var msgs = spec();
        var mismatches = 0, checked = 0, nullDates = 0;
        for (var c = 0; c < 50 && total > 0; c++) {
            var idx = Math.floor(Math.random() * total);
            var m = msgs[idx];
            var id = m.id(), dr = m.dateReceived(), rs = m.readStatus();
            checked++;
            var bd = bulkValues.dateReceived[idx];
            if (bd === null || bd === undefined) nullDates++;
            var dateOk = (bd === null || bd === undefined) ? (dr === null || dr === undefined) : (dr !== null && bd.getTime() === dr.getTime());
            if (id !== bulkValues.id[idx] || !dateOk || rs !== bulkValues.readStatus[idx]) mismatches++;
        }
        out.alignment.spotChecked = checked; out.alignment.spotMismatches = mismatches; out.alignment.nullDatesSeen = nullDates;
    } catch (e) { out.errors.push('alignment: ' + String(e)); }

    // Current per-message loop over the first loopRows messages (about 9 events per row).
    try {
        var loopTimes = [];
        for (var lr = 0; lr < repeats; lr++) {
            var msgs2 = spec();
            var n = Math.min(loopRows, msgs2.length);
            var t2 = timed(function() {
                for (var j = 0; j < n; j++) {
                    var mm = msgs2[j];
                    mm.id(); mm.dateReceived(); mm.dateSent(); mm.readStatus(); mm.subject(); mm.sender(); mm.messageSize();
                    try { mm.mailAttachments().length; } catch (e) {}
                }
                return n;
            });
            loopTimes.push(t2.ms);
        }
        out.loop = {rows: Math.min(loopRows, total), medianMs: median(loopTimes), msPerRow: median(loopTimes) / Math.max(1, Math.min(loopRows, total))};
    } catch (e) { out.errors.push('loop: ' + String(e)); }

    // whose() date window plus bulk getters on the filtered specifier.
    try {
        var since = new Date(Date.now() - 30 * 86400000);
        var wt = timed(function() {
            var w = spec.whose({dateReceived: {_greaterThan: since}});
            var ids = w.id(); var dates = w.dateReceived(); var reads = w.readStatus();
            return {n: ids.length, aligned: ids.length === dates.length && dates.length === reads.length};
        });
        out.whose30d = {ms: wt.ms, matched: wt.value.n, aligned: wt.value.aligned};
    } catch (e) { out.errors.push('whose30d: ' + String(e)); }

    // Volatile set only (what a cached-read answer would fetch live).
    try {
        var vt = timed(function() { spec.id(); spec.dateReceived(); spec.readStatus(); return true; });
        out.volatileSetMs = vt.ms;
    } catch (e) { out.errors.push('volatile: ' + String(e)); }

    return JSON.stringify(out);
}
