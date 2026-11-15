import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../app/views/pwa/service-worker.js',import.meta.url),'utf8');
const origin='https://routine.example';
function harness(){
  const handlers={},stored=new Map([['/offline','PUBLIC_OFFLINE_GUIDE']]),puts=[],deleted=[],added=[],pending=[];
  let openGate=null;
  let online=true,result=()=>new Response('SYNTHETIC_PRIVATE_DOCUMENT',{headers:{'Content-Type':'text/html','Cache-Control':'private, no-store'}});
  const key=r=>typeof r==='string'?new URL(r,origin).pathname:new URL(r.url).pathname;
  const cache={match:async r=>stored.has(key(r))?new Response(stored.get(key(r))):undefined,
    put:async(r,response)=>{puts.push(key(r));stored.set(key(r),await response.text());},addAll:async items=>added.push(...items)};
  const self={location:{origin},addEventListener:(name,fn)=>handlers[name]=fn,skipWaiting:async()=>{},clients:{claim:async()=>{}}};
  const context={self,URL,Request,Response,console,caches:{open:async()=>{if(openGate)await openGate;return cache;},keys:async()=>['routine-finders-v1','routine-finders-v2','unrelated-app'],delete:async name=>deleted.push(name)},fetch:async (request,options)=>{added.push({path:key(request),credentials:request.credentials,redirect:request.redirect,cache:options?.cache});if(!online)throw Error('synthetic offline');return result();}};
  vm.runInNewContext(source,context);
  return {stored,puts,deleted,added,delayOpen(){let release;openGate=new Promise(resolve=>release=resolve);return release;},async flush(){await Promise.all(pending.splice(0));},setOffline:()=>online=false,setResponse:fn=>result=fn,
    async event(name){handlers[name]({waitUntil:p=>pending.push(p)});await Promise.all(pending.splice(0));},
    async request(path,{method='GET',mode='cors',drain=true}={}){let response;handlers.fetch({request:{url:new URL(path,origin).href,method,mode},respondWith:p=>response=p,waitUntil:p=>pending.push(p)});const value=await response;if(drain)await Promise.all(pending.splice(0));return value;}};
}
function publicAsset({status=200,headers={},redirected=false}={}){
  const r=new Response('PUBLIC_ASSET',{status,headers});Object.defineProperty(r,'type',{value:'basic'});Object.defineProperty(r,'redirected',{value:redirected});return r;
}
test('personal documents and API/auth paths never cache or replay offline',async()=>{
  const h=harness();for(const path of ['/my','/profile','/auth/google_oauth2/callback','/api/account'])await h.request(path,{mode:'navigate'});
  h.setResponse(()=>publicAsset({headers:{'Content-Type':'text/html','Cache-Control':'public'}}));await h.request('/my',{mode:'navigate'});
  assert.deepEqual(h.puts,[]);h.stored.set('/my','STALE_PRIVATE_DOCUMENT');h.setOffline();
  assert.equal(await (await h.request('/my',{mode:'navigate'})).text(),'PUBLIC_OFFLINE_GUIDE');
  assert.equal((await h.request('/api/account')).type,'error');
});
test('cacheable public assets remain available offline',async()=>{
  const h=harness();h.setResponse(()=>publicAsset());await h.request('/assets/application-digest.css');assert.deepEqual(h.puts,['/assets/application-digest.css']);h.setOffline();assert.equal(await (await h.request('/assets/application-digest.css')).text(),'PUBLIC_ASSET');
});
test('mutations and foreign origins are not intercepted',async()=>{
  const h=harness();assert.equal(await h.request('/pwa/subscribe',{method:'POST'}),undefined);assert.equal(await h.request('/session',{method:'DELETE'}),undefined);assert.equal(await h.request('https://routine.example.attacker.test/assets/code.js'),undefined);assert.deepEqual(h.puts,[]);
});
test('private, no-store, cookie-varying, redirected and error assets are not cached',async()=>{
  for(const options of [{headers:{'Cache-Control':'private'}},{headers:{'Cache-Control':'no-store'}},{headers:{Vary:'Cookie'}},{redirected:true},{status:500}]){const h=harness();h.setResponse(()=>publicAsset(options));await h.request('/assets/private.css');assert.deepEqual(h.puts,[]);}
});
test('installation precaches only the public offline guide and icons',async()=>{
  const h=harness();h.setResponse(()=>publicAsset());await h.event('install');assert.deepEqual(h.added.map(r=>r.path).sort(),['/icon-192.png','/offline','/pwa-icon-512.png']);assert(h.added.every(r=>r.credentials==='omit'&&r.redirect==='error'));
});
test('activation removes old app caches and preserves unrelated caches',async()=>{
  const h=harness();await h.event('activate');assert.deepEqual(h.deleted,['routine-finders-v1']);
});
test('missing offline cache fails safely without a personal document',async()=>{
  const h=harness();h.stored.delete('/offline');h.stored.set('/my','STALE_PRIVATE_DOCUMENT');h.setOffline();const r=await h.request('/my',{mode:'navigate'});assert.equal(r.status,503);assert(!((await r.text()).includes('STALE_PRIVATE_DOCUMENT')));
});

test('precache refuses private, no-store or redirected documents before writing any cache',async()=>{
  for(const options of [{headers:{'Cache-Control':'private'}},{headers:{'Cache-Control':'no-store'}},{redirected:true}]){const h=harness();h.setResponse(()=>publicAsset(options));await assert.rejects(h.event('install'),/Unsafe precache response/);assert.deepEqual(h.puts,[]);}
});
test('public responses are cloned before asynchronous cache opening and body consumption',async()=>{
  const h=harness(),release=h.delayOpen();h.setResponse(()=>publicAsset());const response=await h.request('/assets/slow.css',{drain:false});await response.text();release();await h.flush();assert.equal(h.stored.get('/assets/slow.css'),'PUBLIC_ASSET');
});

test('manifest requests revalidate HTTP cache without entering Cache Storage',async()=>{
  const h=harness();h.setResponse(()=>publicAsset());await h.request('/manifest.json');assert.equal(h.added[0].cache,'no-cache');assert.deepEqual(h.puts,[]);
});
