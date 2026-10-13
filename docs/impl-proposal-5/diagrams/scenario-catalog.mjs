import fs from 'node:fs/promises';
import path from 'node:path';

// Resolve scenario evidence against actual headings and named requirement/test rows.
export async function prepareScenarios(catalog, data, corpus, root, relative) {
  const texts = new Map();
  async function read(file) {
    if (!corpus.includes(file)) throw Error('Scenario source outside reviewed corpus: ' + file);
    if (!texts.has(file)) texts.set(file, await fs.readFile(path.join(root, file), 'utf8'));
    return texts.get(file);
  }
  const slug = heading => heading.toLowerCase().replace(/<[^>]*>/g, '').replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/ /g, '-');
  function headings(text) {
    const seen = new Map(), result = [];
    text.split('\n').forEach((line, i) => {
      const match = line.match(/^#{1,6}\s+(.+?)(?:\s+#+)?$/);
      if (!match) return;
      const section = match[1], base = slug(section), occurrence = seen.get(base) || 0;
      seen.set(base, occurrence + 1);
      result.push({section, anchor: base + (occurrence ? '-' + occurrence : ''), line: i + 1});
    });
    return result;
  }
  async function reference(ref) {
    const match = headings(await read(ref.path)).find(h => h.section === ref.section);
    if (!match) throw Error('Missing scenario source heading: ' + ref.path + ' / ' + ref.section);
    return {...ref, ...match, href: relative(ref.path) + '#' + match.anchor};
  }
  const specPath = 'docs/iCloud-Drive-Support-Spec.md';
  const testPath = 'docs/impl-proposal-5/plan/swift-storage-conformance-testing-strategy.md';
  const spec = await read(specPath), tests = await read(testPath);
  const registry = await reference({path: specPath, section: 'Normative requirement registry'});
  const backlog = await reference({path: testPath, section: '9. Remaining scenario backlog and caller coverage'});
  const requirements = [...spec.matchAll(/^\| ([A-Z]+-\d+) \| (.+) \|$/gm)].map(m => ({id: m[1], title: m[2], ...registry}));
  const contracts = [];
  for (const h of headings(tests)) {
    const match = h.section.match(/^(TC-[A-Z]+-\d+) — (.+)$/);
    if (match) contracts.push({id: match[1], title: match[2], path: testPath, ...h, href: relative(testPath) + '#' + h.anchor});
  }
  tests.split('\n').forEach((line, i) => {
    const match = line.match(/^\| (TC-[A-Z]+-\d+) \/ ([^|]+) \| ([^|]+) \| (.+) \|$/);
    if (match && !contracts.some(c => c.id === match[1])) contracts.push({id: match[1], title: match[3].trim(), expectation: match[4].trim(), gate: match[2].trim(), ...backlog, line: i + 1});
  });
  const references = {};
  for (const [id, ref] of Object.entries(catalog.references)) references[id] = await reference(ref);
  const nodes = new Set(data.nodes.map(n => n.id)), edges = new Map(data.edges.map(e => [e.id, e]));
  const cats = new Set(catalog.categories.map(c => c.id)), ids = new Set(catalog.scenarios.map(s => s.id));
  const reqs = new Set(requirements.map(r => r.id)), tcs = new Set(contracts.map(c => c.id));
  if (catalog.version !== 1 || !catalog.scope || cats.size !== catalog.categories.length || ids.size !== catalog.scenarios.length) throw Error('Invalid scenario catalog identity');
  const coverage = Object.fromEntries(requirements.map(r => [r.id, []]));
  const usedContracts = new Set(), usedNodes = new Set();
  for (const s of catalog.scenarios) {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(s.id) || !cats.has(s.category) || !s.title || !s.summary || !s.setup || !s.outcome || s.steps.length < 3 || !s.requirements.length || !s.contracts.length || !s.sources.length) throw Error('Incomplete scenario: ' + s.id);
    for (const id of s.requirements) {
      if (!reqs.has(id)) throw Error('Unknown requirement ' + id + ' in ' + s.id);
      coverage[id].push(s.id);
    }
    for (const id of s.contracts) {
      if (!tcs.has(id)) throw Error('Unknown test contract ' + id + ' in ' + s.id);
      usedContracts.add(id);
    }
    for (const id of s.sources) if (!references[id]) throw Error('Unknown scenario source ' + id);
    for (const id of s.related) if (!ids.has(id) || id === s.id) throw Error('Unknown/self related scenario ' + id);
    for (const [i, step] of s.steps.entries()) {
      const roles = Object.entries(step.roles), active = new Set(roles.flatMap(([, values]) => values));
      if (!step.title || !step.actor || !step.user || !step.operation || !step.rule || !active.size || !active.has(step.focus)) throw Error('Incomplete scenario step ' + s.id + ':' + (i + 1));
      for (const [role, values] of roles) {
        if (!['read', 'write', 'guard'].includes(role) || new Set(values).size !== values.length) throw Error('Invalid scenario role ' + s.id + ':' + role);
        for (const id of values) {
          if (!nodes.has(id)) throw Error('Unknown scenario object ' + id);
          usedNodes.add(id);
        }
      }
      for (const id of step.edges) {
        const edge = edges.get(id);
        if (!edge || !active.has(edge.source) || !active.has(edge.target)) throw Error('Step relationship outside highlighted objects ' + s.id + ':' + id);
      }
    }
  }
  const uncovered = Object.entries(coverage).filter(([, values]) => !values.length).map(([id]) => id);
  if (uncovered.length) throw Error('Requirements without a scenario: ' + uncovered.join(', '));
  return {
    catalog: {...catalog, references, requirements, contracts: contracts.filter(c => usedContracts.has(c.id)), coverage},
    check: {scenarios: ids.size, scenarioSteps: catalog.scenarios.reduce((sum, s) => sum + s.steps.length, 0), scenarioCategories: cats.size, linkedRequirements: reqs.size, linkedTestContracts: usedContracts.size, scenarioObjects: usedNodes.size, checkedScenarioSourceHeadings: Object.keys(references).length + 2}
  };
}
