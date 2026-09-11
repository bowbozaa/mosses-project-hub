/**
 * หน้า Mini App ที่เปิดในแอป Telegram — บอทกราฟิกสายพนัน
 *
 * ทำไมเป็นสตริงในโค้ด: worker เดียวจบ ไม่ต้องมี Pages แยก ไม่ต้อง build step
 * ตัว SDK ของ Telegram (telegram-web-app.js) ต้องโหลดจากโดเมนทางการเท่านั้น จึงเป็น script ภายนอกตัวเดียวในหน้า
 * ⚠️ ตั้งแต่ Bot API 10.2 Mini App ต้องเสิร์ฟจากโดเมนเดียวกับที่ลงทะเบียน — ห้ามย้ายหน้าไป host อื่น
 */
import { VERTICALS, TONES, SIZES } from "./presets.js";

export function miniAppHtml(quota) {
  const chips = (obj, cls) =>
    Object.entries(obj)
      .map(
        ([key, p]) =>
          `<button class="chip ${cls}" data-key="${key}" title="${p.hint}"><span>${p.label}</span></button>`,
      )
      .join("");

  const vhints = JSON.stringify(
    Object.fromEntries(Object.entries(VERTICALS).map(([k, v]) => [k, v.hint])),
  );

  return `<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Graphic BOT 888</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
  :root {
    --bg: #0a1520; --card: #10202e; --line: #1d3446;
    --teal: #4ec6c6; --gold: #e6b84a; --light: #c8e6ec; --muted: #7b96a6; --danger: #ff6b6b;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body {
    margin: 0; padding: 14px 14px 32px; background: var(--bg); color: var(--light);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans Thai", sans-serif;
    font-size: 15px; line-height: 1.5;
  }
  h1 { font-size: 17px; margin: 0 0 2px; color: #fff; }
  h1 b { color: var(--gold); }
  .sub { color: var(--muted); font-size: 12.5px; margin-bottom: 12px; }
  .sub b { color: var(--teal); }
  .lbl { color: var(--muted); font-size: 11.5px; margin: 14px 0 6px; text-transform: uppercase; letter-spacing: .6px; display: flex; justify-content: space-between; align-items: center; }
  .lbl small { text-transform: none; letter-spacing: 0; color: var(--muted); }
  .row { display: flex; flex-wrap: wrap; gap: 7px; }
  .chip {
    padding: 9px 12px; border-radius: 999px; background: var(--card); border: 1px solid var(--line);
    color: var(--light); font: inherit; font-size: 14px; cursor: pointer; transition: .15s;
  }
  .chip.v { flex: 1 1 30%; text-align: center; font-weight: 600; }
  .chip[aria-selected="true"] { border-color: var(--gold); background: #1c2a1a; color: #fff; box-shadow: 0 0 0 1px var(--gold) inset; }
  .hint { color: var(--muted); font-size: 12px; margin-top: 6px; min-height: 16px; }
  textarea, input[type=url] {
    width: 100%; padding: 10px 12px; border-radius: 12px; background: var(--card); border: 1px solid var(--line);
    color: var(--light); font: inherit; font-size: 14px;
  }
  textarea { min-height: 64px; resize: vertical; }
  textarea:focus, input:focus { outline: none; border-color: var(--teal); }
  .go {
    width: 100%; margin-top: 14px; padding: 14px; border: 0; border-radius: 12px;
    background: linear-gradient(135deg, var(--gold), #c9962a); color: #1a1200; font-weight: 800; font-size: 15.5px; cursor: pointer;
  }
  .go:disabled { opacity: .5; cursor: default; }
  .status {
    margin-top: 12px; padding: 10px 12px; border-radius: 12px; background: var(--card);
    border: 1px solid var(--line); font-size: 13.5px; display: none;
  }
  .status.on { display: block; }
  .status.err { border-color: var(--danger); color: #ffc9c9; }
  .refs { display: flex; gap: 8px; overflow-x: auto; padding-bottom: 4px; }
  .ref { flex: 0 0 auto; width: 76px; height: 76px; border-radius: 10px; border: 2px solid var(--line); overflow: hidden; position: relative; cursor: pointer; background: var(--card); }
  .ref img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .ref[aria-selected="true"] { border-color: var(--gold); }
  .ref.none { display: flex; align-items: center; justify-content: center; font-size: 12px; color: var(--muted); text-align: center; }
  .ref .x { position: absolute; top: 2px; right: 2px; width: 18px; height: 18px; border-radius: 50%; background: rgba(0,0,0,.65); color: #fff; font-size: 11px; line-height: 18px; text-align: center; }
  .urlrow { display: flex; gap: 6px; margin-top: 8px; }
  .urlrow input { flex: 1; }
  .btn { padding: 10px 12px; border-radius: 12px; border: 1px solid var(--line); background: var(--card); color: var(--light); font: inherit; font-size: 13.5px; cursor: pointer; white-space: nowrap; }
  .btn.ideas { width: 100%; margin-top: 8px; border-color: #3b2f55; background: #1b1530; }
  .ideas { display: none; margin-top: 8px; }
  .ideas.on { display: block; }
  .igrid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px; }
  .igrid img { width: 100%; aspect-ratio: 3/4; object-fit: cover; border-radius: 8px; border: 1px solid var(--line); display: block; cursor: pointer; background: var(--card); }
  .gal { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .gal img { width: 100%; border-radius: 10px; display: block; border: 1px solid var(--line); }
  .spin { display: inline-block; width: 12px; height: 12px; border: 2px solid var(--teal);
          border-right-color: transparent; border-radius: 50%; animation: s .7s linear infinite; vertical-align: -1px; margin-right: 6px; }
  @keyframes s { to { transform: rotate(360deg) } }
</style>
</head>
<body>
  <h1>🎨 Graphic <b>BOT 888</b></h1>
  <div class="sub">กราฟิกสายพนันโดยเฉพาะ · รูปเด้งเข้าแชทให้เอง · โควตาวันนี้ <b id="q">${quota}</b> รูป</div>

  <div class="lbl">สาย</div>
  <div class="row" id="vs">${chips(VERTICALS, "v")}</div>
  <div class="hint" id="vh"></div>

  <div class="lbl">โทน</div>
  <div class="row" id="ts">${chips(TONES, "t")}</div>

  <div class="lbl">ขนาด</div>
  <div class="row" id="ss">${chips(SIZES, "s")}</div>

  <div class="lbl">รูปอ้างอิง <small>ให้ AI วาดตามลุคนี้ (ไม่บังคับ)</small></div>
  <div class="refs" id="refs"></div>
  <div class="urlrow">
    <input type="url" id="refurl" placeholder="วางลิงก์ Pinterest / ลิงก์รูป แล้วกดเพิ่ม">
    <button class="btn" id="addurl">เพิ่ม</button>
  </div>
  <button class="btn ideas" id="ideasbtn">💡 ไอเดียจาก Pinterest ตามสายที่เลือก</button>
  <div class="ideas" id="ideas">
    <div class="hint" id="ideash"></div>
    <div class="igrid" id="igrid"></div>
  </div>

  <div class="lbl">รายละเอียดเพิ่ม <small>เว้นว่างได้</small></div>
  <textarea id="extra" placeholder="เช่น โทนเขียว-ทอง, มีลูกบอลทอง, เว้นที่ด้านบนไว้ใส่พาดหัว"></textarea>

  <button class="go" id="go">สร้างภาพ</button>
  <div class="status" id="st"></div>

  <div class="lbl">ผลงานล่าสุดของคุณ</div>
  <div class="gal" id="gal"></div>

<script>
  const tg = window.Telegram?.WebApp;
  tg?.ready(); tg?.expand();
  const initData = tg?.initData || "";
  const VH = ${vhints};

  const $ = (s) => document.querySelector(s);
  const st = $("#st"), go = $("#go"), gal = $("#gal"), refsEl = $("#refs"), igrid = $("#igrid");
  const sel = { vertical: "casino", tone: "hard", size: "square", ref: null };

  // เปิดจากคำสั่ง /ball ฯลฯ → ปุ่มพา ?v= มาด้วย
  const qv = new URLSearchParams(location.search).get("v");
  if (qv && VH[qv]) sel.vertical = qv;

  function group(id, key, cls) {
    document.querySelectorAll("#" + id + " .chip").forEach((b) => {
      b.setAttribute("aria-selected", String(b.dataset.key === sel[key]));
      b.onclick = () => { sel[key] = b.dataset.key; group(id, key, cls); tg?.HapticFeedback?.selectionChanged(); if (key === "vertical") $("#vh").textContent = VH[sel.vertical] || ""; };
    });
  }
  group("vs", "vertical"); group("ts", "tone"); group("ss", "size");
  $("#vh").textContent = VH[sel.vertical] || "";

  function say(html, isErr) { st.className = "status on" + (isErr ? " err" : ""); st.innerHTML = html; }
  function hide() { st.className = "status"; }

  async function api(path, opts = {}) {
    const r = await fetch(path, { ...opts, headers: { "content-type": "application/json", "x-init-data": initData, ...(opts.headers || {}) } });
    return r.json();
  }

  // ── รูปอ้างอิง ──
  let refs = [];
  function renderRefs() {
    refsEl.innerHTML = '<div class="ref none" data-id="" aria-selected="' + (sel.ref === null) + '">ไม่ใช้<br>รูปอ้างอิง</div>' +
      refs.map((r) => '<div class="ref" data-id="' + r.id + '" aria-selected="' + (sel.ref === r.id) + '" title="' + (r.style || "").replace(/"/g, "") + '">' +
        '<img src="/img/' + encodeURIComponent(r.r2_key) + '" alt=""><span class="x" data-del="' + r.id + '">✕</span></div>').join("");
    refsEl.querySelectorAll(".ref").forEach((el) => {
      el.onclick = (e) => {
        if (e.target.dataset.del) { delRef(e.target.dataset.del); return; }
        sel.ref = el.dataset.id || null; renderRefs(); tg?.HapticFeedback?.selectionChanged();
      };
    });
  }
  async function loadRefs(autoPickLatest) {
    const j = await api("/api/refs");
    if (!j.ok) return;
    refs = j.items || [];
    // รูปที่เพิ่งส่งมาในแชท (ภายใน 10 นาที) เลือกให้เลย — คนส่งรูปมาแปลว่าอยากใช้
    if (autoPickLatest && refs[0] && Date.now() - refs[0].created_at < 600000) sel.ref = refs[0].id;
    renderRefs();
  }
  async function delRef(id) {
    if (!confirm("ลบรูปอ้างอิงนี้?")) return;
    await api("/api/ref/del", { method: "POST", body: JSON.stringify({ id }) });
    if (sel.ref === id) sel.ref = null;
    loadRefs(false);
  }
  async function addRefUrl(url) {
    if (!url) return;
    say('<span class="spin"></span>กำลังดึงรูปและอ่านสไตล์…');
    const j = await api("/api/ref/url", { method: "POST", body: JSON.stringify({ url }) });
    if (!j.ok) { say("❌ " + (j.error || "เพิ่มรูปไม่สำเร็จ"), true); return; }
    hide(); $("#refurl").value = "";
    sel.ref = j.ref.id;
    await loadRefs(false);
    tg?.HapticFeedback?.notificationOccurred("success");
  }
  $("#addurl").onclick = () => addRefUrl($("#refurl").value.trim());

  // ── ไอเดีย Pinterest ──
  $("#ideasbtn").onclick = async () => {
    const box = $("#ideas"); box.classList.add("on");
    $("#ideash").innerHTML = '<span class="spin"></span>กำลังหาไอเดีย…'; igrid.innerHTML = "";
    const j = await api("/api/ideas?v=" + sel.vertical);
    if (!j.ok) { $("#ideash").textContent = "❌ " + (j.error || "ค้นไม่สำเร็จ"); return; }
    $("#ideash").textContent = (j.items || []).length ? "แตะรูปที่ชอบเพื่อใช้เป็นรูปอ้างอิง · " + j.keyword : "ไม่พบไอเดียสำหรับสายนี้";
    igrid.innerHTML = (j.items || []).map((it) => '<img loading="lazy" src="' + it.thumb + '" data-full="' + it.full + '" alt="">').join("");
    igrid.querySelectorAll("img").forEach((im) => { im.onclick = () => addRefUrl(im.dataset.full); im.onerror = () => im.remove(); });
  };

  // ── ผลงาน ──
  async function loadGallery() {
    const j = await api("/api/mine");
    if (!j.ok) return;
    gal.innerHTML = (j.items || []).map((it) => '<img loading="lazy" src="/img/' + encodeURIComponent(it.r2_key) + '" alt="">').join("");
    if (typeof j.left === "number") $("#q").textContent = j.left;
  }

  // ── สร้าง ──
  go.addEventListener("click", async () => {
    go.disabled = true;
    const started = Date.now();
    // server วาดในตัว request (10–25 วิ) — นับวิให้เห็นระหว่างรอ
    const tick = setInterval(() => say('<span class="spin"></span>กำลังวาด… ' + Math.round((Date.now() - started) / 1000) + " วิ"), 1000);
    say('<span class="spin"></span>กำลังวาด…');
    let j;
    try {
      j = await api("/api/generate", {
        method: "POST",
        body: JSON.stringify({ vertical: sel.vertical, tone: sel.tone, size: sel.size, ref_id: sel.ref, extra: $("#extra").value }),
      });
    } catch (e) { j = { ok: false, error: "การเชื่อมต่อหลุด ลองใหม่อีกครั้ง" }; }
    clearInterval(tick);
    if (!j.ok) { say("❌ " + (j.error || "ส่งงานไม่สำเร็จ"), true); go.disabled = false; return; }
    const finish = (s) => {
      const sec = Math.round((Date.now() - started) / 1000);
      if (s.status === "done") {
        say("✅ เสร็จแล้ว (" + sec + " วิ) — ส่งเข้าแชทให้แล้ว" + (s.fallback ? "<br><small>โมเดลหลักปฏิเสธภาพนี้ ใช้ตัวสำรองแทน (ได้ 1:1)</small>" : ""));
        tg?.HapticFeedback?.notificationOccurred("success");
      } else {
        say("❌ " + (s.error || "สร้างไม่สำเร็จ"), true);
      }
      go.disabled = false; loadGallery();
    };
    if (j.status === "done" || j.status === "failed") { finish(j); return; }

    // เผื่อกรณี response กลับมาก่อนเสร็จ (ไม่ควรเกิด) → poll ต่อ
    const poll = setInterval(async () => {
      const s = await api("/api/job?id=" + j.id);
      const sec = Math.round((Date.now() - started) / 1000);
      if (s.status === "done" || s.status === "failed") {
        clearInterval(poll); finish(s);
      } else {
        say('<span class="spin"></span>' + (s.status === "running" ? "กำลังวาด" : "รอคิว") + "… " + sec + " วิ");
      }
      if (sec > 180) { clearInterval(poll); say("⌛ นานผิดปกติ ลองใหม่อีกครั้ง", true); go.disabled = false; }
    }, 1500);
  });

  loadRefs(true); loadGallery();
</script>
</body>
</html>`;
}
