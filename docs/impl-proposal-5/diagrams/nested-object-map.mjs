const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const tones = {
  memory: ['#f1f6fc', '#7e9fc4', '#365e89'], authority: ['#f3f3f9', '#aaa7c1', '#655d88'],
  required: ['#fcf6e9', '#c4a05e', '#876424'], indexed: ['#fcf6e9', '#c4a05e', '#876424'],
  derived: ['#ecf6f0', '#7eaf97', '#366b53'], portable: ['#f4effa', '#aa94c5', '#725496'],
  external: ['#f4f5f7', '#a1abb7', '#5c6979']
};
const relationNames = {
  process: 'Process / lifetime boundary', directory: 'Directory', file: 'File', bundle: 'File bundle',
  functional: 'Functional group', operation: 'Operation values', feature: 'Feature group',
  ownership: 'Session resources', role: 'Logical roles', association: 'Associated locations / state'
};
const physical = new Set(['process', 'directory', 'file', 'bundle']);
const edgeColors = {derive: '#467da9', commit: '#ad813c', copy: '#9273b5', reference: '#7d8997', guard: '#79728f'};

export function validateHierarchy(data, layout) {
  const seen = new Set(), groupIDs = new Set(), objectIDs = new Set(data.nodes.map(n => n.id));
  const edges = new Set(data.edges.map(e => e.id));
  function walk(item, ancestors = []) {
    if (item.object) {
      if (!objectIDs.has(item.object) || seen.has(item.object)) throw Error('Hierarchy object membership: ' + item.object);
      seen.add(item.object);
      const n = data.nodes.find(n => n.id === item.object);
      if (ancestors.includes('process') && !['memory', 'authority'].includes(n.kind)) throw Error('Disk object in process: ' + n.id);
      if (ancestors.includes('sqlite') && !['required', 'indexed', 'derived'].includes(n.kind)) throw Error('Non-SQL lifetime in database: ' + n.id);
      if (n.tables.length && !ancestors.includes('sqlite')) throw Error('SQL table outside database file: ' + n.id);
    }
    if (item.children) {
      if (!item.id || groupIDs.has(item.id)) throw Error('Hierarchy group ID: ' + item.id);
      groupIDs.add(item.id);
      for (const child of item.children) walk(child, [...ancestors, item.id]);
    }
  }
  walk(layout.tree);
  if (seen.size !== objectIDs.size) throw Error('Unnested objects: ' + [...objectIDs].filter(id => !seen.has(id)).join(', '));
  for (const trace of layout.traces) {
    for (const stage of trace.stages) for (const id of stage.nodes) if (!objectIDs.has(id)) throw Error('Trace object: ' + id);
    for (const id of trace.edges) if (!edges.has(id)) throw Error('Trace relationship: ' + id);
  }
  return {nestedObjects: seen.size, hierarchyGroups: groupIDs.size, operationTraces: layout.traces.length};
}

