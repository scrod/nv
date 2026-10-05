// Independent wire/SQL oracle for the synthetic process-probe repositories.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash, createDecipheriv, hkdfSync, argon2Sync} from 'node:crypto';
import {expandProviderZstd} from './zstd-frame.mjs';
const report = JSON.parse(readFileSync(0, 'utf8'));
const B = s => Buffer.from(s, 'hex');
const sha = b => createHash('sha256').update(b).digest();
const hex = b => b.toString('hex');
const cat = (...b) => Buffer.concat(b);
const u32 = n => { const b=Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const u64 = n => { const b=Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b; };
const vector = a => cat(u32(a.length), ...a);
const blob = b => cat(u32(b.length), b);
class Reader {
  constructor(b) { this.b=b; this.p=0; }
  take(n) { assert(n >= 0 && this.p+n <= this.b.length); const b=this.b.subarray(this.p,this.p+n); this.p+=n; return b; }
  n() { return this.take(4).readUInt32BE(); }
  byte() { return this.take(1)[0]; }
  list(f) { const n=this.n(); assert(n <= this.b.length-this.p); return Array.from({length:n},f); }
  blob() { return this.take(this.n()); }
  end() { assert.equal(this.p,this.b.length); }
  magic(m) { assert.equal(this.take(8).toString(),m); assert.equal(this.take(2).readUInt16BE(),1); }
}
function note(r) {
  const start=r.p; assert.equal(r.byte(),1);
  const title=r.blob().toString(), body=r.blob().toString(), labels=r.list(()=>r.blob().toString());
  const created=r.take(8).readDoubleBE(), modified=r.take(8).readDoubleBE();
  assert(Number.isFinite(created) && Number.isFinite(modified));
  return {title,body,labels,created,modified,bytes:hex(r.b.subarray(start,r.p))};
}
const raw = new Map(report.objects.map(r => [r[0].toLowerCase(), {id:r[0].toLowerCase(),kind:Number(r[1]),bytes:B(r[4]),accepted:r[5]!==''}]));
assert.deepEqual(report.integrity,[['ok']]); assert.deepEqual(report.foreign_keys,[]);
let key;
for (const d of [...raw.values()].filter(o=>o.kind===0)) {
  assert.equal(hex(sha(d.bytes)),d.id);
  assert.equal(d.bytes.subarray(0,8).toString(),'NVKEY1\r\n');
  if (d.bytes[10]===2) {
    const wrapping=argon2Sync('argon2id',{message:Buffer.from('probe password'),nonce:d.bytes.subarray(118,134),
      parallelism:4,memory:65536,passes:3,tagLength:32});
    const decipher=createDecipheriv('aes-256-gcm',wrapping,d.bytes.subarray(134,146));
    decipher.setAAD(cat(Buffer.from('NV key wrap\0v1\0'),d.bytes.subarray(0,150)));
    decipher.setAuthTag(d.bytes.subarray(182)); key=cat(decipher.update(d.bytes.subarray(150,182)),decipher.final());
    assert.deepEqual(key,Buffer.alloc(32,4));
  } else assert.deepEqual(d.bytes.subarray(150),sha(cat(Buffer.from('NV public descriptor\0v1\0'),d.bytes.subarray(0,150))));
  d.deps=[hex(d.bytes.subarray(45+24,45+56))];
}
const all = new Map();
for (const o of raw.values()) {
  if (o.kind===0) continue;
  const b=o.bytes, h=b.subarray(0,124); assert.equal(hex(sha(b)),o.id);
  assert.equal(h.subarray(0,8).toString(),'NVSEG1\r\n'); assert.equal(h[10],o.kind);
  let payload;
  const length=Number(h.readBigUInt64BE(96));
  if (h[11]===1) {
    const k=hkdfSync('sha256',key,h.subarray(16,48),cat(Buffer.from('NV object key\0v1\0'),h.subarray(10,11),h.subarray(48,64),Buffer.alloc(16)),32);
    const d=createDecipheriv('aes-256-gcm',k,h.subarray(112,124));
    d.setAAD(cat(Buffer.from('NV object envelope\0v1\0'),h)); d.setAuthTag(b.subarray(124+length));
    payload=cat(d.update(b.subarray(124,124+length)),d.final());
  } else {
    payload=b.subarray(124,124+length);
    assert.deepEqual(b.subarray(124+length),sha(cat(Buffer.from('NV object envelope\0v1\0'),h,payload)));
  }
  assert(h[88]===0 || h[88]===1);
  if (h[88]===1) payload=expandProviderZstd(payload,Number(h.readBigUInt64BE(104)));
  assert.equal(payload.length,Number(h.readBigUInt64BE(104)));
  o.locator=cat(h.subarray(48,72),sha(b)); o.payload=payload; all.set(hex(o.locator),o);
}
const refs=[];
function ref(r,deps,local,width=32,section='ops') {
  const tag=r.byte();
  if(tag===1) { const n=r.n(); assert(n<local.length); return local[n].id; }
  assert.equal(tag,0); const d=r.n(),index=r.n(),id=hex(r.take(width)); assert(d<deps.length);
  refs.push({locator:deps[d],index,id,section}); return id;
}
const ops=new Map(), actions=new Map(), pages=[];
const generalRoots=[];
function pageRange(r) {
  const locator=hex(r.take(56)),offset=r.take(8).readBigUInt64BE(),length=r.take(8).readBigUInt64BE();
  assert(length>0n && offset+length<=(1n<<64n)-1n);return {locator,offset,length};
}
function state(r,deps,local) {
  const tag=r.byte();
  if(tag===0)return [0];
  if(tag<=2)return [tag,ref(r,deps,local)];
  if(tag===5)return [tag,hex(r.take(16)),hex(r.take(32)),ref(r,deps,local)];
  assert(tag===3 || tag===4);
  const inputs=r.list(()=>ref(r,deps,local));
  assert.deepEqual(inputs,[...new Set(inputs)].sort());
  if(tag===3)return [tag,inputs,hex(r.take(32))];
  assert.equal(r.take(2).readUInt16BE(),1);
  return [tag,inputs,ref(r,deps,local),hex(r.take(32)),hex(r.take(32))];
}
function domain(r) { const tag=r.byte(); assert(tag<=1);return {tag,key:hex(r.take(32)),slot:tag===1?r.take(8).readBigUInt64BE().toString():null}; }
for(const o of all.values()) {
  // Retained candidates have authenticated bytes; accepted membership selects
  // the dependency-closed history used for logical occurrences and Current.
  if(!o.accepted)continue;
  const r=new Reader(o.payload);
  o.ops=[]; o.actions=[];
  if(o.kind===1) {
    r.magic('NVCHG1\r\n'); const deps=r.list(()=>hex(r.take(56))); o.deps=deps.map(d=>d.slice(48));
    r.list(()=>{
      const x=new Reader(r.blob()),id=hex(x.take(32)),begin=x.p;
      x.take(16); const tag=x.byte(),action=x.byte()?hex(x.take(16)):null,birth=x.byte()?hex(x.take(16)):null;
      const header=x.b.subarray(begin,x.p);
      const parents=x.list(()=>ref(x,deps,o.ops)),pred=x.list(()=>ref(x,deps,o.ops)),data=x.blob(); x.end();
      assert.equal(hex(sha(cat(Buffer.from('NV operation\0v1\0'),header,vector(parents.map(B)),vector(pred.map(B)),blob(data)))),id);
      const op={id,tag,action,birth,parents,pred,data:hex(data)};
      if(tag>=3 && tag<=5) { const n=new Reader(data); op.value=note(n); n.end(); }
      if(tag===7) { const n=new Reader(data);op.source=hex(n.take(16));op.sourceRevision=hex(n.take(32));op.key=hex(n.take(32));op.slot=n.take(8).readBigUInt64BE().toString();op.reused=n.byte()?hex(n.take(32)):null;op.value=note(n);n.end(); }
      if(tag===8) { const n=new Reader(data);op.domain=domain(n);n.end(); }
      if(tag===9) { const n=new Reader(data);op.source=hex(n.take(16));op.sourceRevision=hex(n.take(32));op.key=hex(n.take(32));op.value=note(n);n.end(); }
      if(ops.has(id)) assert.deepEqual(ops.get(id),op); else ops.set(id,op);
      o.ops.push(op);
    });
    r.list(()=>{
      const a=new Reader(r.blob()),id=hex(a.take(16)),origin=hex(a.take(16));
      const previous=a.byte()?ref(a,deps,o.actions,16,'actions'):null;
      const scope=a.byte()?hex(a.take(16)):null,parents=a.list(()=>ref(a,deps,o.actions,16,'actions')),kind=a.byte();
      const members=a.list(()=>{ const i=a.n(); assert(i<o.ops.length); return o.ops[i].id; });
      const affected=a.list(()=>({birth:hex(a.take(16)),before:state(a,deps,o.ops),after:state(a,deps,o.ops)}));
      const restorations=[6,10,11].includes(kind) ? a.list(()=>({birth:hex(a.take(16)),source:hex(a.take(16)),
        deletion:ref(a,deps,o.actions,16,'actions'),revision:ref(a,deps,o.ops),prior:a.byte()?state(a,deps,o.ops):null})) : [];
      let details=null;
      if(kind===7)details={source:hex(a.take(16)),revision:ref(a,deps,o.ops),fields:a.byte()};
      if(kind===8)details={selected:ref(a,deps,o.ops),heads:a.list(()=>ref(a,deps,o.ops))};
      if(kind===9)details={source:hex(a.take(16)),revision:ref(a,deps,o.ops),key:hex(a.take(32)),slot:a.take(8).readBigUInt64BE().toString(),reused:a.byte()?ref(a,deps,o.ops):null};
      if(kind===10 || kind===11)details={target:ref(a,deps,o.actions,16,'actions'),reviewed:a.byte()};
      if(kind===12)details=a.list(()=>({action:ref(a,deps,o.actions,16,'actions'),remaining:state(a,deps,o.ops),complete:a.byte()}));
      a.end();
      const action={id,origin,previous,scope,parents,kind,members,affected,restorations,details};
      if(actions.has(id)) assert.deepEqual(actions.get(id),action); else actions.set(id,action);
      for(const m of members) assert.equal(ops.get(m).action,id);
      o.actions.push(action);
    }); r.end();
  } else if(o.kind===3) {
    if(o.payload.subarray(0,8).toString()==='NVGPG1\r\n') {
      r.magic('NVGPG1\r\n');const tag=r.byte();assert(tag<=1);
      if(tag===0) {o.offset=r.take(8).readBigUInt64BE();o.data=r.blob();o.length=BigInt(o.data.length);assert(o.length>0n);o.deps=[];}
      else {o.children=r.list(()=>pageRange(r));assert(o.children.length);o.offset=o.children[0].offset;
        let end=o.offset;for(const child of o.children){assert.equal(child.offset,end);end+=child.length;}
        o.length=end-o.offset;o.deps=o.children.map(c=>c.locator.slice(48));}
      r.end();continue;
    }
    r.magic('NVSPG1\r\n'); r.take(16); r.n(); const deps=r.list(()=>hex(r.take(56))); o.deps=deps.map(d=>d.slice(48));
    o.rows=r.list(()=>({birth:hex(r.take(16)),value:note(r),id:ref(r,deps,[])})); r.end(); pages.push(o);
  } else {
    if(o.payload.subarray(0,8).toString()==='NVGRT1\r\n') {
      r.magic('NVGRT1\r\n');assert.equal(r.take(2).readUInt16BE(),1);o.bootstrap=hex(r.take(56));o.tree=pageRange(r);
      assert.equal(o.tree.offset,0n);o.counts=Array.from({length:7},()=>r.take(8).readBigUInt64BE());o.digest=r.take(32);r.end();
      o.general=true;generalRoots.push(o);continue;
    }
    r.magic('NVSRT1\r\n'); r.take(16); o.count=Number(r.take(8).readBigUInt64BE()); o.digest=hex(r.take(32));
    const deps=r.list(()=>hex(r.take(56))); o.deps=deps.map(d=>d.slice(48)); o.complete=ref(r,deps,[]);
    r.list(()=>ref(r,deps,[])); o.pages=r.list(()=>{r.n();const d=hex(r.take(56)); r.n();return d;});r.end();
    o.deps.push(...o.pages.map(d=>d.slice(48)));
  }
}
const generalSnapshots=[];
for(const root of generalRoots) {
  const work=[root.tree],seen=new Set(),leaves=[];
  while(work.length) {
    const range=work.pop();assert(!seen.has(range.locator));seen.add(range.locator);
    const page=all.get(range.locator);assert(page?.accepted && page.kind===3);
    assert.equal(page.offset,range.offset);assert.equal(page.length,range.length);
    if(page.data)leaves.push(page);else work.push(...page.children);
  }
  leaves.sort((a,b)=>a.offset<b.offset?-1:a.offset>b.offset?1:0);
  const stream=cat(...leaves.map(p=>p.data));assert.equal(BigInt(stream.length),root.tree.length);
  assert.deepEqual(sha(cat(Buffer.from('NV general snapshot state\0v1\0'),stream)),root.digest);
  const r=new Reader(stream);r.magic('NVGST1\r\n');const counts=Array(7).fill(0n),history=new Set([root.bootstrap]),frontier=[],cells=[];
  let previousKey;
  function occurrence(r,width) {const address=hex(r.b.subarray(r.p,r.p+56));history.add(address);return stored(r,width);}
  while(r.p<r.b.length) {
    const tag=r.byte();assert(tag>=1 && tag<=7);counts[tag-1]++;
    const p=new Reader(r.blob());let key;
    if(tag===1) {
      assert.equal(p.take(8).toString(),'NVCEL1\r\n');const version=p.take(2).readUInt16BE();assert([1,2].includes(version));
      const birth=hex(p.take(16)),n=new Reader(p.blob()),value=note(n);n.end();
      const revision=occurrence(p,32),scope=p.list(()=>occurrence(p,16));let represented=[revision],heads=[revision];
      if(version===2) {
        represented=p.list(()=>occurrence(p,32));heads=p.list(()=>occurrence(p,32));
        if(p.byte()){const deps=p.list(()=>hex(p.take(56)));deps.forEach(d=>history.add(d));const s=new Reader(p.blob());state(s,deps,[]);s.end();}
        if(p.byte()){p.take(16);p.take(32);occurrence(p,32);}
        if(p.byte())domain(p);
      }
      key=cat(Buffer.from([tag]),B(birth));cells.push({birth,body:value.body,value,represented,heads,scope});
    } else if(tag===2) {const id=occurrence(p,32);frontier.push(id);key=cat(Buffer.from([tag]),B(id));}
    else if(tag===3) {const start=p.p,scope=p.byte();assert(scope<=1);if(scope)p.take(16);const prefix=p.b.subarray(start,p.p);const id=occurrence(p,16);key=cat(Buffer.from([tag]),prefix,B(id));}
    else if(tag===4) {const birth=p.take(16),id=occurrence(p,32);key=cat(Buffer.from([tag]),birth,B(id));assert.equal(ops.get(id).tag,6);}
    else {const payload=p.take(p.b.length);key=cat(Buffer.from([tag]),payload);assert.equal(payload.length,tag===5?(payload[0]===0?33:41):tag===6?32:64);}
    p.end();if(previousKey)assert(Buffer.compare(previousKey,key)<0);previousKey=key;
  }
  assert.deepEqual(counts,root.counts);assert(all.get(root.bootstrap)?.accepted && !all.get(root.bootstrap).general);
  root.deps=[...new Set([root.tree.locator,...history].map(d=>d.slice(48)))];
  const cut=new Set(frontier.flatMap(id=>[...past(id,'parents',true)]));
  for(const op of ops.values())if([1,2,4].includes(op.tag))assert(cut.has(op.id));
  for(const id of cut){const op=ops.get(id);op.pred.forEach(p=>assert(cut.has(p)));if(op.action)actions.get(op.action).members.forEach(m=>assert(cut.has(m)));}
  generalSnapshots.push({root:root.id,pages:[...seen].map(d=>d.slice(48)).sort(),cut:[...cut].sort(),cells});
}
for(const r of refs) assert.equal(all.get(r.locator)?.[r.section]?.[r.index]?.id,r.id);
for(const a of actions.values()) for(const s of a.restorations) {
  const entry=actions.get(s.deletion).affected.find(e=>e.birth===s.source);
  assert.equal(entry.after[0],2);
  if(s.prior)assert.deepEqual(s.prior,entry.before);
  assert.notEqual(s.birth,s.source); assert.equal(ops.get(s.revision).birth,s.prior?.[0]===5?s.prior[1]:s.source);
  const result=a.affected.find(e=>e.birth===s.birth); assert.deepEqual(result.before,[0]);
  assert.equal(result.after[0],1); assert(a.members.includes(result.after[1]));
  assert.equal(ops.get(result.after[1]).tag,3);
  assert.deepEqual(ops.get(result.after[1]).value,s.prior?stateValue(s.prior):ops.get(s.revision).value);
}
for(const p of pages) for(const row of p.rows) { assert.equal(ops.get(row.id).birth,row.birth); assert.deepEqual(ops.get(row.id).value,row.value); }
for(const root of [...all.values()].filter(o=>o.accepted && o.kind===2 && !o.general)) {
  const values=root.pages.flatMap(p=>all.get(p).rows).sort((a,b)=>a.birth.localeCompare(b.birth));
  assert.equal(values.length,root.count); const count=Buffer.alloc(8); count.writeBigUInt64BE(BigInt(root.count));
  const digest=sha(cat(Buffer.from('NV initial values\0v1\0'),count,...values.map(v=>cat(B(v.birth),blob(B(v.value.bytes))))));
  assert.equal(hex(digest),root.digest); assert.equal(ops.get(root.complete).tag,2);
  assert.equal(ops.get(root.complete).data.slice(-64),root.digest);
}
assert.equal(ops.size,report.operations.length); assert.equal(actions.size,report.actions.length);
for(const row of report.operations) { const op=ops.get(row[0].toLowerCase()); assert.equal(op.tag,Number(row[1])); assert.equal(op.birth??'',row[2].toLowerCase()); }
for(const row of report.actions) {
  const a=actions.get(row[0].toLowerCase());
  assert.deepEqual(row.slice(1).map(s=>s.toLowerCase()),[a.origin,a.previous??'',a.scope??'',String(a.kind)]);
}
const pairs=a=>a.map(x=>x.map(s=>s.toLowerCase()).join(':')).sort();
const restoredEntries=new Map();
for(const a of actions.values()) for(const s of a.restorations) {
  const k=s.source+':'+s.deletion, candidates=restoredEntries.get(k)??[];
  candidates.push(a.id); restoredEntries.set(k,candidates);
}
assert.deepEqual(report.restorations.map(r=>r.slice(0,2).map(s=>s.toLowerCase()).join(':')).sort(),[...restoredEntries.keys()].sort());
const acceptedSequence=id=>Number(report.operations.find(r=>r[0].toLowerCase()===actions.get(id).members[0])[6]);
for(const [birth,deletion,action] of report.restorations) {
  const candidates=restoredEntries.get(birth.toLowerCase()+':'+deletion.toLowerCase());
  assert(candidates.includes(action.toLowerCase()));
  assert.equal(acceptedSequence(action.toLowerCase()),Math.min(...candidates.map(acceptedSequence)));
}
assert.deepEqual(pairs(report.operation_occurrences),[...all.values()].filter(o=>o.accepted).flatMap(o=>o.ops.map((p,n)=>p.id+':'+o.id+':'+n)).sort());
assert.deepEqual(pairs(report.action_occurrences),[...all.values()].filter(o=>o.accepted).flatMap(o=>o.actions.map((a,n)=>a.id+':'+o.id+':'+n)).sort());
assert.deepEqual(pairs(report.dependencies),[...raw.values()].filter(o=>o.accepted).flatMap(o=>[...new Set(o.deps??[])].map(d=>o.id+':'+d)).sort());
assert.deepEqual(pairs(report.parents),[...ops.values()].flatMap(o=>o.parents.map(p=>o.id+':'+p)).sort());
assert.deepEqual(pairs(report.predecessors),[...ops.values()].flatMap(o=>o.pred.map(p=>o.id+':'+p)).sort());
assert.deepEqual(pairs(report.members),[...actions.values()].flatMap(a=>a.members.map((m,n)=>a.id+':'+n+':'+m)).sort());
const maximal=new Set([...raw.values()].filter(o=>o.accepted && o.kind!==0).map(o=>o.id));
for(const o of raw.values()) if(o.accepted) for(const d of o.deps??[]) { assert(raw.get(d)?.accepted); maximal.delete(d); }
assert.deepEqual(report.frontier.map(r=>r[0].toLowerCase()).sort(),[...maximal].sort());
function stored(r,width) { const locator=hex(r.take(56)),index=r.n(),id=hex(r.take(width)); assert.equal(all.get(locator)?.[width===32?'ops':'actions']?.[index]?.id,id);return id; }
const ctx=new Reader(B(report.view[0][2]));ctx.magic('NVCTX1\r\n');const frontier=ctx.list(()=>stored(ctx,32)),collectionActions=ctx.list(()=>stored(ctx,16));ctx.end();
function scopeMaxima(scope) {
  const candidates=[...actions.values()].filter(a=>a.scope===scope),heads=new Set(candidates.map(a=>a.id));
  for(const a of candidates)for(const p of a.parents)heads.delete(p);
  return [...heads].sort();
}
function noteBytes(v) {
  const date=d=>{const b=Buffer.alloc(8);b.writeDoubleBE(d);return b;};
  return cat(Buffer.from([1]),blob(Buffer.from(v.title)),blob(Buffer.from(v.body)),vector(v.labels.map(x=>blob(Buffer.from(x)))),date(v.created),date(v.modified));
}
function valueWith(v,fields) { const result={...v,...fields};result.bytes=hex(noteBytes(result));return result; }
function sameFields(a,b) {return a.title===b.title && a.body===b.body && JSON.stringify(a.labels)===JSON.stringify(b.labels);}
function scalar(b,l,r) {if(l===r)return l;if(l===b)return r;if(r===b)return l;return undefined;}
// The independent oracle uses LF-token slices and array reconstruction.
function mergedValue(base,left,right,created) {
  const title=scalar(base.title,left.title,right.title);if(title===undefined)return null;
  let body=scalar(base.body,left.body,right.body);
  if(body===undefined) {
    const tokens=s=>s.match(/[^\n]*\n|[^\n]+$/g)??[];
    const b=tokens(base.body),l=tokens(left.body),r=tokens(right.body);
    if(Math.max(b.length,l.length,r.length)>10000)return null;
    const edit=x=>{
      const equal=b.map((v,i)=>v===x[i]);let start=equal.findIndex(x=>!x);
      if(start<0)start=Math.min(b.length,x.length);
      let tail=0;while(tail<Math.min(b.length,x.length)-start && b[b.length-1-tail]===x[x.length-1-tail])tail++;
      return {start,end:b.length-tail,replacement:x.slice(start,x.length-tail)};
    };
    const a=edit(l),z=edit(r);
    if(JSON.stringify(a)===JSON.stringify(z))body=[...b.slice(0,a.start),...a.replacement,...b.slice(a.end)].join('');
    else {
      const [x,y]=[a,z].sort((a,b)=>a.start-b.start);if(x.end>=y.start)return null;
      body=[...b.slice(0,x.start),...x.replacement,...b.slice(x.end,y.start),...y.replacement,...b.slice(y.end)].join('');
    }
  }
  const labels=[...new Set([...base.labels,...left.labels,...right.labels])]
    .filter(x=>scalar(base.labels.includes(x),left.labels.includes(x),right.labels.includes(x)))
    .sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b)));
  return valueWith(base,{title,body,labels,created,modified:Math.max(left.modified,right.modified)});
}
function stateValue(s) {
  if(s[0]===0 || s[0]===2)return null;
  if(s[0]===1)return ops.get(s[1]).value;
  if(s[0]===5)return valueWith(ops.get(s[3]).value,{title:ops.get(s[3]).value.title+' (conflict)'});
  assert(s[0]===3 || s[0]===4);
  const values=s[1].map(id=>ops.get(id).value);let result;
  if(s[0]===3) {assert(values.every(v=>sameFields(values[0],v)));result=valueWith(values[0],{modified:Math.max(...values.map(v=>v.modified))});}
  else {result=mergedValue(ops.get(s[2]).value,values[0],values[1],ops.get(s[2]).value.created);assert(result);}
  assert.equal(hex(sha(cat(Buffer.from('NV note value\0v1\0'),noteBytes(result)))),s[0]===3?s[2]:s[3]);
  return result;
}
function past(id,edge='parents',include=false) {
  const found=new Set(),work=include?[id]:[...ops.get(id)[edge]];
  while(work.length){const next=work.pop();assert(ops.has(next));if(!found.has(next)){found.add(next);work.push(...ops.get(next)[edge]);}}
  return found;
}
const uuid=d=>{const b=Buffer.from(d.subarray(0,16));b[6]=b[6]&15|128;b[8]=b[8]&63|128;return hex(b);};
function automaticKey(source,v) {
  const text=x=>{const b=Buffer.from(x.normalize('NFC'));return cat(u64(b.length),b);};
  const labels=[...new Set(v.labels.map(x=>x.normalize('NFC')))].sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b)));
  return hex(sha(cat(Buffer.from('NV automatic conflict preservation\0v1\0'),B(source),text(v.title),text(v.body),u64(labels.length),...labels.map(text))));
}
assert.deepEqual(collectionActions.sort(),scopeMaxima(null));
const opHeads=new Set(ops.keys());for(const o of ops.values())for(const p of o.parents)opHeads.delete(p);
assert.deepEqual(frontier.sort(),[...opHeads].sort());
const expectedNotes=new Map();
const retired=[...ops.values()].filter(o=>o.tag===8).map(o=>o.domain);
const temporary=new Map();
for(const op of ops.values())if(op.birth && !expectedNotes.has(op.birth)) {
  const revisions=[...ops.values()].filter(o=>o.birth===op.birth);
  const values=revisions.filter(o=>o.value && !(o.tag===7 && o.reused));
  const heads=new Set(values.map(o=>o.id));for(const o of values)for(const p of o.pred)heads.delete(p);
  const sorted=[...heads].sort(),deletes=revisions.filter(o=>o.tag===6);
  if(deletes.length) {
    const covered=new Set(deletes.flatMap(o=>[...past(o.id)]));
    for(const id of sorted.filter(id=>!covered.has(id))) {
      const key=automaticKey(op.birth,ops.get(id).value);
      if(retired.some(d=>d.tag===0 && d.key===key))continue;
      const birth=uuid(B(key));if([...ops.values()].some(o=>o.birth===birth))continue;
      const earlier=temporary.get(birth);if(earlier && earlier.represented[0]<id)continue;
      temporary.set(birth,{value:valueWith(ops.get(id).value,{title:ops.get(id).value.title+' (conflict)'}),represented:[id],heads:[id],automatic:{source:op.birth,key,revision:id}});
    }
    continue;
  }
  if(!sorted.length)continue;
  const roots=values.filter(o=>!o.pred.length).sort((a,b)=>a.id.localeCompare(b.id));assert(roots.length);
  const first=ops.get(sorted[0]).value;
  let represented=sorted.filter(id=>sameFields(ops.get(id).value,first));
  let value=valueWith(first,{created:roots[0].value.created,modified:Math.max(...represented.map(id=>ops.get(id).value.modified))});
  if(represented.length!==sorted.length && sorted.length===2) {
    const common=[...past(sorted[0],'pred',true)].filter(id=>past(sorted[1],'pred',true).has(id));
    const bases=common.filter(id=>!common.some(other=>other!==id && past(other,'pred').has(id)));
    if(bases.length===1) {const merged=mergedValue(ops.get(bases[0]).value,ops.get(sorted[0]).value,ops.get(sorted[1]).value,roots[0].value.created);if(merged){value=merged;represented=sorted;}}
  }
  expectedNotes.set(op.birth,{value,represented,heads:sorted,automatic:null});
}
for(const [birth,cell] of temporary)expectedNotes.set(birth,cell);
assert.deepEqual(report.cells.map(r=>r[0].toLowerCase()).sort(),[...expectedNotes.keys()].sort());
for(const [birth,encoded] of report.cells) {
  const r=new Reader(B(encoded));assert.equal(r.take(8).toString(),'NVCEL1\r\n');const version=r.take(2).readUInt16BE();assert([1,2].includes(version));assert.equal(hex(r.take(16)),birth.toLowerCase());
  const n=new Reader(r.blob()),v=note(n);n.end();const revision=stored(r,32),noteActions=r.list(()=>stored(r,16));
  let represented=[revision],heads=[revision],automatic=null;
  if(version===2) {
    represented=r.list(()=>stored(r,32));heads=r.list(()=>stored(r,32));
    if(r.byte()) {const deps=r.list(()=>hex(r.take(56))),s=new Reader(r.blob()),claim=state(s,deps,[]);s.end();assert.deepEqual(stateValue(claim),v);assert.deepEqual(claim[1],represented);}
    if(r.byte())automatic={source:hex(r.take(16)),key:hex(r.take(32)),revision:stored(r,32)};
    if(r.byte()){const identity=domain(r);assert(retired.every(d=>JSON.stringify(d)!==JSON.stringify(identity)));}
  }
  r.end();
  const expected=expectedNotes.get(birth.toLowerCase());assert.deepEqual(represented,expected.represented);assert.deepEqual(heads,expected.heads);assert.deepEqual(automatic,expected.automatic);assert.equal(revision,represented[0]);
  assert.deepEqual(noteActions.sort(),scopeMaxima(birth.toLowerCase()));
  assert.deepEqual(expected.value,v);
}
const dispositions=[...new Set([...actions.values()].filter(a=>a.kind===9).map(a=>a.details.revision))].sort();
console.log(JSON.stringify({objects:raw.size,operations:ops.size,actions:actions.size,verified:true,generalSnapshots,notes:[...expectedNotes].map(([birth,c])=>({birth,body:c.value.body,represented:c.represented,heads:c.heads,automatic:c.automatic})),dispositions,retired,actionRecords:[...actions.values()].map(a=>({...a, affected:a.affected.map(e=>({...e,beforeValue:stateValue(e.before),afterValue:stateValue(e.after)}))})),operationRecords:[...ops.values()]}));
