import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { validateHierarchy, createNestedSVG, createHTML, createHierarchyDOT } from './nested-object-map.mjs';
import { prepareScenarios } from './scenario-catalog.mjs';

// Render the same object inventory as a standalone SVG, interactive HTML and source index.
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../..');
const input = path.join(here, 'nvstorage-object-map.json');
const data = JSON.parse(await fs.readFile(input, 'utf8'));
const layout = JSON.parse(await fs.readFile(path.join(here, 'nvstorage-object-map.layout.json'), 'utf8'));
const hierarchyCheck = validateHierarchy(data, layout);
const scenarioText = await fs.readFile(path.join(here, 'nvstorage-scenarios.json'), 'utf8');
const relative = p => path.relative(here, path.join(root, p)).split(path.sep).join('/');
const colors = {
  required: ['#fff5df','#a56516'], portable: ['#f2ecff','#7553af'], indexed: ['#fff5df','#a56516'],
  derived: ['#e6f7ef','#247257'], external: ['#f1f3f7','#667386'],
  memory: ['#eaf3ff','#366da9'], authority: ['#eef0f7','#596181']
};
const edgeColors = {derive:'#2e6da4',commit:'#ac6b1c',copy:'#7850ad',reference:'#6f7b89',guard:'#667186'};

async function markdownFiles(directory) {
  const entries = await fs.readdir(path.join(root,directory),{withFileTypes:true});
  const result = [];
  for (const entry of entries.sort((a,b)=>a.name.localeCompare(b.name))) {
    const p = directory + '/' + entry.name;
    if (entry.isDirectory() && entry.name !== 'diagrams') result.push(...await markdownFiles(p));
    else if (entry.isFile() && p.endsWith('.md') && entry.name !== 'NVStorage-Object-Map.md') result.push(p);
  }
  return result;
}
const corpus = ['CONTEXT.md','docs/iCloud-Drive-Support-Spec.md','docs/Apple-API-Contract-Validation.md',
  'docs/Foundation-Safe-Replacement-Migration.md', ...await markdownFiles('docs/adr'),
  ...await markdownFiles('docs/impl-proposal-5'),'docs/tla/README.md','docs/tla/Proposal5-Coverage.md'];