// Shared geometry keeps the interactive map and the printable SVG in the same hierarchy.
export function createNestedSVG(data, layout) {
  const byID = new Map(data.nodes.map(n => [n.id, n]));
  const bounds = {}, ancestry = {}, groups = [], parts = [];
  const wrap = (value, width, size = 14) => {
    const result = []; let line = '';
    const max = Math.max(12, Math.floor(width / (size * .52)));
    for (const word of String(value).split(/\s+/)) {
      if (line && line.length + word.length + 1 > max) { result.push(line); line = ''; }
      line += (line ? ' ' : '') + word;
    }
    if (line) result.push(line);
    return result;
  };
  const text = (lines, x, y, size, fill, extra = '') => '<text x="' + x + '" y="' + y + '" font-size="' + size + '" fill="' + fill + '" ' + extra + '>' + lines.map((line, i) => '<tspan x="' + x + '" dy="' + (i ? size * 1.22 : 0) + '">' + escape(line) + '</tspan>').join('') + '</text>';
  function measure(item, width) {
    item.w = width;
    if (!item.children) {
      const n = byID.get(item.object), display = layout.display[n.id] || {title: n.title, caption: n.subtitle[0]};
      item.titleLines = wrap(display.title, width - 30, 16);
      item.captionLines = wrap(display.caption, width - 30, 12);
      item.structureLines = (item.structure || []).flatMap((s, i) => wrap(s, width - 46 - i * 7, 11).map((line, j) => ({line, indent: i, continuation: j > 0})));
      item.h = Math.max(item.height || 100, 19 + item.titleLines.length * 19.5 + 6 + item.captionLines.length * 14.5 + 25 + (item.structureLines.length ? item.structureLines.length * 15 + 16 : 0));
      return item.h;
    }
    const pad = item.bare ? 0 : 16, gap = item.bare ? 18 : 14, cols = item.columns || 1;
    item.titleLines = wrap(item.title, width - pad * 2 - 30, item.major ? 23 : 17);
    item.captionLines = wrap(item.caption, width - pad * 2, 12);
    item.header = item.bare ? 0 : 30 + item.titleLines.length * (item.major ? 28 : 21) + item.captionLines.length * 15 + 13;
    item.rows = [];
    let total = item.header + pad;
    for (let start = 0; start < item.children.length; start += cols) {
      const row = item.children.slice(start, start + cols), weights = item.weights || row.map(() => 1);
      const weight = row.reduce((sum, _, i) => sum + (weights[i] || 1), 0), available = width - pad * 2 - gap * (row.length - 1);
      const widths = row.map((_, i) => available * (weights[i] || 1) / weight);
      const height = Math.max(...row.map((child, i) => measure(child, widths[i])));
      item.rows.push({children: row, widths, height, gap});
      total += height + (start + cols < item.children.length ? gap : 0);
    }
    item.h = total + pad + (item.note ? 44 : 0);
    return item.h;
  }
  function draw(item, x, y, parents = []) {
    item.x = x; item.y = y;
    if (!item.children) {
      const n = byID.get(item.object), [fill, stroke, ink] = tones[n.kind];
      bounds[n.id] = {x, y, width: item.w, height: item.h}; ancestry[n.id] = parents;
      parts.push('<g id="node-' + n.id + '" class="node leaf ' + n.kind + '" data-object="' + n.id + '"><title>' + escape(n.title + ' · ' + data.kinds[n.kind]) + '</title>');
      parts.push('<rect class="node-body" x="' + x + '" y="' + y + '" width="' + item.w + '" height="' + item.h + '" rx="7" fill="white" stroke="' + stroke + '" stroke-opacity=".66"/>');
      parts.push('<path d="M ' + (x + 2) + ' ' + (y + 11) + ' V ' + (y + item.h - 11) + '" stroke="' + stroke + '" stroke-width="3"/>');
      let ty = y + 23;
      parts.push(text(item.titleLines, x + 14, ty, 16, '#22344b', 'font-weight="600"'));
      ty += item.titleLines.length * 19.5 + 4;
      parts.push(text(item.captionLines, x + 14, ty, 12, '#617187'));
      ty += item.captionLines.length * 14.5 + 9;
      if (item.structureLines.length) {
        const height = item.structureLines.length * 15 + 9;
        parts.push('<rect x="' + (x + 12) + '" y="' + (ty - 4) + '" width="' + (item.w - 24) + '" height="' + height + '" rx="4" fill="' + fill + '"/>');
        for (const s of item.structureLines) { parts.push(text([s.line], x + 19 + s.indent * 7, ty + 8, 11, ink)); ty += 15; }
      }
      parts.push(text([n.features.join('  ·  ')], x + 14, y + item.h - 10, 10, ink, 'class="feature-letters"'));
      if (n.statusLabel) parts.push(text([n.statusLabel], x + item.w - 12, y + item.h - 10, 8, '#997939', 'text-anchor="end"'));
      parts.push('<g class="step-marker" data-step="' + n.id + '" visibility="hidden"><circle cx="' + (x + item.w - 7) + '" cy="' + (y + 5) + '" r="13" fill="#234d76" stroke="white" stroke-width="2"/><text x="' + (x + item.w - 7) + '" y="' + (y + 9) + '" text-anchor="middle" font-size="11" font-weight="700" fill="white"></text></g></g>');
      return;
    }
    const tone = tones[item.tone || 'external'], tag = relationNames[item.relation] || '';
    const count = collect(item).length;
    groups.push({id: item.id, title: item.title, caption: item.caption, relation: tag, objects: collect(item), x, y, width: item.w, height: item.h});
    parts.push('<g id="group-' + item.id + '" class="map-group ' + (physical.has(item.relation) ? 'physical' : 'functional') + '" data-group="' + item.id + '">');
    if (!item.bare) {
      parts.push('<rect class="group-bg" x="' + x + '" y="' + y + '" width="' + item.w + '" height="' + item.h + '" rx="' + (item.major ? 15 : 10) + '" fill="' + tone[0] + '" stroke="' + tone[1] + '" stroke-width="' + (physical.has(item.relation) ? 1.4 : .6) + '" stroke-opacity="' + (physical.has(item.relation) ? .9 : .45) + '"/>');
      if (item.object) {
        const n = byID.get(item.object);
        bounds[n.id] = {x, y, width: item.w, height: item.header}; ancestry[n.id] = parents;
        parts.push('<g id="node-' + n.id + '" class="node container-object" data-object="' + n.id + '"><title>' + escape(n.title) + '</title><rect class="node-body" x="' + (x + 3) + '" y="' + (y + 3) + '" width="' + (item.w - 6) + '" height="' + (item.header - 5) + '" rx="8" fill="transparent" stroke="transparent"/>');
      }
      parts.push(text([tag.toUpperCase() + '  ·  ' + count + ' OBJECT GROUPS'], x + 16, y + 21, 9, tone[2], 'letter-spacing=".8"'));
      parts.push(text(item.titleLines, x + 16, y + 44, item.major ? 23 : 17, '#26384f', 'font-weight="' + (item.major ? 650 : 600) + '"'));
      parts.push(text(item.captionLines, x + 16, y + 44 + item.titleLines.length * (item.major ? 28 : 21), 12, '#607187'));
      if (item.object) {
        const n = byID.get(item.object);
        parts.push('<g class="step-marker" data-step="' + n.id + '" visibility="hidden"><circle cx="' + (x + item.w - 10) + '" cy="' + (y + 10) + '" r="13" fill="#234d76" stroke="white" stroke-width="2"/><text x="' + (x + item.w - 10) + '" y="' + (y + 14) + '" text-anchor="middle" font-size="11" font-weight="700" fill="white"></text></g></g>');
      }
    }
    const pad = item.bare ? 0 : 16;
    let yy = y + item.header + pad;
    for (const row of item.rows) {
      let xx = x + pad;
      for (let i = 0; i < row.children.length; i++) { draw(row.children[i], xx, yy, item.bare ? parents : [...parents, item.id]); xx += row.widths[i] + row.gap; }
      yy += row.height + row.gap;
    }
    if (item.note) parts.push(text(wrap(item.note, item.w - 36, 11), x + 18, y + item.h - 23, 11, '#6c7180'));
    parts.push('</g>');
  }
  function collect(item) { return [...(item.object ? [item.object] : []), ...(item.children || []).flatMap(collect)]; }
  const width = layout.width, offset = 258, tree = structuredClone(layout.tree);
  measure(tree, width - 48);
  const height = tree.h + offset + 55;
  parts.push('<svg xmlns="http://www.w3.org/2000/svg" width="' + width + '" height="' + height + '" viewBox="0 0 ' + width + ' ' + height + '" role="img" aria-label="Nested NVStorage architecture: physical containers, in-memory roles and derivation paths" font-family="system-ui, -apple-system, Helvetica, sans-serif">');
  parts.push('<defs><marker id="arrowhead" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0 0 L8 4 L0 8" fill="context-stroke"/></marker></defs><style>.node{cursor:pointer}.node.selected>.node-body{stroke:#244d75;stroke-width:3;fill:#f2f7fd}.node.related>.node-body{stroke:#5d86ad;stroke-width:2}.node.dim{opacity:.22}.node:focus{outline:none}.node:focus>.node-body{stroke:#244d75;stroke-width:3}.edge{display:none;pointer-events:none}.edge.shown{display:inline}.trace-box{cursor:pointer}</style>');
  parts.push('<rect width="100%" height="100%" fill="#ffffff"/>');
  parts.push(text([layout.title], 26, 37, 27, '#24374e', 'font-weight="650"'));
  parts.push(text([layout.subtitle], 27, 61, 13, '#65768b'));
  parts.push(text(['Nesting shows the labeled boundary. Functional subheadings group similar roles. Select an operation to trace its objects.'], 27, 87, 12, '#65768b'));
  const summaries = [
    ['save', '01  EDIT / SAVE', 'Live notes → capture / seal → checked batch → local acceptance'],
    ['reopen', '02  REOPEN', 'Required work / suffix → current rows + context → live notes'],
    ['receive', '03  RECEIVE', 'Repository → durable candidates → checked unit → acceptance'],
    ['publish', '04  PUBLISH', 'Accepted bytes → owned stage → verified immutable install'],
    ['plaintext', '05  PLAINTEXT', 'File observations → retained review input → admitted action'],
    ['repair', '06  REPAIR / COPY', 'Independent evidence → verified sibling → selection / output']
  ];
  for (let i = 0; i < summaries.length; i++) {
    const [id, label, caption] = summaries[i], w = (width - 76) / 3, x = 26 + (i % 3) * (w + 12), y = 107 + Math.floor(i / 3) * 67;
    parts.push('<g class="trace-box" data-trace="' + id + '"><rect x="' + x + '" y="' + y + '" width="' + w + '" height="57" rx="7" fill="#f5f7fa" stroke="#dce3ec"/>' + text([label], x + 13, y + 19, 10, '#486684', 'font-weight="650" letter-spacing=".6"') + text(wrap(caption, w - 26, 12), x + 13, y + 38, 12, '#4d6077') + '</g>');
  }
  draw(tree, 24, offset);
  parts.push('<g id="relationship-layer">');
  for (const edge of data.edges) {
    const a = bounds[edge.source], b = bounds[edge.target];
    let ax = a.x + a.width / 2, ay = a.y + a.height / 2, bx = b.x + b.width / 2, by = b.y + b.height / 2;
    if (Math.abs(ax - bx) > Math.abs(ay - by)) { ax += Math.sign(bx - ax) * a.width / 2; bx -= Math.sign(bx - ax) * b.width / 2; }
    else { ay += Math.sign(by - ay) * a.height / 2; by -= Math.sign(by - ay) * b.height / 2; }
    const bend = Math.max(35, Math.abs(bx - ax) * .28), path = edge.source === edge.target ? 'M' + ax + ',' + ay + ' c70,-60 70,60 0,0' : 'M' + ax + ',' + ay + ' C' + (ax + bend) + ',' + ay + ' ' + (bx - bend) + ',' + by + ' ' + bx + ',' + by;
    parts.push('<g id="edge-' + edge.id + '" class="edge" data-edge="' + edge.id + '"><title>' + escape(edge.operation) + '</title><path d="' + path + '" fill="none" stroke="white" stroke-width="6"/><path d="' + path + '" fill="none" stroke="' + edgeColors[edge.kind] + '" stroke-width="2.5" ' + (edge.kind === 'guard' ? 'stroke-dasharray="7 5"' : '') + ' marker-end="url(#arrowhead)"/></g>');
  }
  parts.push('</g>');
  parts.push(text([data.nodes.length + ' object groups · ' + data.edges.length + ' operations / relationships · all ' + data.nodes.flatMap(n => n.tables).length + ' SQL tables · source-linked adopted design · planned adapters marked'], 26, height - 19, 11, '#6c7a8e'));
  parts.push('</svg>');
  return {svg: parts.join('\n'), geometry: {width, height, bounds, ancestry, groups}};
}

