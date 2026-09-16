// MOSSES PROJECT HUB — Cloudflare Worker
// Online 24/7 at mosses-project-hub.banknakorn39.workers.dev
// v2.0 (2026-07-03): now a LIVE ecosystem inventory. Reads the single source of
// truth (SYSTEM_MAP KV, key map:latest) at request time instead of shipping a
// hardcoded/outdated snapshot. Built by Flyday, upgraded by FRIDAY.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    if (url.pathname === '/api/health') {
      return json({ status: 'online', version: '2.0.0', timestamp: new Date().toISOString() });
    }

    // Live inventory JSON, straight from the SYSTEM_MAP KV single source of truth.
    if (url.pathname === '/api/live') {
      const map = await loadMap(env);
      if (!map) return json({ error: 'SYSTEM_MAP unavailable' }, 503);
      return json(map);
    }

    const map = await loadMap(env);
    return new Response(renderPage(map), {
      headers: { 'Content-Type': 'text/html;charset=UTF-8', 'Cache-Control': 'public, max-age=60' },
    });
  },
};

async function loadMap(env) {
  try {
    if (!env.SYSTEM_MAP) return null;
    return await env.SYSTEM_MAP.get('map:latest', { type: 'json' });
  } catch {
    return null;
  }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

function renderPage(map) {
  const dataJson = JSON.stringify(map ?? null);
  return `<!DOCTYPE html><html lang="th"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>MOSSES PROJECT HUB — Live Inventory</title><link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;600;700&display=swap" rel="stylesheet"><style>:root{--bg:#0a0e1a;--surface:#111827;--card:#1a2235;--border:#2a3655;--accent:#00d4ff;--accentDim:#00d4ff22;--green:#22c55e;--yellow:#f59e0b;--red:#ef4444;--purple:#a855f7;--text:#e2e8f0;--dim:#8892b0;--white:#fff}*{box-sizing:border-box;margin:0;padding:0}body{background:var(--bg);color:var(--text);font-family:'Inter',sans-serif;font-size:13px;line-height:1.5}::-webkit-scrollbar{width:4px;height:4px}::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}code{background:var(--accentDim);padding:1px 4px;border-radius:3px;font-family:'JetBrains Mono',monospace;font-size:11px;color:var(--accent)}.header{background:linear-gradient(135deg,var(--surface),var(--card));border-bottom:1px solid var(--border);padding:16px 20px}.header h1{font-size:20px;font-family:'JetBrains Mono',monospace;color:var(--accent);letter-spacing:1px}.header .sub{font-size:11px;color:var(--dim);margin-top:2px}.stats-row{display:flex;gap:16px;flex-wrap:wrap;margin-top:10px}.stat{text-align:center}.stat .n{font-size:20px;font-weight:700;color:var(--accent);font-family:'JetBrains Mono',monospace}.stat .l{font-size:9px;color:var(--dim);text-transform:uppercase;letter-spacing:1px}.tabs{display:flex;gap:2px;padding:8px 12px;overflow-x:auto;background:var(--surface);border-bottom:1px solid var(--border)}.tabs button{padding:6px 12px;border:none;border-radius:6px;cursor:pointer;font-size:12px;background:transparent;color:var(--dim);white-space:nowrap;transition:all .15s;font-family:'Inter',sans-serif}.tabs button:hover{opacity:.85}.tabs button.active{background:var(--accentDim);color:var(--accent);font-weight:700}.content{padding:16px 20px;max-width:920px;margin:0 auto}.section{margin-bottom:28px}.section-head{display:flex;align-items:center;gap:8px;margin-bottom:12px;border-bottom:1px solid var(--border);padding-bottom:8px}.section-head h2{font-size:16px;color:var(--accent);font-family:'JetBrains Mono',monospace;letter-spacing:1px}.section-head .cnt{font-size:11px;color:var(--dim);background:var(--accentDim);padding:1px 8px;border-radius:10px}.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:12px;margin-bottom:8px;transition:border-color .2s}.card.hl{border-color:#00d4ff44}.card:hover{border-color:#00d4ff66}.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;margin-right:4px;margin-bottom:2px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;flex-shrink:0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:8px}.footer{text-align:center;padding:20px 0;border-top:1px solid var(--border);font-size:10px;color:var(--dim)}.tab-content{display:none}.tab-content.active{display:block}.mono{font-family:'JetBrains Mono',monospace}.live-pill{display:inline-flex;align-items:center;gap:5px;font-size:10px;color:var(--green);background:#22c55e18;border:1px solid #22c55e44;padding:2px 8px;border-radius:10px}.live-pill .dot{width:7px;height:7px;margin:0;animation:pulse 1.8s infinite}@keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}@media(max-width:600px){.header h1{font-size:16px}.stats-row{gap:10px}.stat .n{font-size:16px}}</style></head><body><div class="header"><div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px"><div><h1>MOSSES PROJECT HUB</h1><p class="sub">Live Ecosystem Inventory &middot; <span class="live-pill"><span class="dot" style="background:#22c55e"></span>LIVE from SYSTEM_MAP KV</span> &middot; <span id="genAt">-</span></p></div><div class="stats-row"><div class="stat"><div class="n" id="s-workers">-</div><div class="l">Workers</div></div><div class="stat"><div class="n" id="s-pages">-</div><div class="l">Pages</div></div><div class="stat"><div class="n" id="s-monitored">-</div><div class="l">Monitored</div></div><div class="stat"><div class="n" id="s-groups">-</div><div class="l">Groups</div></div><div class="stat"><div class="n" id="s-db">-</div><div class="l">D1 DBs</div></div></div></div></div><div class="tabs" id="tabs"><button class="active" data-tab="overview">Overview</button><button data-tab="workers">Workers</button><button data-tab="pages">Pages</button><button data-tab="groups">Groups</button><button data-tab="data">Data (D1/KV)</button><button data-tab="findings">Findings</button></div><div class="content"><div class="tab-content active" id="tab-overview"><div class="section"><div class="section-head"><h2>SNAPSHOT</h2></div><div class="grid" id="overview-cards"></div></div></div><div class="tab-content" id="tab-workers"><div class="section"><div class="section-head"><h2>CLOUDFLARE WORKERS</h2><span class="cnt" id="c-workers">0</span></div><div id="workers-list"></div></div></div><div class="tab-content" id="tab-pages"><div class="section"><div class="section-head"><h2>CLOUDFLARE PAGES</h2><span class="cnt" id="c-pages">0</span></div><div id="pages-list"></div></div></div><div class="tab-content" id="tab-groups"><div class="section"><div class="section-head"><h2>SERVICE GROUPS</h2><span class="cnt" id="c-groups">0</span></div><div id="groups-list"></div></div></div><div class="tab-content" id="tab-data"><div class="section"><div class="section-head"><h2>SHARED D1 DATABASES</h2></div><div id="d1-list"></div></div><div class="section"><div class="section-head"><h2>KV NAMESPACES</h2><span class="cnt" id="c-kv">0</span></div><div id="kv-list"></div></div></div><div class="tab-content" id="tab-findings"><div class="section"><div class="section-head"><h2>FINDINGS</h2><span class="cnt" id="c-findings">0</span></div><div id="findings-list"></div></div></div></div><div class="footer">MOSSES x FRIDAY &middot; Live inventory served from Cloudflare KV (SYSTEM_MAP / map:latest) &middot; Cloudflare Workers 24/7</div><script>
const M=${dataJson};
function badge(t,c){return '<span class="badge" style="background:'+c+'22;color:'+c+';border:1px solid '+c+'44">'+t+'</span>'}
function dot(c){return '<span class="dot" style="background:'+c+'"></span>'}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]))}
function boot(){
  if(!M){document.getElementById('overview-cards').innerHTML='<div class="card"><strong style="color:var(--red)">SYSTEM_MAP unavailable</strong><div style="color:var(--dim);font-size:11px;margin-top:4px">KV read failed — check the SYSTEM_MAP binding on this worker.</div></div>';return}
  const meta=M.meta||{},tot=meta.totals||{},groups=M.groups||{},workers=M.workers||[],pages=M.pages||[],findings=M.findings||[];
  const shared=(M.data&&M.data.d1_shared)||M.d1_shared||{};
  const kv=(M.data&&M.data.kv_namespaces)||M.kv_namespaces||[];
  document.getElementById('genAt').textContent='map v'+(meta.version||'?')+' &middot; '+(meta.generated||'');
  document.getElementById('s-workers').textContent=tot.workers!=null?tot.workers:workers.length;
  document.getElementById('s-pages').textContent=tot.pages!=null?tot.pages:pages.length;
  document.getElementById('s-monitored').textContent=tot.monitored_by_edith!=null?tot.monitored_by_edith:'-';
  document.getElementById('s-groups').textContent=Object.keys(groups).length;
  document.getElementById('s-db').textContent=Object.keys(shared).length;
  // Overview
  const monW=workers.filter(w=>w.monitored).length,monP=pages.filter(p=>p.monitored).length;
  const ov=[
    ['EDITH Monitored',(tot.monitored_by_edith!=null?tot.monitored_by_edith:(monW+monP))+' / '+(workers.length+pages.length),'#22c55e','workers + pages under health check'],
    ['Workers',workers.length+' deployed','#00d4ff',monW+' monitored'],
    ['Pages',pages.length+' sites','#00d4ff',monP+' monitored'],
    ['Service Groups',Object.keys(groups).length+'','#a855f7',Object.keys(groups).join(', ')],
    ['Shared D1',Object.keys(shared).length+' databases','#a855f7','single source of truth for data'],
    ['KV Namespaces',kv.length+'','#f59e0b',kv.slice(0,4).join(', ')+(kv.length>4?' …':'')],
  ];
  document.getElementById('overview-cards').innerHTML=ov.map(c=>'<div class="card hl"><div style="font-size:10px;color:var(--dim);text-transform:uppercase;letter-spacing:1px">'+esc(c[0])+'</div><div style="font-size:15px;font-weight:700;color:'+c[2]+';margin:4px 0 2px">'+esc(c[1])+'</div><div style="font-size:10px;color:var(--dim)">'+esc(c[3])+'</div></div>').join('');
  // Workers
  document.getElementById('c-workers').textContent=workers.length;
  document.getElementById('workers-list').innerHTML=workers.map(w=>{
    const tags=[];if(w.ai)tags.push(badge('AI','#a855f7'));if(w.vectorize)tags.push(badge('Vectorize','#a855f7'));
    if(w.d1)w.d1.forEach(d=>tags.push(badge('D1:'+d,'#00d4ff')));
    if(w.kv)w.kv.forEach(k=>tags.push(badge('KV:'+k,'#f59e0b')));
    if(w.r2)w.r2.forEach(r=>tags.push(badge('R2:'+r,'#22c55e')));
    if(w.service_bindings)w.service_bindings.forEach(s=>tags.push(badge('SVC:'+s,'#8892b0')));
    if(w.durable_objects)tags.push(badge('DO x'+w.durable_objects.length,'#a855f7'));
    return '<div class="card hl"><div style="display:flex;align-items:center;gap:6px;margin-bottom:4px">'+dot(w.monitored?'#22c55e':'#8892b0')+'<strong style="color:var(--accent);font-size:13px">'+esc(w.name)+'</strong>'+(w.monitored?badge('MONITORED','#22c55e'):badge('unmonitored','#8892b0'))+'</div><div style="font-size:10px;color:var(--dim);margin-bottom:4px" class="mono">repo: '+esc(w.repo||'-')+(w.main?' &middot; '+esc(w.main):'')+'</div><div style="display:flex;flex-wrap:wrap;gap:2px">'+tags.join('')+'</div></div>';
  }).join('');
  // Pages
  document.getElementById('c-pages').textContent=pages.length;
  document.getElementById('pages-list').innerHTML=pages.map(p=>'<div class="card"><div style="display:flex;align-items:center;gap:6px;margin-bottom:4px">'+dot(p.monitored?'#22c55e':'#8892b0')+'<strong style="color:#fff;font-size:13px">'+esc(p.name)+'</strong>'+(p.monitored?badge('MONITORED','#22c55e'):badge('unmonitored','#8892b0'))+'</div>'+(p.note?'<div style="font-size:11px;color:var(--dim)">'+esc(p.note)+'</div>':'')+(p.repo?'<div style="font-size:10px;color:var(--dim)" class="mono">repo: '+esc(p.repo)+'</div>':'')+'</div>').join('');
  // Groups
  document.getElementById('c-groups').textContent=Object.keys(groups).length;
  document.getElementById('groups-list').innerHTML=Object.entries(groups).map(([g,items])=>'<div class="card"><div style="font-size:12px;font-weight:700;color:var(--accent);margin-bottom:6px">'+esc(g)+' <span style="color:var(--dim);font-weight:400">('+items.length+')</span></div><div style="display:flex;flex-wrap:wrap;gap:4px">'+items.map(i=>badge(i,'#e2e8f0')).join('')+'</div></div>').join('');
  // Data
  document.getElementById('d1-list').innerHTML=Object.entries(shared).map(([db,info])=>{const users=(info&&info.used_by)||[];const note=(info&&info.note)||'';return '<div class="card hl"><div style="display:flex;align-items:center;gap:6px;margin-bottom:6px">'+dot('#22c55e')+'<strong style="color:var(--accent);font-size:13px">'+esc(db)+'</strong>'+badge(users.length+' consumers','#22c55e')+'</div>'+(note?'<div style="font-size:10px;color:var(--yellow);margin-bottom:4px">'+esc(note)+'</div>':'')+'<div style="display:flex;flex-wrap:wrap;gap:3px">'+users.map(u=>badge(u,'#a855f7')).join('')+'</div></div>'}).join('');
  document.getElementById('c-kv').textContent=kv.length;
  document.getElementById('kv-list').innerHTML='<div class="card"><div style="display:flex;flex-wrap:wrap;gap:4px">'+kv.map(k=>badge(k,'#f59e0b')).join('')+'</div></div>';
  // Findings
  const sev={resolved:'#22c55e',info:'#00d4ff',low:'#8892b0',medium:'#f59e0b',high:'#ef4444'};
  document.getElementById('c-findings').textContent=findings.length;
  document.getElementById('findings-list').innerHTML=findings.map(f=>{const c=sev[f.severity]||'#8892b0';return '<div class="card"><div style="display:flex;align-items:center;gap:6px;margin-bottom:4px">'+dot(c)+'<strong style="color:#fff;font-size:12px">'+esc(f.id)+'</strong>'+badge(f.severity,c)+'</div><div style="font-size:11px;color:var(--dim)">'+esc(f.detail)+'</div></div>'}).join('');
}
document.getElementById('tabs').addEventListener('click',e=>{if(e.target.tagName!=='BUTTON')return;document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));document.querySelectorAll('.tab-content').forEach(t=>t.classList.remove('active'));e.target.classList.add('active');document.getElementById('tab-'+e.target.dataset.tab).classList.add('active')});
boot();
</script></body></html>`;
}
