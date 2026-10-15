// Match diagram prose to canonical terms and their existing glossary sections.
const aliases = {
  'Operation': ['logical operation', 'logical operations', 'note operation', 'note operations'],
  'Current-state materialization': ['materialization', 'materialized current rows'],
  'Private current-row dictionary': ['current-row dictionaries'],
  'Retained-history pin': ['retained pin', 'retained history pin'],
  'Provider snapshot': ['provider snapshots'],
  'Collection bootstrap': ['editable bootstrap'],
  'Snapshot retention parent': ['retention parent', 'retention parents', 'retention-parent'],
  'Causal parents': ['causal parent'],
  'Note predecessors': ['note predecessor'],
  'Scope parents': ['scope parent', 'scope-parent'],
  'Dependency closure': ['complete closure', 'required closure'],
  'Note birth': ['fresh birth', 'fresh-birth', 'birth'],
  'Note head': ['note heads'],
  'Represented revisions': ['represented inputs', 'represented-input'],
  'Action group': ['action groups'],
  'Action record': ['action records'],
  'Action origin': ['action-origin'],
  'Immutable object': ['immutable objects'],
  'Object envelope': ['envelope', 'envelopes'],
  'Sealed object': ['sealed bytes', 'sealed objects'],
  'Live note store': ['live store'],
  'Local store': ['private store', 'local stores'],
  'Generation fence': ['generation-fenced', 'generation-checked', 'generation checks'],
  'Separate note file / projection': ['projection', 'projections', 'note projection', 'note projections'],
  'Projection stamp': ['projection stamps', 'advisory stamp', 'advisory stamps'],
  'Projection receipt': ['projection receipts'],
  'Accepted projection / provisional relationship claim': ['accepted projection', 'provisional relationship claim'],
  'Pending-file item / latest pending snapshot': ['pending-file item', 'latest pending snapshot'],
  'Operation reservation / frozen pending input': ['operation reservation', 'frozen pending input'],
  'Portable causal undo': ['causal Undo/Redo', 'portable Undo', 'portable Undo/Redo'],
  'Compensation target': ['compensation targets'],
  'Compensation family': ['compensation families'],
  'Unresolved provider version': ['unresolved provider versions', 'Apple unresolved versions'],
  'Representation-only copy disposition': ['copy disposition'],
  'Accepted-file scan hint': ['accepted-file hints', 'accepted-file scan hints'],
  'Local durability barrier': ['local barrier'],
  'Physical authority': ['physical permission'],
  'Root session': ['root owner'],
  'Root-directory lock': ['root lock'],
  'Repository transport driver': ['transport driver'],
  'Current-notes export': ['current-note export'],
  'Save Current Collection As': ['Save Current Collection As…'],
  'Remaining effect': ['remaining effects', 'remaining-effect coverage']
};

export function prepareGlossary(text, href) {
  const lines = text.split('\n'), entries = [], anchors = new Set(), seen = new Map();
  let section;
  const slug = value => value.toLowerCase().replace(/<[^>]*>/g, '').replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/ /g, '-');
  for (const [i, line] of lines.entries()) {
    const heading = line.match(/^#{1,6}\s+(.+?)(?:\s+#+)?$/);
    if (heading) {
      const base = slug(heading[1]), occurrence = seen.get(base) || 0;
      seen.set(base, occurrence + 1); section = base + (occurrence ? '-' + occurrence : ''); anchors.add(section);
    }
    const term = line.match(/^\*\*([^*]+?)\*\*:?(?:\s*)$/) || line.match(/^- \*\*([^*]+?):\*\*\s*(.*)$/);
    if (!term) continue;
    if (!section) throw Error('Glossary definition has no section: ' + term[1]);
    const paragraph = term[2] ? [term[2]] : [];
    for (let j = i + 1; j < lines.length; j++) {
      if (!lines[j].trim()) { if (paragraph.length) break; continue; }
      if (/^(?:#|\*\*|_Avoid_|- \*\*)/.test(lines[j])) break;
      paragraph.push(lines[j].trim());
    }
    const definition = paragraph.join(' ').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/[`*]/g, '');
    if (!definition) throw Error('Empty glossary definition: ' + term[1]);
    entries.push({term: term[1], definition, anchor: section, href: href + '#' + section,
      aliases: [term[1], ...(aliases[term[1]] || [])], caseSensitive: ['Current','Local State','Operation'].includes(term[1])});
  }
  const terms = new Set(entries.map(entry => entry.term));
  for (const term of Object.keys(aliases)) if (!terms.has(term)) throw Error('Glossary alias target missing: ' + term);
  if (terms.size !== entries.length) throw Error('Duplicate glossary definition');
  for (const entry of entries) if (!anchors.has(entry.anchor)) throw Error('Missing glossary section: ' + entry.term);
  return {path: 'CONTEXT.md', href, entries};
}

// Keep displayed prose intact while finding whole terms outside code identifiers.
export function glossaryParts(value, glossary) {
  const text = String(value), lookup = new Map(), used = new Set(), parts = [];
  for (const entry of glossary.entries) for (const alias of entry.aliases) {
    const key = alias.toLowerCase();
    if (lookup.has(key) && lookup.get(key).term !== entry.term) throw Error('Ambiguous glossary alias: ' + alias);
    lookup.set(key, entry);
  }
  const escapePattern = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = [...lookup.keys()].sort((a, b) => b.length - a.length || a.localeCompare(b)).map(escapePattern).join('|');
  const matches = text.matchAll(new RegExp(pattern, 'giu'));
  let cursor = 0;
  for (const match of matches) {
    const index = match.index, word = match[0], entry = lookup.get(word.toLowerCase());
    if (/[\p{L}\p{N}_]/u.test(text[index - 1] || '') || /[\p{L}\p{N}_]/u.test(text[index + word.length] || '')) continue;
    if (entry.term === 'Current' && /^(?:-|\s+(?:rows?|cells?|view|files?|state)\b)/i.test(text.slice(index + word.length))) continue;
    const namedAlias = entry.aliases.slice(1).some(alias => alias.toLowerCase() === word.toLowerCase());
    if ((entry.caseSensitive && word !== entry.term && !namedAlias) || used.has(entry.term)) continue;
    if (index > cursor) parts.push({text: text.slice(cursor, index)});
    parts.push({text: word, entry}); used.add(entry.term); cursor = index + word.length;
  }
  if (cursor < text.length) parts.push({text: text.slice(cursor)});
  return parts;
}

export function glossaryHTML(value, glossary) {
  const safe = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  return glossaryParts(value, glossary).map(part => part.entry
    ? '<a class="glossary-term" href="' + safe(part.entry.href) + '" target="_blank" rel="noopener" title="' + safe(part.entry.term + ': ' + part.entry.definition) + '">' + safe(part.text) + '</a>'
    : safe(part.text)).join('');
}

export function glossaryMarkdown(document, glossary) {
  let fenced = false;
  return document.split('\n').map(line => {
    if (/^```/.test(line)) { fenced = !fenced; return line; }
    if (fenced || /^#/.test(line)) return line;
    return line.split(/(\[[^\]\n]+\]\([^)\n]+\)|`[^`\n]+`)/g).map((part, i) => i % 2 ? part
      : glossaryParts(part, glossary).map(piece => piece.entry ? '[' + piece.text + '](' + piece.entry.href + ')' : piece.text).join('')).join('');
  }).join('\n');
}