export function createHTML(data, layout, rendered, css, viewer) {
  const model = JSON.stringify({...data, presentation: layout, geometry: rendered.geometry}).replaceAll('<', '\\u003c');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'">
<title>NVStorage · scenarios & object map</title><style>${css}</style></head><body>
<header><div><h1>NVStorage <span>scenarios & object map</span></h1><p>Storage behavior, participating objects, operations, and requirement/test references.</p></div><div class="header-links"><a href="NVStorage-Scenarios.md" target="_blank" rel="noopener">Scenario document ↗</a><a href="../NVStorage-Object-Map.md" target="_blank" rel="noopener">Inventory & sources ↗</a></div></header>
<nav class="view-switch" aria-label="Reference views"><button id="show-scenarios" aria-pressed="true">Scenarios <span>${data.scenarioCatalog.scenarios.length}</span></button><button id="show-map" aria-pressed="false">Architecture map</button><p id="view-context">Scenario conditions, processing stages, and source references.</p></nav>
<div id="map-controls" class="toolbar" aria-label="Map controls" hidden><input id="search" type="search" placeholder="Find an object, record or SQL table" aria-label="Find an object, record or SQL table"><select id="feature" aria-label="Highlight feature"><option value="">All features</option></select><button id="fit-width">Fit width</button><button id="fit-all">Whole map</button><button id="minus" aria-label="Zoom out">−</button><output id="zoom-value"></output><button id="plus" aria-label="Zoom in">+</button><button id="reset">Clear focus</button><span id="summary">${data.nodes.length} groups · ${data.nodes.flatMap(n => n.tables).length} SQL tables</span></div>
<nav id="traces" aria-label="Trace an operation"><span>Trace</span></nav>
<nav id="scenario-strip" class="scenario-strip" aria-label="Walkthrough controls" hidden><button id="back-library">← All scenarios</button><strong id="walkthrough-label"></strong><span id="walkthrough-status" role="status" aria-live="polite"></span><button id="strip-prev" aria-label="Previous walkthrough step">←</button><button id="strip-next" aria-label="Next walkthrough step">→</button><button id="return-step">Show current step</button><button id="exit-walkthrough">Exit walkthrough</button></nav>
<main id="workspace"><section id="scenario-library" class="scenario-library" aria-label="Scenario reference"><div class="library-intro"><div><div class="eyebrow">Behavior and operation sequences</div><h2>Scenario reference</h2><p>Each scenario specifies an initial state and follows storage operations through their observable results. Select a card to inspect the participating objects, applicable rules, and requirement/test-contract references.</p></div><div class="library-scope"><strong>${data.scenarioCatalog.scenarios.length} scenarios · ${data.scenarioCatalog.requirements.length} requirements · ${data.scenarioCatalog.contracts.length} test contracts</strong><p>${escape(data.scenarioCatalog.scope)}</p></div></div><div class="library-controls"><label class="scenario-query">Scenario search<input id="scenario-search" type="search" placeholder="Scenario, object, requirement or contract ID"></label><label>Requirement<select id="scenario-requirement"><option value="">All requirements</option></select></label><button id="clear-scenario-filters">Clear filters</button><span id="scenario-count" role="status" aria-live="polite"></span></div><nav id="scenario-categories" class="scenario-categories" aria-label="Scenario categories"></nav><div id="scenario-results"></div></section><div id="canvas" class="canvas" inert aria-hidden="true">${rendered.svg}</div><aside id="inspector" class="inspector" aria-label="Object and walkthrough details" hidden><button id="close" class="close" aria-label="Close details">×</button><div id="details" aria-live="polite"></div></aside><div id="connection" class="connection" hidden></div></main>
<footer><span><i style="background:#c4a05e"></i>Required private / accepted history</span><span><i style="background:#7eaf97"></i>Rebuildable</span><span><i style="background:#aa94c5"></i>Portable immutable</span><span><i style="background:#7e9fc4"></i>Memory</span><span><i style="background:#aaa7c1"></i>Owners / context</span><span>Process / file / directory borders = containment · functional subheadings = similarity · click a card for inputs and outputs</span></footer>
<noscript>JavaScript enables guided navigation. <a href="NVStorage-Scenarios.md">Read all scenario walkthroughs</a> or <a href="nvstorage-object-map.svg">open the standalone map</a>.</noscript>
<script id="model" type="application/json">${model}</script><script>${viewer}</script></body></html>`;
}

export function createHierarchyDOT(data, layout) {
  const lines = ['digraph NVStorage {', 'graph [compound=true, rankdir=TB];', 'node [shape=box, style=rounded];'];
  function walk(item) {
    if (!item.children) { const n = data.nodes.find(n => n.id === item.object); lines.push(JSON.stringify(n.id) + ' [label=' + JSON.stringify(n.title) + '];'); return; }
    lines.push('subgraph cluster_' + item.id.replaceAll('-', '_') + ' { label=' + JSON.stringify(item.title + (item.caption ? '\n' + item.caption : '')) + ';');
    if (item.object) lines.push(JSON.stringify(item.object) + ' [label=' + JSON.stringify(data.nodes.find(n => n.id === item.object).title) + '];');
    for (const child of item.children) walk(child);
    lines.push('}');
  }
  walk(layout.tree);
  for (const edge of data.edges) lines.push(JSON.stringify(edge.source) + ' -> ' + JSON.stringify(edge.target) + ' [label=' + JSON.stringify(edge.operation) + '];');
  lines.push('}');
  return lines.join('\n') + '\n';
}
