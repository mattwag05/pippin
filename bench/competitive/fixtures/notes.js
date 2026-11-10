// JXA: seeds, dumps and removes the PippinBench Notes folder. Run ONLY inside the disposable benchmark VM.
//   osascript -l JavaScript notes.js seed <manifest.json>     prints state JSON
//   osascript -l JavaScript notes.js dump                     prints every folder named PippinBench with its notes
//   osascript -l JavaScript notes.js teardown <state.json>    deletes the listed folder and verifies by id
ObjC.import('Foundation');
const MARKER = 'PippinBench';

function readJSON(path) {
  const full = $(path).stringByExpandingTildeInPath;
  const text = $.NSString.stringWithContentsOfFileEncodingError(full, $.NSUTF8StringEncoding, null);
  if (text.isNil()) throw new Error('cannot read ' + path);
  return JSON.parse(text.js);
}

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// One <div> per line; the first line becomes the note title. Notes plaintext is then title, newline, body, newline.
function html(title, body) {
  return [title].concat(body.split('\n')).map(l => (l === '' ? '<div><br></div>' : '<div>' + esc(l) + '</div>')).join('');
}

function markerFolders(Notes) {
  return Notes.folders().filter(f => f.name() === MARKER);
}

function exists(specifier) {
  try { specifier.name(); return true; } catch (e) { return false; }
}

function run(argv) {
  const Notes = Application('Notes');
  const mode = argv[0];
  if (mode === 'seed') {
    const spec = readJSON(argv[1]).notes;
    markerFolders(Notes).forEach(f => Notes.delete(f));
    let account = Notes.accounts.byName(spec.account);
    if (!exists(account)) account = Notes.defaultAccount();
    account.folders.push(Notes.Folder({name: MARKER}));
    const folder = account.folders.byName(MARKER);
    spec.notes.forEach(n => folder.notes.push(Notes.Note({body: html(n.title, n.body)})));
    const byTitle = {};
    folder.notes().forEach(n => { byTitle[n.name()] = n.id(); });
    const notes = {};
    spec.notes.forEach(n => {
      if (!byTitle[n.title]) throw new Error('note was not created: ' + n.key);
      notes[n.key] = {id: byTitle[n.title]};
    });
    return JSON.stringify({notes_folder: {id: folder.id(), name: MARKER, account: account.name()}, notes: notes});
  }
  if (mode === 'dump') {
    return JSON.stringify({folders: markerFolders(Notes).map(f => ({
      id: f.id(), name: f.name(),
      notes: f.notes().map(n => ({id: n.id(), name: n.name(), plaintext: n.plaintext()})),
    }))});
  }
  if (mode === 'teardown') {
    const state = readJSON(argv[1]);
    const folderId = state.notes_folder && state.notes_folder.id;
    if (folderId && exists(Notes.folders.byId(folderId))) Notes.delete(Notes.folders.byId(folderId));
    const remaining = [];
    if (folderId && exists(Notes.folders.byId(folderId))) remaining.push('folder:' + folderId);
    const live = {};  // ids of notes still listed in any live folder (Recently Deleted is not scriptable)
    Notes.notes.id().forEach(id => { live[id] = true; });
    Object.keys(state.notes || {}).forEach(k => { if (live[state.notes[k].id]) remaining.push('note:' + state.notes[k].id); });
    const out = JSON.stringify({checked: Object.keys(state.notes || {}).length + (folderId ? 1 : 0), remaining: remaining});
    if (remaining.length) throw new Error(out);
    return out;
  }
  throw new Error('usage: notes.js seed <manifest.json> | dump | teardown <state.json>');
}
