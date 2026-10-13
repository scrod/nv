const model = JSON.parse(document.getElementById('model').textContent);
const {presentation, geometry, scenarioCatalog: catalog} = model;
const canvas = document.getElementById('canvas'), svg = canvas.querySelector('svg');
const inspector = document.getElementById('inspector'), details = document.getElementById('details');
const library = document.getElementById('scenario-library'), workspace = document.getElementById('workspace');
const byID = new Map(model.nodes.map(node => [node.id, node]));
const byEdge = new Map(model.edges.map(edge => [edge.id, edge]));
const byTrace = new Map(presentation.traces.map(trace => [trace.id, trace]));
const byGroup = new Map(geometry.groups.map(group => [group.id, group]));
const byScenario = new Map(catalog.scenarios.map(s => [s.id, s]));
const byCategory = new Map(catalog.categories.map(c => [c.id, c]));
const byRequirement = new Map(catalog.requirements.map(r => [r.id, r]));
const byContract = new Map(catalog.contracts.map(c => [c.id, c]));
const progress = new Map(), mapTop = 242, mapHeight = geometry.height - mapTop;
svg.setAttribute('viewBox', '0 ' + mapTop + ' ' + geometry.width + ' ' + mapHeight);
const safe = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const plain = value => String(value).replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/[`*]/g, '');
const objectName = id => presentation.display[id]?.title || byID.get(id).title;
const objectButton = id => '<button class="object-link" data-object="' + id + '">' + safe(objectName(id)) + '</button>';
const sourceLink = (ref, label = ref.section) => '<a href="' + safe(ref.href) + '" target="_blank" rel="noopener" title="' + safe(plain(ref.title || ref.section || ref.path)) + '">' + safe(label) + '</a>';
const evidenceChips = (ids, registry) => ids.map(id => sourceLink(registry.get(id), id)).join('');
const roleNames = {read: 'Read / consume', write: 'Write / produce', guard: 'Check / gate'};
let zoom = 1, fitted = 'width', selected = null, traceID = null, feature = null, query = '', edgeID = null;
let scenarioID = null, stepIndex = 0, browsing = true, categoryFilter = '', requirementFilter = '', scenarioQuery = '';

function showPanel(content) { details.innerHTML = content; inspector.hidden = false; inspector.scrollTop = 0; }
function setZoom(value, center = true) {
  const old = zoom, x = (canvas.scrollLeft + canvas.clientWidth / 2) / old, y = (canvas.scrollTop + canvas.clientHeight / 2) / old;
  zoom = Math.max(.16, Math.min(2.5, value));
  svg.style.width = geometry.width * zoom + 'px'; svg.style.height = mapHeight * zoom + 'px';
  document.getElementById('zoom-value').value = Math.round(zoom * 100) + '%';
  if (center) { canvas.scrollLeft = x * zoom - canvas.clientWidth / 2; canvas.scrollTop = y * zoom - canvas.clientHeight / 2; }
}
function fit(mode = 'width') {
  fitted = mode;
  const value = (canvas.clientWidth - 18) / geometry.width;
  setZoom(mode === 'all' ? Math.min(value, (canvas.clientHeight - 18) / mapHeight) : value, false);
  canvas.scrollTo({left: 0, top: 0});
}
function goToObject(id) {
  const bounds = geometry.bounds[id];
  if (!bounds) return;
  const panelOverlap = !scenarioID && !inspector.hidden ? inspector.offsetWidth + 40 : 0;
  const available = Math.max(200, canvas.clientWidth - panelOverlap);
  fitted = null;
  setZoom(Math.max(zoom, Math.min(1.1, available / (bounds.width + 65))), false);
  canvas.scrollTo({left: Math.max(0, (bounds.x + bounds.width / 2) * zoom - available / 2), top: Math.max(0, (bounds.y - mapTop) * zoom - 65), behavior: 'auto'});
}
function currentStep() { return scenarioID ? byScenario.get(scenarioID).steps[stepIndex] : null; }
function fitStep() {
  const step = currentStep();
  if (!step) return;
  const bounds = [...new Set(Object.values(step.roles).flat())].map(id => geometry.bounds[id]);
  const x = Math.min(...bounds.map(b => b.x)), y = Math.min(...bounds.map(b => b.y));
  const width = Math.max(...bounds.map(b => b.x + b.width)) - x, height = Math.max(...bounds.map(b => b.y + b.height)) - y;
  fitted = null;
  setZoom(Math.min((canvas.clientWidth - 50) / width, (canvas.clientHeight - 50) / height, 1.1), false);
  canvas.scrollTo({left: Math.max(0, (x + width / 2) * zoom - canvas.clientWidth / 2), top: Math.max(0, (y + height / 2 - mapTop) * zoom - canvas.clientHeight / 2)});
}
function operationButton(edge, nodeID) {
  const other = edge.source === nodeID ? edge.target : edge.source;
  return '<button class="operation" data-edge="' + edge.id + '">' + safe(edge.operation) + '<small>' + safe(edge.source === nodeID ? '→ ' : '← ') + safe(objectName(other)) + '</small></button>';
}
function apply() {
  const active = new Set(), related = new Set(), stages = new Map(), roles = new Map();
  const step = currentStep();
  if (edgeID) { const e = byEdge.get(edgeID); active.add(e.source); active.add(e.target); }
  else if (selected) {
    active.add(selected);
    for (const e of model.edges.filter(e => e.source === selected || e.target === selected)) { active.add(e.source); active.add(e.target); related.add(e.source); related.add(e.target); }
  } else if (traceID) {
    byTrace.get(traceID).stages.forEach((stage, i) => stage.nodes.forEach(id => { active.add(id); if (!stages.has(id)) stages.set(id, i + 1); }));
  } else if (feature) model.nodes.filter(n => n.features.includes(feature)).forEach(n => active.add(n.id));
  else if (query) model.nodes.filter(n => [n.title, n.purpose, ...n.members, ...n.tables].join(' ').toLowerCase().includes(query)).forEach(n => active.add(n.id));
  else if (step) {
    // Role priority makes a read-and-written object visibly an output of this step.
    for (const role of ['read', 'guard', 'write']) for (const id of step.roles[role] || []) { active.add(id); roles.set(id, role); stages.set(id, stepIndex + 1); }
  } else model.nodes.forEach(n => active.add(n.id));
  for (const n of model.nodes) {
    const el = document.getElementById('node-' + n.id);
    el.classList.toggle('dim', !active.has(n.id)); el.classList.toggle('selected', n.id === selected || !!edgeID && active.has(n.id));
    el.classList.toggle('related', active.has(n.id) && !selected && !!(traceID || feature || query) || related.has(n.id) && n.id !== selected);
    for (const role of ['read', 'write', 'guard']) el.classList.toggle('scenario-' + role, roles.get(n.id) === role);
    el.setAttribute('aria-label', n.title + '; ' + model.kinds[n.kind] + (roles.has(n.id) ? '; step ' + (stepIndex + 1) + ', ' + roleNames[roles.get(n.id)] : ''));
    const marker = svg.querySelector('[data-step="' + n.id + '"]');
    marker.setAttribute('visibility', stages.has(n.id) ? 'visible' : 'hidden');
    marker.querySelector('text').textContent = stages.get(n.id) || '';
  }
  for (const e of model.edges) document.getElementById('edge-' + e.id).classList.toggle('shown', e.id === edgeID);
  document.querySelectorAll('[data-trace]').forEach(button => button.classList.toggle('active', button.dataset.trace === traceID));
  document.getElementById('feature').value = feature || '';
  const connection = document.getElementById('connection'); connection.hidden = !edgeID || browsing;
  if (edgeID) { const e = byEdge.get(edgeID); connection.innerHTML = '<small>' + safe(objectName(e.source)) + ' → ' + safe(objectName(e.target)) + '</small>' + safe(e.operation); }
  return active;
}
function clearState() { selected = null; traceID = null; feature = null; query = ''; edgeID = null; document.getElementById('search').value = ''; }
function reset() { clearState(); if (scenarioID && !browsing) showWalkthrough(false); else { inspector.hidden = true; apply(); } }
function returnLink() { return scenarioID ? '<button class="return-walkthrough" data-return-step>← Back to step ' + (stepIndex + 1) + ': ' + safe(currentStep().title) + '</button>' : ''; }
function selectObject(id, move = false) {
  clearState(); selected = id; apply();
  document.getElementById('close').setAttribute('aria-label', scenarioID ? 'Return to walkthrough' : 'Close details');
  const n = byID.get(id), incoming = model.edges.filter(e => e.target === id), outgoing = model.edges.filter(e => e.source === id);
  const path = geometry.ancestry[id].map(id => byGroup.get(id)).filter(g => g?.title);
  showPanel(returnLink() + '<div class="eyebrow">' + safe(model.kinds[n.kind]) + '</div><h2>' + safe(n.title) + '</h2>' +
    '<div class="breadcrumbs">' + path.map(g => safe(g.title)).join(' › ') + '</div><p>' + safe(n.purpose) + '</p>' +
    '<div>' + n.features.map(id => '<span class="badge">' + safe(model.features.find(f => f.id === id).label) + '</span>').join('') + '</div>' +
    '<h3>Inside this object group</h3><ul class="members">' + n.members.map(member => '<li>' + safe(member) + '</li>').join('') + '</ul>' +
    (n.tables.length ? '<h3>SQL tables</h3><p>' + n.tables.map(safe).join(' · ') + '</p>' : '') +
    '<p class="status">' + safe(n.status) + '</p>' +
    '<h3>Inputs / issuing operations</h3>' + (incoming.map(e => operationButton(e, id)).join('') || '<p>Physical contents are shown by nesting.</p>') +
    '<h3>Outputs / consuming operations</h3>' + (outgoing.map(e => operationButton(e, id)).join('') || '<p>Physical contents are shown by nesting.</p>') +
    '<h3>Source contracts</h3><ul>' + n.sourceLinks.map(source => '<li>' + sourceLink(source, source.path) + '</li>').join('') + '</ul>');
  if (move) goToObject(id);
}
function selectTrace(id) {
  if (traceID === id) { reset(); return; }
  clearState(); traceID = id; apply();
  const trace = byTrace.get(id);
  showPanel(returnLink() + '<div class="eyebrow">Operation trace · numbered on the map</div><h2>' + safe(trace.title) + '</h2><p>' + safe(trace.description) + '</p>' +
    trace.stages.map((stage, i) => '<section class="step"><span>' + (i + 1) + '</span><h3>' + safe(stage.title) + '</h3><p>' + safe(stage.detail) + '</p><div>' + stage.nodes.map(objectButton).join('') + '</div></section>').join('') +
    '<details><summary>Exact operations in this trace (' + trace.edges.length + ')</summary>' + trace.edges.map(id => { const e = byEdge.get(id); return '<button class="operation" data-edge="' + id + '">' + safe(e.operation) + '<small>' + safe(objectName(e.source)) + ' → ' + safe(objectName(e.target)) + '</small></button>'; }).join('') + '</details>');
}
function selectEdge(id) {
  clearState(); edgeID = id; apply(); const edge = byEdge.get(id);
  showPanel(returnLink() + '<div class="eyebrow">' + safe(edge.kind) + ' · one relationship</div><h2>' + safe(edge.operation) + '</h2><h3>Input / issuer</h3>' + objectButton(edge.source) + '<h3>Output / consumer</h3>' + objectButton(edge.target) + '<p>The map shows this one connector. Select either object to inspect its full inputs, outputs and source contracts.</p>');
}
function resultPanel(active, title, eyebrow) {
  showPanel(returnLink() + '<div class="eyebrow">' + safe(eyebrow) + '</div><h2>' + safe(title) + '</h2><p>' + active.size + ' object groups highlighted within their existing containers.</p><ul>' + model.nodes.filter(n => active.has(n.id)).map(n => '<li>' + objectButton(n.id) + '<div class="breadcrumbs">' + geometry.ancestry[n.id].map(id => byGroup.get(id)?.title).filter(Boolean).map(safe).join(' › ') + '</div></li>').join('') + '</ul>');
}

function updateView() {
  library.hidden = !browsing; canvas.inert = browsing; canvas.setAttribute('aria-hidden', String(browsing));
  workspace.classList.toggle('walkthrough-active', !browsing && !!scenarioID);
  document.getElementById('map-controls').hidden = browsing;
  document.getElementById('map-controls').classList.toggle('guide-controls', !browsing && !!scenarioID);
  document.getElementById('traces').hidden = browsing || !!scenarioID;
  document.getElementById('scenario-strip').hidden = browsing || !scenarioID;
  document.getElementById('show-scenarios').setAttribute('aria-pressed', String(browsing));
  document.getElementById('show-map').setAttribute('aria-pressed', String(!browsing));
  document.getElementById('show-map').textContent = scenarioID ? 'Back to walkthrough' : 'Architecture map';
  document.querySelector('footer').hidden = browsing;
  document.getElementById('view-context').textContent = browsing ? 'Scenario conditions, processing stages, and source references.' : scenarioID ? 'Read / consume · Write / produce · Check / gate. Select an object to inspect it.' : 'Nested containers, functional groups, and one relationship at a time.';
}
function updateAddress() {
  const hash = scenarioID ? '#scenario=' + scenarioID + '&step=' + (stepIndex + 1) : '';
  try { history.replaceState(null, '', location.pathname + location.search + hash); }
  catch { /* Keep guide navigation available in embedded previews with fixed document URLs. */ }
}
function showLibrary() {
  browsing = true; inspector.hidden = true; document.getElementById('connection').hidden = true;
  updateView(); renderCatalog();
}
function showMap() {
  browsing = false; updateView();
  if (scenarioID) showWalkthrough(true); else { inspector.hidden = true; apply(); fit('width'); }
}
function startScenario(id, index = progress.get(id) || 0) {
  scenarioID = id; stepIndex = Math.max(0, Math.min(byScenario.get(id).steps.length - 1, index)); browsing = false;
  updateView(); showWalkthrough(true); updateAddress();
}
function exitScenario() {
  scenarioID = null; clearState(); inspector.hidden = true; browsing = false; updateView(); apply(); fit('width'); updateAddress();
}
function moveStep(index) {
  if (!scenarioID) return;
  stepIndex = Math.max(0, Math.min(byScenario.get(scenarioID).steps.length - 1, index));
  showWalkthrough(true); updateAddress();
}
function showWalkthrough(move = false) {
  if (!scenarioID) return;
  clearState(); const s = byScenario.get(scenarioID), step = currentStep(), category = byCategory.get(s.category);
  progress.set(s.id, stepIndex); apply();
  document.getElementById('walkthrough-label').textContent = s.title;
  document.getElementById('walkthrough-status').textContent = 'Step ' + (stepIndex + 1) + ' of ' + s.steps.length + ' · ' + step.actor;
  document.getElementById('strip-prev').disabled = stepIndex === 0;
  document.getElementById('strip-next').disabled = stepIndex === s.steps.length - 1;
  document.getElementById('close').setAttribute('aria-label', 'Exit walkthrough');
  showPanel('<div class="eyebrow">' + safe(category.title) + ' · specified scenario</div><h2 id="walkthrough-title">' + safe(s.title) + '</h2>' +
    '<h4>Initial conditions</h4><p class="scenario-setup">' + safe(s.setup) + '</p><details class="scenario-context"><summary>Expected outcome</summary><p>' + safe(s.outcome) + '</p></details>' +
    '<ol class="step-rail" aria-label="Walkthrough steps">' + s.steps.map((item, i) => '<li><button data-walk-step="' + i + '" ' + (i === stepIndex ? 'aria-current="step"' : '') + '><span>' + (i + 1) + '</span>' + safe(item.title) + '</button></li>').join('') + '</ol>' +
    '<section class="walkthrough-step"><div class="eyebrow">' + safe(step.actor) + ' · step ' + (stepIndex + 1) + '</div><h3 data-step-title tabindex="-1">' + safe(step.title) + '</h3>' +
    '<div class="user-result"><strong>Observable state</strong><p>' + safe(step.user) + '</p></div><h4>Storage operation</h4><p>' + safe(step.operation) + '</p>' +
    '<div class="step-objects"><div class="objects-heading"><h4>Objects in this step</h4><button data-fit-step>Fit step</button></div><p class="hint">Select an object to inspect it and jump to its location.</p>' +
    ['read', 'write', 'guard'].filter(role => step.roles[role]?.length).map(role => '<div class="role-group role-' + role + '"><strong>' + roleNames[role] + '</strong><div>' + step.roles[role].map(objectButton).join('') + '</div></div>').join('') + '</div>' +
    (step.edges.length ? '<details><summary>Relationships in this step</summary>' + step.edges.map(id => operationButton(byEdge.get(id), byEdge.get(id).source)).join('') + '</details>' : '') +
    '<div class="guarantee"><strong>Applicable rule</strong><p>' + safe(step.rule) + '</p></div></section>' +
    '<div class="scenario-evidence"><h4>Requirements</h4><div class="evidence-chips">' + evidenceChips(s.requirements, byRequirement) + '</div><h4>Test contracts</h4><div class="evidence-chips contract-chips">' + evidenceChips(s.contracts, byContract) + '</div>' + (s.contractNote ? '<p class="contract-note">' + safe(s.contractNote) + '</p>' : '') +
    '<details><summary>Design and test-contract references</summary><ul class="contract-list">' + s.contracts.map(id => '<li>' + sourceLink(byContract.get(id), id) + '<span>' + safe(plain(byContract.get(id).title)) + '</span></li>').join('') + '</ul><ul class="design-links">' + s.sources.map(id => { const ref = catalog.references[id]; return '<li>' + sourceLink(ref) + '<small>' + safe(ref.path) + '</small></li>'; }).join('') + '</ul></details></div>' +
    (stepIndex === s.steps.length - 1 ? '<div class="walkthrough-outcome"><strong>Expected outcome</strong><p>' + safe(s.outcome) + '</p><h4>Related scenarios</h4>' + s.related.map(id => '<button class="related-scenario" data-scenario="' + id + '">' + safe(byScenario.get(id).title) + ' →</button>').join('') + '</div>' : '') +
    '<div class="step-navigation"><button data-prev-step ' + (stepIndex === 0 ? 'disabled' : '') + '>← Previous</button><span>' + (stepIndex + 1) + ' / ' + s.steps.length + '</span><button data-next-step ' + (stepIndex === s.steps.length - 1 ? 'disabled' : '') + '>Next →</button></div>');
  if (move) { goToObject(step.focus); details.querySelector('[data-step-title]')?.focus({preventScroll: true}); }
}
function scenarioText(s) {
  const objects = [...new Set(s.steps.flatMap(step => Object.values(step.roles).flat()))].map(id => byID.get(id));
  return [s.title, s.summary, s.setup, s.outcome, ...s.requirements, ...s.contracts, ...s.steps.flatMap(step => [step.title, step.user, step.operation, step.rule]), ...objects.flatMap(n => [n.id, n.title, ...n.members, ...n.tables])].join(' ').toLowerCase();
}
const scenarioSearchText = new Map(catalog.scenarios.map(s => [s.id, scenarioText(s)]));
function matchingScenarios() {
  const words = scenarioQuery.trim().toLowerCase().split(/\s+/).filter(Boolean);
  return catalog.scenarios.filter(s => (!categoryFilter || s.category === categoryFilter) && (!requirementFilter || s.requirements.includes(requirementFilter)) && words.every(word => scenarioSearchText.get(s.id).includes(word)));
}
function scenarioCard(s) {
  const saved = progress.get(s.id);
  return '<article class="scenario-card"><button class="scenario-open" data-scenario="' + s.id + '"><span class="card-kicker">' + safe(byCategory.get(s.category).title) + '</span><h4>' + safe(s.title) + '</h4><p>' + safe(s.summary) + '</p><span class="card-action">' + (saved > 0 ? 'Resume at step ' + (saved + 1) : 'Open walkthrough') + ' <span>→</span></span></button><div class="card-evidence"><span>Requirements</span><div class="evidence-chips">' + evidenceChips(s.requirements, byRequirement) + '</div><span>Test contracts</span><div class="evidence-chips contract-chips">' + evidenceChips(s.contracts, byContract) + '</div></div></article>';
}
function renderCatalog() {
  const matches = matchingScenarios(), filtered = !!(categoryFilter || requirementFilter || scenarioQuery.trim());
  document.getElementById('scenario-count').textContent = matches.length + ' of ' + catalog.scenarios.length + ' scenarios';
  document.getElementById('scenario-categories').innerHTML = '<button data-category="" aria-pressed="' + !categoryFilter + '">All scenarios <span>' + catalog.scenarios.length + '</span></button>' + catalog.categories.map(c => '<button data-category="' + c.id + '" aria-pressed="' + (categoryFilter === c.id) + '">' + safe(c.title) + ' <span>' + catalog.scenarios.filter(s => s.category === c.id).length + '</span></button>').join('');
  let content = '';
  if (!filtered) content += '<section class="scenario-section featured-section"><div class="section-heading"><div><div class="eyebrow">Overview</div><h3>Representative scenarios</h3></div><p>Local save/startup, merge, compensation, external import, and store repair. Each walkthrough uses the same object locations.</p></div><div class="scenario-grid">' + catalog.scenarios.filter(s => s.featured).slice(0, 6).map(scenarioCard).join('') + '</div></section>';
  for (const category of catalog.categories) {
    const group = matches.filter(s => s.category === category.id);
    if (!group.length) continue;
    content += '<section class="scenario-section"><div class="section-heading"><div><div class="eyebrow">' + group.length + ' ' + (group.length === 1 ? 'scenario' : 'scenarios') + '</div><h3>' + safe(category.title) + '</h3></div><p>' + safe(category.description) + '</p></div><div class="scenario-grid">' + group.map(scenarioCard).join('') + '</div></section>';
  }
  if (!matches.length) content = '<div class="no-scenarios"><h3>No matching scenarios</h3><p>Search accepts scenario text, object names, requirement IDs (DUR-01), and test-contract IDs (TC-IMPORT-01).</p><button data-clear-filters>Clear filters</button></div>';
  document.getElementById('scenario-results').innerHTML = content;
}
function clearScenarioFilters() {
  scenarioQuery = ''; categoryFilter = ''; requirementFilter = '';
  document.getElementById('scenario-search').value = ''; document.getElementById('scenario-requirement').value = '';
  renderCatalog();
}

for (const n of model.nodes) {
  const el = document.getElementById('node-' + n.id);
  el.setAttribute('tabindex', '0'); el.setAttribute('role', 'button');
  el.addEventListener('click', ev => { ev.stopPropagation(); selectObject(n.id); });
  el.addEventListener('dblclick', ev => { ev.stopPropagation(); selectObject(n.id, true); });
  el.addEventListener('keydown', ev => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); selectObject(n.id, true); } });
}
for (const trace of presentation.traces) {
  const button = document.createElement('button'); button.dataset.trace = trace.id; button.textContent = trace.short;
  button.addEventListener('click', () => selectTrace(trace.id)); document.getElementById('traces').append(button);
}
svg.querySelectorAll('[data-trace]').forEach(el => { el.style.display = 'none'; el.setAttribute('aria-hidden', 'true'); });
for (const feature of model.features) { const option = document.createElement('option'); option.value = feature.id; option.textContent = feature.label; document.getElementById('feature').append(option); }
for (const req of catalog.requirements) { const option = document.createElement('option'); option.value = req.id; option.textContent = req.id + ' · ' + plain(req.title).slice(0, 95); document.getElementById('scenario-requirement').append(option); }
details.addEventListener('click', ev => {
  const target = ev.target;
  if (target.closest('[data-return-step]')) { showWalkthrough(true); return; }
  if (target.closest('[data-prev-step]')) { moveStep(stepIndex - 1); return; }
  if (target.closest('[data-next-step]')) { moveStep(stepIndex + 1); return; }
  if (target.closest('[data-fit-step]')) { fitStep(); return; }
  const walkStep = target.closest('[data-walk-step]'), scenario = target.closest('[data-scenario]'), object = target.closest('[data-object]'), edge = target.closest('[data-edge]');
  if (walkStep) moveStep(Number(walkStep.dataset.walkStep)); else if (scenario) startScenario(scenario.dataset.scenario); else if (object) selectObject(object.dataset.object, true); else if (edge) selectEdge(edge.dataset.edge);
});
library.addEventListener('click', ev => { const scenario = ev.target.closest('[data-scenario]'); if (scenario) startScenario(scenario.dataset.scenario); if (ev.target.closest('[data-clear-filters]')) clearScenarioFilters(); });
document.getElementById('scenario-categories').addEventListener('click', ev => { const button = ev.target.closest('[data-category]'); if (button) { categoryFilter = button.dataset.category; renderCatalog(); } });
document.getElementById('scenario-search').addEventListener('input', ev => { scenarioQuery = ev.target.value; renderCatalog(); });
document.getElementById('scenario-requirement').addEventListener('change', ev => { requirementFilter = ev.target.value; renderCatalog(); });
document.getElementById('clear-scenario-filters').addEventListener('click', clearScenarioFilters);
document.getElementById('show-scenarios').addEventListener('click', showLibrary);
document.getElementById('back-library').addEventListener('click', showLibrary);
document.getElementById('show-map').addEventListener('click', showMap);
document.getElementById('return-step').addEventListener('click', () => showWalkthrough(true));
document.getElementById('strip-prev').addEventListener('click', () => moveStep(stepIndex - 1));
document.getElementById('strip-next').addEventListener('click', () => moveStep(stepIndex + 1));
document.getElementById('exit-walkthrough').addEventListener('click', exitScenario);
document.getElementById('feature').addEventListener('change', ev => { const value = ev.target.value; clearState(); feature = value || null; const active = apply(); if (feature) resultPanel(active, model.features.find(f => f.id === feature).label, 'Feature group'); else reset(); });
document.getElementById('search').addEventListener('input', ev => { const value = ev.target.value; clearState(); query = value.trim().toLowerCase(); ev.target.value = value; const active = apply(); if (query) resultPanel(active, 'Search results', 'Object / record / SQL table'); else reset(); });
document.getElementById('fit-width').addEventListener('click', () => fit('width'));
document.getElementById('fit-all').addEventListener('click', () => fit('all'));
document.getElementById('plus').addEventListener('click', () => { fitted = null; setZoom(zoom * 1.2); });
document.getElementById('minus').addEventListener('click', () => { fitted = null; setZoom(zoom / 1.2); });
document.getElementById('reset').addEventListener('click', reset);
document.getElementById('close').addEventListener('click', () => { if (scenarioID && !(selected || edgeID || feature || query || traceID)) exitScenario(); else reset(); });
document.addEventListener('keydown', ev => {
  if (ev.key === 'Escape') { if (!browsing) { if (scenarioID && !(selected || edgeID || feature || query || traceID)) showLibrary(); else reset(); } return; }
  if (!browsing && scenarioID && !ev.ctrlKey && !ev.metaKey && !ev.altKey && !ev.target.closest('input,select,textarea,[contenteditable]')) {
    if (ev.key === 'ArrowRight' || ev.key === 'ArrowLeft') { ev.preventDefault(); moveStep(stepIndex + (ev.key === 'ArrowRight' ? 1 : -1)); }
  }
});
canvas.addEventListener('wheel', ev => { if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); fitted = null; setZoom(zoom * (ev.deltaY > 0 ? .93 : 1.07)); } }, {passive: false});
new ResizeObserver(() => { if (!browsing && fitted) fit(fitted); }).observe(canvas);
function readAddress() {
  const params = new URLSearchParams(location.hash.slice(1)), id = params.get('scenario');
  if (byScenario.has(id)) { const value = Number(params.get('step')); startScenario(id, Number.isFinite(value) ? Math.trunc(value) - 1 : 0); }
  else { scenarioID = null; clearState(); apply(); showLibrary(); }
}
window.addEventListener('hashchange', readAddress);
apply(); renderCatalog(); updateView(); fit('width'); readAddress();
