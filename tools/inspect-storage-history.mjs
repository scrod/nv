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
for(const o of all.values()) {
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
      if(ops.has(id)) assert.deepEqual(ops.get(id),op); else ops.set(id,op);
      o.ops.push(op);
    });
    r.list(()=>{
      const a=new Reader(r.blob()),id=hex(a.take(16)),origin=hex(a.take(16));
      const previous=a.byte()?ref(a,deps,o.actions,16,'actions'):null;
      const scope=a.byte()?hex(a.take(16)):null,parents=a.list(()=>ref(a,deps,o.actions,16,'actions')),kind=a.byte();
      const members=a.list(()=>{ const i=a.n(); assert(i<o.ops.length); return o.ops[i].id; });
      function state() { const tag=a.byte(); return tag===0 ? [0] : [tag,ref(a,deps,o.ops)]; }
      const affected=a.list(()=>({birth:hex(a.take(16)),before:state(),after:state()})); a.end();
      const action={id,origin,previous,scope,parents,kind,members,affected};
      if(actions.has(id)) assert.deepEqual(actions.get(id),action); else actions.set(id,action);
      for(const m of members) assert.equal(ops.get(m).action,id);
      o.actions.push(action);
    }); r.end();
  } else if(o.kind===3) {
    r.magic('NVSPG1\r\n'); r.take(16); r.n(); const deps=r.list(()=>hex(r.take(56))); o.deps=deps.map(d=>d.slice(48));
    o.rows=r.list(()=>({birth:hex(r.take(16)),value:note(r),id:ref(r,deps,[])})); r.end(); pages.push(o);
  } else {
    r.magic('NVSRT1\r\n'); r.take(16); o.count=Number(r.take(8).readBigUInt64BE()); o.digest=hex(r.take(32));
    const deps=r.list(()=>hex(r.take(56))); o.deps=deps.map(d=>d.slice(48)); o.complete=ref(r,deps,[]);
    r.list(()=>ref(r,deps,[])); o.pages=r.list(()=>{r.n();const d=hex(r.take(56)); r.n();return d;});r.end();
    o.deps.push(...o.pages.map(d=>d.slice(48)));
  }
}
for(const r of refs) assert.equal(all.get(r.locator)?.[r.section]?.[r.index]?.id,r.id);
for(const p of pages) for(const row of p.rows) { assert.equal(ops.get(row.id).birth,row.birth); assert.deepEqual(ops.get(row.id).value,row.value); }
for(const root of [...all.values()].filter(o=>o.kind===2)) {
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
assert.deepEqual(pairs(report.operation_occurrences),[...all.values()].flatMap(o=>o.ops.map((p,n)=>p.id+':'+o.id+':'+n)).sort());
assert.deepEqual(pairs(report.action_occurrences),[...all.values()].flatMap(o=>o.actions.map((a,n)=>a.id+':'+o.id+':'+n)).sort());
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
assert.deepEqual(collectionActions.sort(),scopeMaxima(null));
const opHeads=new Set(ops.keys());for(const o of ops.values())for(const p of o.parents)opHeads.delete(p);
assert.deepEqual(frontier.sort(),[...opHeads].sort());
const expectedNotes=new Map();
for(const op of ops.values())if(op.birth && !expectedNotes.has(op.birth)) {
  const revisions=[...ops.values()].filter(o=>o.birth===op.birth);
  // This oracle's process corpus is the ordinary, single-valued subset.
  if(revisions.some(o=>o.tag===6))continue;
  const heads=new Set(revisions.map(o=>o.id));for(const o of revisions)for(const p of o.pred)heads.delete(p);
  assert.equal(heads.size,1);expectedNotes.set(op.birth,[...heads][0]);
}
assert.deepEqual(report.cells.map(r=>r[0].toLowerCase()).sort(),[...expectedNotes.keys()].sort());
for(const [birth,encoded] of report.cells) {
  const r=new Reader(B(encoded));r.magic('NVCEL1\r\n');assert.equal(hex(r.take(16)),birth.toLowerCase());
  const n=new Reader(r.blob()),v=note(n);n.end();const revision=stored(r,32),noteActions=r.list(()=>stored(r,16));r.end();
  assert.equal(revision,expectedNotes.get(birth.toLowerCase()));
  assert.deepEqual(noteActions.sort(),scopeMaxima(birth.toLowerCase()));
  assert.deepEqual(ops.get(revision).value,v);assert.equal(ops.get(revision).birth,birth.toLowerCase());
}
console.log(JSON.stringify({objects:raw.size,operations:ops.size,actions:actions.size,verified:true}));