const sources = [];
for (const p of corpus) {
  const text = await fs.readFile(path.join(root,p),'utf8');
  sources.push({path:p,title:text.split('\n')[0].replace(/^#+\s*/,''),
    sha256:crypto.createHash('sha256').update(text).digest('hex'),lines:text.trimEnd().split('\n').length});
}

const ids = new Set(data.nodes.map(n=>n.id));
const featureIDs = new Set(data.features.map(f=>f.id));
const laneIDs = new Set(data.lanes.map(l=>l.id));
if (ids.size !== data.nodes.length) throw Error('Duplicate object ID');
if (new Set(data.edges.map(e=>e.id)).size !== data.edges.length) throw Error('Duplicate relationship ID');
for (const n of data.nodes) {
  if (!laneIDs.has(n.lane) || !colors[n.kind] || !n.members.length || !n.purpose) throw Error('Incomplete object '+n.id);
  for (const f of n.features) if (!featureIDs.has(f)) throw Error('Unknown feature '+f);
  for (const s of n.sources) if (!corpus.includes(s)) throw Error('Source outside reviewed corpus: '+s);
}
for (const e of data.edges) {
  if (!ids.has(e.source) || !ids.has(e.target) || !edgeColors[e.kind] || !e.operation) throw Error('Incomplete edge '+e.id);
  for (const f of e.features) if (!featureIDs.has(f)) throw Error('Unknown edge feature '+f);
}
const ddl = await fs.readFile(path.join(root,'NVStorage/Sources/NVStorageRuntime/Resources/SchemaV1.sql'),'utf8');
const tables = [...ddl.matchAll(/CREATE TABLE (\w+)/g)].map(m=>m[1]);
const coveredTables = data.nodes.flatMap(n=>n.tables);
if (new Set(coveredTables).size !== coveredTables.length) throw Error('SQL table assigned more than once');
for (const t of tables) if (!coveredTables.includes(t)) throw Error('Unmapped SQL table '+t);
for (const t of coveredTables) if (!tables.includes(t)) throw Error('Unknown SQL table '+t);
for (const n of data.nodes) if (!data.edges.some(e=>e.source===n.id || e.target===n.id)) throw Error('Disconnected object '+n.id);
const scenarios = await prepareScenarios(JSON.parse(scenarioText), data, corpus, root, relative);
data.scenarioCatalog = scenarios.catalog;

// The hierarchy and operation inventory share one stable geometry across outputs.
data.sourceCount=sources.length;
data.nodes=data.nodes.map(n=>({...n,sourceLinks:n.sources.map(p=>({path:p,href:relative(p)}))}));
const rendered=createNestedSVG(data,layout), svg=rendered.svg;
const [css,viewer]=await Promise.all([
  fs.readFile(path.join(here,'object-map-viewer.css'),'utf8'),
  fs.readFile(path.join(here,'object-map-viewer.js'),'utf8')
]);
const html=createHTML(data,layout,rendered,css,viewer);
const outputs=new Map([
  [path.join(here,'nvstorage-object-map.svg'),svg],
  [path.join(here,'nvstorage-object-map.html'),html],
  [path.join(here,'nvstorage-object-map.dot'),createHierarchyDOT(data,layout)]
]);
outputs.set(path.join(here,'nvstorage-object-map.sources.json'),JSON.stringify({captured:data.date,authority:'Normative specification and annexes, ADRs, glossary, current proposal/plan corpus, conditional Apple/replacement contracts and TLA coverage boundaries.',sources,
  schema:{path:'NVStorage/Sources/NVStorageRuntime/Resources/SchemaV1.sql',sha256:crypto.createHash('sha256').update(ddl).digest('hex'),tables},
  scenarioCatalog:{path:'docs/impl-proposal-5/diagrams/nvstorage-scenarios.json',sha256:crypto.createHash('sha256').update(scenarioText).digest('hex'),...scenarios.check}},null,2)+'\n');

const mdLink = p => '['+path.basename(p)+']('+path.relative(path.join(root,'docs/impl-proposal-5'),path.join(root,p)).split(path.sep).join('/')+')';
let md='# NVStorage unified object map\n\nDate: '+data.date+'. Explanatory architecture inventory of the adopted segment-collection design. The normative specification, algorithm/wire annexes, ADRs and vocabulary retain their authority. The diagram includes documented Core, Runtime and Apple work alongside planned projection/application consumers, with implementation and qualification boundaries marked.\n\n'+
  '[Scenario reference and interactive map](diagrams/nvstorage-object-map.html) · [Scenario document](diagrams/NVStorage-Scenarios.md) · [Full-size SVG](diagrams/nvstorage-object-map.svg) · [Object inventory](diagrams/nvstorage-object-map.json) · [Editable hierarchy and traces](diagrams/nvstorage-object-map.layout.json)\n\n'+
  'The inventory contains '+data.nodes.length+' object groups, '+data.edges.length+' labeled operations/relationships, and all '+tables.length+' current private SQL tables. Containment represents process, directory and file boundaries; subheadings identify functional groups. The live in-memory session, private SQL store and provider repository have distinct responsibilities and boundaries.\n\n'+
  'The scenario index contains '+scenarios.check.scenarios+' cases in '+scenarios.check.scenarioCategories+' categories. Each case records initial conditions and an expected outcome, followed by three processing stages with observable state, storage operations and applicable rules. The map highlights objects read/consumed, written/produced, and checked as gates for the selected stage. Object controls open the corresponding inventory details and retain a return path to that stage. Previous/Next, numbered steps and Left/Right keys navigate. Search covers scenario text, object names, requirement IDs and test-contract IDs; the requirement filter covers all '+scenarios.check.linkedRequirements+' registry entries. References link each case to source sections and named conformance contracts. Implementation and platform qualification are recorded in the linked plans and reports.\n\n'+
  'The architecture-map view emphasizes structure. All SQL roles are nested inside `Collection.sqlite`; pager sidecars are siblings in its database-file bundle. Private unlock copies are outside that bundle, and the selected-store record sits outside either active or replacement store. Repository descriptors and segment objects sit inside the `NV Data/v1` hierarchy. Snapshot root/page families share the segment namespace. Apple unresolved-version evidence sits outside the physical repository boundary as associated OS state.\n\n'+
  'Functional groups say **Feature group**, **Operation values**, **Logical roles**, or **Session resources**. These express similarity and purpose. The enclosing process/directory/file/bundle labels establish physical or lifetime containment. Recovery/output locations have their own explicitly associated boundaries.\n\n'+
  'Choose an operation trace to highlight its objects and show numbered stages in their existing locations. The trace panel explains what derives or commits each stage and exposes its exact relationships. Clicking one relationship draws that connector alone; clicking a card shows its members, incoming/outgoing operations, features and source contracts. Feature highlighting and object/SQL search preserve the same hierarchy. The interactive view initially fits the map width and scrolls vertically; zoom and whole-map controls support broader inspection.\n\n'+
  'During use, the complete live note store is authoritative and search is synchronous. The save route freezes admitted generations, seals exact bytes, validates complete groups, and atomically retains history/acceptance/pin/wakeups. The receive route retains incoming bytes first, waits for the appropriate byte/history requirements, validates and accepts, then prepares generation-fenced reduction. These routes join at accepted history, whose durability precedes external effects.\n\n'+
  'Private current rows/context accelerate reopening through an exact accepted prefix. Provider snapshots describe a verified logical operation cut; general v1 retention-parent links cover object closures independently. Recovery includes every accepted outside-cut action. Both representations retain their own validation and final-publication checks.\n\n'+
  'Operation causal parents, note predecessors, action scope parents, compensation targets, and snapshot retention parents answer separate questions. A pin, stamp, receipt, decoded ID, upload status, and physical permission also have distinct issuing and consuming boundaries.\n\n'+
  'The source corpus contains '+sources.length+' specification, annex, ADR, plan, validation and coverage documents, including working-tree updates and planned work. The [source manifest](diagrams/nvstorage-object-map.sources.json) records every path and SHA-256 at generation. Current adopted contracts govern where earlier experimental reports describe a discarded alternative. Test fixtures, compiler probes and benchmark-only synthetic objects are evidence; scalar ID wrappers, codec cursors and allocation buffers are grouped with their owning records/jobs. The same map applies independently on each Mac.\n\n'+
  '![Nested NVStorage object diagram](diagrams/nvstorage-object-map.svg)\n\n'+
  'Feature letters: '+data.features.map(f=>'**'+f.id+'** '+f.label).join('; ')+'.\n\n';
md+='## Scenario reference\n\n[Scenario descriptions and source references](diagrams/NVStorage-Scenarios.md). The following links open individual walkthroughs:\n\n';
for(const category of scenarios.catalog.categories){
  md+='### '+category.title+'\n\n'+category.description+'\n\n';
  for(const s of scenarios.catalog.scenarios.filter(s=>s.category===category.id))md+='- ['+s.title+'](diagrams/nvstorage-object-map.html#scenario='+s.id+'&step=1) — '+s.summary+'\n';
  md+='\n';
}
md+='## Operation traces\n\n';
for(const trace of layout.traces){
  md+='### '+trace.title+'\n\n'+trace.description+'\n\n';
  trace.stages.forEach((stage,i)=>{md+=(i+1)+'. **'+stage.title+'.** '+stage.detail+' Objects: '+stage.nodes.map(id=>'`'+id+'`').join(', ')+'.\n';});
  md+='\n';
}
md+='## Nested object inventory\n\nThe following inventory follows the diagram hierarchy. Each object appears once; its container path distinguishes physical nesting from the labeled functional groups.\n\n';
function writeObject(id,depth,parents){
  const n=data.nodes.find(n=>n.id===id);
  md+='#'.repeat(Math.min(depth,6))+' '+n.id+' — '+n.title+'\n\n**'+data.kinds[n.kind]+'** · Features '+n.features.join(', ')+'.\n\n';
  md+='Container / grouping path: '+parents.join(' › ')+'.\n\n'+n.purpose+'\n\n';
  md+=n.members.map(m=>'- '+m).join('\n')+'\n\n';
  if(n.tables.length)md+='SQL tables: '+n.tables.map(t=>'`'+t+'`').join(', ')+'.\n\n';
  md+='Boundary: '+n.status+'\n\nSources: '+n.sources.map(mdLink).join(', ')+'.\n\n';
}
function writeGroup(item,depth=3,parents=[]){
  if(item.children){
    if(item.title)md+='#'.repeat(Math.min(depth,6))+' '+item.title+'\n\n'+item.caption+'.\n\n';
    if(item.object)writeObject(item.object,depth+1,parents);
    const path=item.title?[...parents,item.title]:parents;
    for(const child of item.children)writeGroup(child,item.bare?depth:depth+1,path);
  }else writeObject(item.object,depth,parents);
}
writeGroup(layout.tree);
md+='## Earlier alternatives and deferred objects\n\n| Object family | Current disposition | Reason / source |\n| --- | --- | --- |\n';
for(const x of data.excluded)md+='| '+x.name+' | '+x.state+' | '+x.reason+' '+mdLink(x.source)+' |\n';
md+='\n## Regeneration and consistency checks\n\nThe renderer validates object/edge IDs, feature references, source paths, connectivity, unique hierarchy placement, lifetime boundaries, trace references, and complete one-owner mapping of the production SQL tables. Scenario checks resolve actual Markdown headings and requirement/test rows, validate every object/operation/related-story reference, and require scenario coverage of the full normative requirement registry. The hierarchy, SVG and HTML share one geometry. `--check` compares all six saved artifacts with freshly rendered content and reports stale or missing outputs without writing files. Generation uses Node built-ins; the saved HTML/SVG are standalone and use embedded resources. From the repository root:\n\n```sh\nnode docs/impl-proposal-5/diagrams/render-object-map.mjs\nnode docs/impl-proposal-5/diagrams/render-object-map.mjs --check\n```\n\nEdit `nvstorage-object-map.json` for records/relationships, `nvstorage-object-map.layout.json` for nesting/display/traces, and `nvstorage-scenarios.json` for scenario cards/steps/evidence. `scenario-catalog.mjs` validates and resolves their evidence links. `nested-object-map.mjs` renders the shared geometry; `object-map-viewer.js` and `.css` supply embedded controls. The [DOT export](diagrams/nvstorage-object-map.dot) retains the hierarchy and all relationships for external tooling. Product/model verification remains governed by the cited contracts.\n';
outputs.set(path.join(root,'docs/impl-proposal-5/NVStorage-Object-Map.md'),md);
const reqByID=new Map(scenarios.catalog.requirements.map(r=>[r.id,r])), tcByID=new Map(scenarios.catalog.contracts.map(c=>[c.id,c]));
const evidenceLink=r=>'['+r.id+']('+r.href+')';
let guide='# NVStorage scenario reference\n\n[Interactive scenario reference](nvstorage-object-map.html) · [Architecture inventory](../NVStorage-Object-Map.md)\n\n'+scenarios.catalog.scope+' Example names and values instantiate the cited requirements. Each diagram represents one Mac; the participant label identifies the Mac or external actor involved at that stage. Read/write labels record conceptual inputs and outputs. Transaction boundaries are specified in the operations and their references.\n\n';
for(const category of scenarios.catalog.categories){
  guide+='## '+category.title+'\n\n'+category.description+'\n\n';
  for(const s of scenarios.catalog.scenarios.filter(s=>s.category===category.id)){
    guide+='### '+s.title+'\n\n[Open walkthrough](nvstorage-object-map.html#scenario='+s.id+'&step=1)\n\n'+s.summary+'\n\n**Initial conditions.** '+s.setup+'\n\n**Expected outcome.** '+s.outcome+'\n\n';
    s.steps.forEach((step,i)=>{
      guide+=(i+1)+'. **'+step.title+'** ('+step.actor+').\n\n   Observable state: '+step.user+'\n\n   Storage operation: '+step.operation+'\n\n   Applicable rule: '+step.rule+'\n\n';
      for(const [role,values] of Object.entries(step.roles))guide+='   '+({read:'Read / consume',write:'Write / produce',guard:'Check / gate'}[role])+': '+values.map(id=>'`'+id+'`').join(', ')+'.\n\n';
    });
    guide+='Requirements: '+s.requirements.map(id=>evidenceLink(reqByID.get(id))).join(', ')+'.\n\nTest contracts:\n\n'+s.contracts.map(id=>{const c=tcByID.get(id);return '- '+evidenceLink(c)+' — '+c.title;}).join('\n')+'\n\n'+(s.contractNote?s.contractNote+'\n\n':'')+'Design / plans:\n\n'+s.sources.map(id=>{const r=scenarios.catalog.references[id];return '- ['+r.section+']('+r.href+') — '+path.basename(r.path);}).join('\n')+'\n\n';
  }
}
guide+='## Requirement coverage\n\nEvery normative registry entry has at least one linked scenario. This is explanatory coverage; actual qualification evidence is tracked by the conformance strategy and validation reports.\n\n';
for(const r of scenarios.catalog.requirements)guide+='- '+evidenceLink(r)+' — '+scenarios.catalog.coverage[r.id].map(id=>'['+scenarios.catalog.scenarios.find(s=>s.id===id).title+'](nvstorage-object-map.html#scenario='+id+'&step=1)').join('; ')+'.\n';
outputs.set(path.join(here,'NVStorage-Scenarios.md'),guide);
const checking=process.argv.includes('--check');
if(checking){
  const stale=[];
  for(const [file,expected] of outputs){
    try{if(await fs.readFile(file,'utf8')!==expected)stale.push(path.relative(root,file));}
    catch(error){if(error.code==='ENOENT')stale.push(path.relative(root,file));else throw error;}
  }
  if(stale.length){
    console.error('Stale or missing diagram artifacts:\n'+stale.map(p=>'  '+p).join('\n')+'\nRun node docs/impl-proposal-5/diagrams/render-object-map.mjs to regenerate.');
    process.exitCode=1;
  }
}else{
  for(const [file,content] of outputs)await fs.writeFile(file,content);
}
console.log(JSON.stringify({objectGroups:data.nodes.length,relationships:data.edges.length,sqlTables:tables.length,sourceDocuments:sources.length,...hierarchyCheck,...scenarios.check,svgBytes:svg.length,htmlBytes:html.length,...(checking?{artifactsChecked:outputs.size}:{artifactsWritten:outputs.size})}));
