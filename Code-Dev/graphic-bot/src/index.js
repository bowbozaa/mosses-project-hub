/**
 * graphic-bot — บอทกราฟิกสายพนัน @graphic888_bot (บอล · หวย · มวย · คาสิโน · สล็อต)
 *
 * ทำ 2 อย่างในตัวเดียว:
 *   1. Telegram Mini App ให้พนักงานหลายคนสั่งสร้างภาพพร้อมกัน (เลือกสาย/โทน/ขนาด + รูปอ้างอิง)
 *   2. บอทในแชท — รับรูปอ้างอิงที่พนักงานส่งมา และส่งรูปที่สร้างเสร็จกลับเข้าแชท
 *
 * รูปอ้างอิง (12 ก.ย. 2026): พนักงานส่งรูปจาก FB/IG/Pinterest เข้ามา หรือวาง URL / เลือกจากไอเดีย Pinterest
 *   → เก็บย่อ ≤512px ใน R2 → vision model อ่านสไตล์เป็นข้อความ → ส่งทั้งรูปและข้อความเข้า FLUX.2 klein
 *   klein ใช้รูปเป็น "แรงบันดาลใจ" วาดฉากใหม่ ไม่ได้ก๊อปรูปคนอื่น
 *
 * ทำไมต้องมีคิวใน D1 ไม่ยิงโมเดลตรง ๆ:
 *   โควตา Workers AI ฟรีคิดรวมทั้งบัญชี (~90 รูป/วันบน klein) ถ้าปล่อยยิงตรง คนเดียวใช้หมดของทีมได้
 */
import { miniAppHtml } from "./miniapp.js";
import { VERTICALS, TONES, SIZES, buildPrompt } from "./presets.js";

const TG_API = "https://api.telegram.org";
// klein-4b: ~104 neurons/รูป กำหนดขนาดได้ รับรูปอ้างอิงได้ · schnell: fallback เมื่อโดน safety filter (ล็อก 1024²)
const MODEL_MAIN = "@cf/black-forest-labs/flux-2-klein-4b";
const MODEL_FALLBACK = "@cf/black-forest-labs/flux-1-schnell";
// ใช้ตัวเดียวทั้งอ่านรูปและคัดกรองข้อความ — ยอมรับ license ไว้แล้วบนบัญชีนี้ (~20 neurons/รูป)
const MODEL_VISION = "@cf/meta/llama-3.2-11b-vision-instruct";
const REF_MAX = 480; // klein รับ input image ต้องเล็กกว่า 512×512
const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const p = url.pathname;
    const m = request.method;

    try {
      if (p === "/ping") return text("pong");

      if (p === "/" && m === "GET") {
        return html(miniAppHtml(env.DAILY_QUOTA || "15"));
      }

      if (p === "/webhook" && m === "POST")
        return handleWebhook(request, env, ctx);

      if (p === "/api/generate" && m === "POST")
        return handleGenerate(request, env, ctx);
      if (p === "/api/job") return handleJobStatus(url, request, env);
      if (p === "/api/mine") return handleMine(request, env);

      if (p === "/api/refs" && m === "GET") return handleRefs(request, env);
      if (p === "/api/ref/url" && m === "POST")
        return handleRefUrl(request, env);
      if (p === "/api/ref/del" && m === "POST")
        return handleRefDel(request, env);
      if (p === "/api/ideas" && m === "GET")
        return handleIdeas(url, request, env);
      if (p === "/api/debug-fetch" && m === "GET")
        return handleDebugFetch(url, request, env);

      if (p.startsWith("/img/"))
        return serveImage(decodeURIComponent(p.slice(5)), env);

      return text("not found", 404);
    } catch (err) {
      console.error("unhandled", err?.stack || String(err));
      return json({ ok: false, error: "internal" }, 500);
    }
  },
};

// ── Telegram Mini App auth ───────────────────────────────────────────────

/**
 * ตรวจ initData ที่ Telegram แนบมากับ Mini App
 * secret = HMAC_SHA256("WebAppData" เป็นคีย์, bot token เป็นข้อความ) — สลับที่กันกับ HMAC ปกติ
 * ถ้าไม่ตรวจ ใครก็ยิง /api/generate จากข้างนอกแล้วเผาโควตาเราได้
 */
async function verifyInitData(initData, botToken) {
  if (!initData) return null;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return null;
  params.delete("hash");

  const dataCheckString = [...params.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([k, v]) => `${k}=${v}`)
    .join("\n");

  const enc = new TextEncoder();
  const secretKey = await crypto.subtle.importKey(
    "raw",
    enc.encode("WebAppData"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const secret = await crypto.subtle.sign(
    "HMAC",
    secretKey,
    enc.encode(botToken),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    secret,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    enc.encode(dataCheckString),
  );
  const hex = [...new Uint8Array(sig)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  if (hex !== hash) return null;

  // หมดอายุใน 24 ชม. — initData เก่าที่หลุดออกไปจะใช้ต่อไม่ได้
  const authDate = Number(params.get("auth_date") || 0);
  if (!authDate || Date.now() / 1000 - authDate > 86400) return null;

  try {
    return JSON.parse(params.get("user") || "null");
  } catch {
    return null;
  }
}

async function upsertUser(env, id, name) {
  await env.DB.prepare(
    `INSERT INTO users (user_id, user_name, first_seen) VALUES (?1, ?2, ?3)
     ON CONFLICT (user_id) DO UPDATE SET user_name = excluded.user_name`,
  )
    .bind(String(id), name, new Date().toISOString())
    .run();
  const row = await env.DB.prepare(
    `SELECT blocked, quota FROM users WHERE user_id = ?1`,
  )
    .bind(String(id))
    .first();
  return { id: String(id), name, blocked: !!row?.blocked, quota: row?.quota };
}

function displayName(u) {
  return (
    [u.first_name, u.last_name].filter(Boolean).join(" ") ||
    (u.username ? "@" + u.username : String(u.id))
  );
}

async function requireUser(request, env) {
  const initData =
    request.headers.get("x-init-data") ||
    new URL(request.url).searchParams.get("init_data") ||
    "";
  const user = await verifyInitData(initData, env.BOT_TOKEN);
  if (!user?.id) return null;
  return upsertUser(env, user.id, displayName(user));
}

// ── สร้างภาพ ────────────────────────────────────────────────────────────

function thaiDate(ms = Date.now()) {
  return new Date(ms + 7 * 3600 * 1000).toISOString().slice(0, 10);
}

async function usedToday(env, userId) {
  const r = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM jobs WHERE user_id = ?1 AND date_th = ?2 AND status != 'failed'`,
  )
    .bind(userId, thaiDate())
    .first();
  return r?.n || 0;
}

/**
 * บอทนี้ทำเฉพาะกราฟิกสายพนัน — ข้อความเพิ่มที่นอกเรื่อง (เช่น "วาดแมว") ต้องถูกปฏิเสธ
 * ใช้ LLM ตัดสินเพราะ keyword list ไล่ไม่ครบ · ถ้าโมเดลล่มให้ผ่าน (อย่าให้ระบบคัดกรองทำให้ทีมทำงานไม่ได้)
 */
async function topicGuard(env, extra) {
  const t = (extra || "").trim();
  if (t.length < 3) return true;
  try {
    const r = await env.AI.run(MODEL_VISION, {
      messages: [
        {
          role: "system",
          content:
            "You are a strict classifier for a gambling-marketing graphics tool. The tool only makes promotional poster " +
            "backgrounds for: football betting, lottery, Muay Thai / boxing betting, casino, slots. " +
            "Answer YES if the user's note describes visual details that fit such a poster (colors, objects like chips, coins, balls, " +
            "gloves, stadium, layout, mood, Thai/lucky motifs, aspect ratio, etc.). Answer NO only if the note clearly asks for an unrelated " +
            "subject (e.g. pets, food, portraits of real people, other products, unrelated scenes). Reply with exactly YES or NO.",
        },
        { role: "user", content: t.slice(0, 400) },
      ],
      max_tokens: 3,
      temperature: 0,
    });
    const a = String(r?.response || "")
      .trim()
      .toUpperCase();
    return !a.startsWith("NO");
  } catch (err) {
    console.error("topicGuard", String(err?.message || err));
    return true;
  }
}

async function handleGenerate(request, env, ctx) {
  const user = await requireUser(request, env);
  if (!user)
    return json({ ok: false, error: "เปิดผ่านแอป Telegram เท่านั้น" }, 401);
  if (user.blocked)
    return json({ ok: false, error: "บัญชีนี้ถูกปิดสิทธิ์ใช้งาน" }, 403);

  const body = await request.json().catch(() => ({}));
  const vertical = VERTICALS[body.vertical] ? body.vertical : "casino";
  const tone = TONES[body.tone] ? body.tone : "hard";
  const size = SIZES[body.size] ? body.size : "square";
  const extra = String(body.extra || "").slice(0, 500);
  const refId = body.ref_id ? String(body.ref_id).slice(0, 20) : null;

  if (!(await topicGuard(env, extra))) {
    return json(
      {
        ok: false,
        error:
          "บอทนี้ทำเฉพาะกราฟิกสายพนัน (บอล หวย มวย คาสิโน สล็อต) — รายละเอียดที่พิมพ์อยู่นอกเรื่องค่ะ",
      },
      400,
    );
  }

  let ref = null;
  if (refId) {
    ref = await env.DB.prepare(
      `SELECT id, r2_key, style FROM refs WHERE id = ?1 AND user_id = ?2`,
    )
      .bind(refId, user.id)
      .first();
    if (!ref) return json({ ok: false, error: "ไม่พบรูปอ้างอิงนี้" }, 400);
  }

  const prompt = buildPrompt({
    vertical,
    tone,
    extra,
    styleText: ref?.style || "",
    hasRef: !!ref,
  });

  const limit = Number(user.quota ?? env.DAILY_QUOTA ?? 15);
  const used = await usedToday(env, user.id);
  if (used >= limit) {
    return json(
      {
        ok: false,
        error: `วันนี้ใช้ครบ ${limit} รูปแล้ว พรุ่งนี้เริ่มใหม่ค่ะ`,
      },
      429,
    );
  }

  const id = crypto.randomUUID().slice(0, 12);
  await env.DB.prepare(
    `INSERT INTO jobs (id, user_id, user_name, chat_id, preset, extra, prompt, status, model, date_th, created_at,
                       vertical, tone, size, ref_id)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'queued', ?8, ?9, ?10, ?11, ?12, ?13, ?14)`,
  )
    .bind(
      id,
      user.id,
      user.name,
      user.id, // Mini App เปิดจากแชทส่วนตัว → chat id = user id
      `${vertical}/${tone}`,
      extra,
      prompt,
      MODEL_MAIN,
      thaiDate(),
      Date.now(),
      vertical,
      tone,
      size,
      ref?.id || null,
    )
    .run();

  // วาดในตัว request เลย (ลูกค้าต่ออยู่ = ไม่จำกัดเวลา) — ห้ามใช้ ctx.waitUntil เพราะถูกตัดที่ 30 วิ
  // klein แนวตั้งใช้ 10–20 วิ เคยโดนตัดจน job ค้าง "running" ตลอดกาล (12 ก.ย. 2026)
  const result = await runJob(env, id);

  return json({
    ok: true,
    id,
    left: Math.max(0, limit - used - 1),
    ...result,
  });
}

/**
 * FLUX.2 klein ผ่าน REST (multipart) — ทางที่ยิงทดสอบแล้วว่าตอบใน 10–17 วิ
 * ไม่ใช้ binding multipart เพราะเคยค้างไม่ตอบกลับเลยจนโดน 30 วิของ waitUntil ตัด
 */
async function runKlein(env, { prompt, w, h, refBytes }) {
  const form = new FormData();
  form.append("prompt", prompt);
  form.append("width", String(w));
  form.append("height", String(h));
  if (refBytes)
    form.append(
      "input_image_0",
      new Blob([refBytes], { type: "image/jpeg" }),
      "ref.jpg",
    );
  const r = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/ai/run/${MODEL_MAIN}`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${env.CF_AI_TOKEN}` },
      body: form,
    },
  );
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j?.success) {
    const msg =
      j?.errors?.map((e) => e.message).join("; ") || `HTTP ${r.status}`;
    throw new Error(msg);
  }
  return j.result;
}

/** งานที่ค้าง running เกิน 3 นาที = ถูกตัดกลางคัน (ลูกค้าปิดแอป) → ปิดเป็น failed ให้โควตาคืนและหน้าจอไม่ค้าง */
async function sweepStale(env) {
  await env.DB.prepare(
    `UPDATE jobs SET status = 'failed', error = 'หมดเวลา (ปิดแอปก่อนเสร็จ)', finished_at = ?1
      WHERE status IN ('queued','running') AND created_at < ?2`,
  )
    .bind(Date.now(), Date.now() - 180_000)
    .run()
    .catch(() => {});
}

async function runJob(env, id) {
  const job = await env.DB.prepare(`SELECT * FROM jobs WHERE id = ?1`)
    .bind(id)
    .first();
  if (!job || job.status !== "queued") return;

  await env.DB.prepare(`UPDATE jobs SET status = 'running' WHERE id = ?1`)
    .bind(id)
    .run();

  try {
    const sz = SIZES[job.size] || SIZES.square;
    let refBytes = null;
    if (job.ref_id) {
      const ref = await env.DB.prepare(`SELECT r2_key FROM refs WHERE id = ?1`)
        .bind(job.ref_id)
        .first();
      const obj = ref && (await env.IMAGES.get(ref.r2_key));
      if (obj) refBytes = new Uint8Array(await obj.arrayBuffer());
    }

    let out;
    let model = MODEL_MAIN;
    try {
      out = await runKlein(env, {
        prompt: job.prompt,
        w: sz.w,
        h: sz.h,
        refBytes,
      });
    } catch (err) {
      const msg = String(err?.message || err);
      // klein มี safety filter ที่ตรวจผลลัพธ์และโดนซ้ำได้กับ prompt เดิม → ถอยไป schnell ให้ทีมได้รูปครบ เสียแค่สัดส่วน
      if (!/flagged/i.test(msg)) throw err;
      console.warn("klein flagged → schnell", id);
      model = MODEL_FALLBACK;
      out = await env.AI.run(MODEL_FALLBACK, {
        prompt: job.prompt.replace(/^Use image 0[^.]*\. /, ""),
        steps: 8,
      });
    }
    if (!out?.image) throw new Error("โมเดลไม่คืนรูป");

    const bytes = Uint8Array.from(atob(out.image), (c) => c.charCodeAt(0));
    const key = `${job.date_th}/${job.user_id}/${id}.jpg`;
    await env.IMAGES.put(key, bytes, {
      httpMetadata: { contentType: "image/jpeg" },
    });

    await env.DB.prepare(
      `UPDATE jobs SET status = 'done', r2_key = ?2, model = ?3, finished_at = ?4 WHERE id = ?1`,
    )
      .bind(id, key, model, Date.now())
      .run();

    const v = VERTICALS[job.vertical]?.label || job.vertical;
    const t = TONES[job.tone]?.label || "";
    const caption = [
      `${v} · ${t} · ${sz.label}${job.ref_id ? " · 🖼 มีรูปอ้างอิง" : ""}`,
      job.extra ? `<i>${escapeHtml(job.extra)}</i>` : "",
      model === MODEL_FALLBACK
        ? "<i>(โมเดลหลักปฏิเสธภาพนี้ เลยใช้ตัวสำรอง ได้ 1:1)</i>"
        : "",
    ]
      .filter(Boolean)
      .join("\n");
    await sendPhoto(env, job.chat_id, bytes, caption);
    return { status: "done", r2_key: key, fallback: model === MODEL_FALLBACK };
  } catch (err) {
    const msg = String(err?.message || err).slice(0, 300);
    console.error("job failed", id, msg);
    await env.DB.prepare(
      `UPDATE jobs SET status = 'failed', error = ?2, finished_at = ?3 WHERE id = ?1`,
    )
      .bind(id, msg, Date.now())
      .run();
    return { status: "failed", error: msg };
  }
}

async function handleJobStatus(url, request, env) {
  const user = await requireUser(request, env);
  if (!user) return json({ ok: false, error: "unauthorized" }, 401);
  await sweepStale(env);

  const row = await env.DB.prepare(
    `SELECT id, status, r2_key, error, model FROM jobs WHERE id = ?1 AND user_id = ?2`,
  )
    .bind(url.searchParams.get("id") || "", user.id)
    .first();
  if (!row) return json({ ok: false, error: "ไม่พบงานนี้" }, 404);
  return json({ ok: true, ...row, fallback: row.model === MODEL_FALLBACK });
}

async function handleMine(request, env) {
  const user = await requireUser(request, env);
  if (!user) return json({ ok: false, error: "unauthorized" }, 401);

  const rows = await env.DB.prepare(
    `SELECT id, r2_key, vertical, tone, size, created_at FROM jobs
      WHERE user_id = ?1 AND status = 'done' ORDER BY created_at DESC LIMIT 12`,
  )
    .bind(user.id)
    .all();

  const limit = Number(user.quota ?? env.DAILY_QUOTA ?? 15);
  const used = await usedToday(env, user.id);
  return json({
    ok: true,
    items: rows.results || [],
    left: Math.max(0, limit - used),
  });
}

/** รูปเสิร์ฟผ่าน worker — bucket ไม่ต้องเปิด public */
async function serveImage(key, env) {
  const obj = await env.IMAGES.get(key);
  if (!obj) return text("not found", 404);
  return new Response(obj.body, {
    headers: {
      "content-type": obj.httpMetadata?.contentType || "image/jpeg",
      "cache-control": "public, max-age=31536000, immutable",
    },
  });
}

// ── รูปอ้างอิง ──────────────────────────────────────────────────────────

/**
 * ย่อรูปให้เล็กกว่า 512px ผ่าน Images binding — ถ้าบัญชีไม่มี binding หรือย่อไม่ได้ ใช้รูปเดิม
 * (รูปจากแชท Telegram เลือก size ≤512 มาแล้ว · รูปจาก pinimg ใช้ 474x อยู่แล้ว จึงพังยาก)
 */
async function shrink(env, bytes) {
  try {
    if (!env.IMG) return bytes;
    const r = await env.IMG.input(new Blob([bytes]).stream())
      .transform({ width: REF_MAX, height: REF_MAX, fit: "scale-down" })
      .output({ format: "image/jpeg", quality: 85 });
    return new Uint8Array(await r.response().arrayBuffer());
  } catch (err) {
    console.warn("shrink failed, using original", String(err?.message || err));
    return bytes;
  }
}

/** vision model แปลงรูปอ้างอิงเป็นข้อความสไตล์ (สี แสง องค์ประกอบ) — ~20 neurons/รูป */
async function describeStyle(env, bytes) {
  try {
    const r = await env.AI.run(MODEL_VISION, {
      prompt:
        "Describe this poster's visual style for an image-generation prompt: color palette, lighting, main objects, " +
        "composition, mood. English, one paragraph, max 70 words. Do not mention any text, numbers, brand names or people's identities.",
      image: [...bytes],
      max_tokens: 160,
      temperature: 0.2,
    });
    return String(r?.response || "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 500);
  } catch (err) {
    console.warn("describeStyle", String(err?.message || err));
    return "";
  }
}

async function storeRef(env, userId, rawBytes, { source, srcUrl = null }) {
  const bytes = await shrink(env, rawBytes);
  const id = "r" + crypto.randomUUID().slice(0, 10);
  const key = `refs/${userId}/${id}.jpg`;
  await env.IMAGES.put(key, bytes, {
    httpMetadata: { contentType: "image/jpeg" },
  });
  const style = await describeStyle(env, bytes);
  await env.DB.prepare(
    `INSERT INTO refs (id, user_id, r2_key, source, src_url, style, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
  )
    .bind(id, userId, key, source, srcUrl, style, Date.now())
    .run();
  return { id, r2_key: key, style, source, src_url: srcUrl };
}

/** pinimg เก็บหลายขนาดตาม path (170x/236x/474x/736x/originals) — สลับเป็น 474x ให้พอดีกับ klein */
function pinimgSize(u, size = "474x") {
  return u.replace(
    /i\.pinimg\.com\/(\d+x|originals)\//,
    `i.pinimg.com/${size}/`,
  );
}

/**
 * แปลง URL ที่พนักงานวางมาให้เป็นลิงก์รูปตรง
 * - Pinterest หน้า pin/ideas เสิร์ฟ og:image ให้ curl ธรรมดา (ตรวจแล้ว 12 ก.ย. 2026)
 * - FB/IG ส่วนใหญ่ต้องล็อกอิน → ถ้าไม่ได้ให้บอกไปส่งรูปเข้าแชทแทน
 */
async function resolveImageUrl(input) {
  let u;
  try {
    u = new URL(input.trim());
  } catch {
    throw new Error("ลิงก์ไม่ถูกต้อง");
  }
  if (!/^https?:$/.test(u.protocol)) throw new Error("ลิงก์ไม่ถูกต้อง");
  if (/(^|\.)pinimg\.com$/.test(u.hostname)) return pinimgSize(u.href);

  const r = await fetch(u.href, {
    headers: { "user-agent": UA, accept: "text/html,image/*;q=0.9,*/*;q=0.5" },
    redirect: "follow",
  });
  const ct = r.headers.get("content-type") || "";
  if (ct.startsWith("image/")) return u.href;
  if (!ct.includes("text/html")) throw new Error("ลิงก์นี้ไม่ใช่รูปภาพ");

  const page = (await r.text()).slice(0, 1_500_000); // หน้า Pinterest ยาว ~1.2MB พินอยู่ท้าย ๆ
  const og =
    page.match(
      /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i,
    )?.[1] ||
    page.match(
      /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i,
    )?.[1] ||
    page.match(
      /<meta[^>]+name=["']og:image["'][^>]+content=["']([^"']+)["']/i,
    )?.[1];
  // หน้า ideas/board ไม่มี og:image ที่เป็นพิน → หยิบพินรูปแรกในหน้าแทน
  const firstPin = !og && page.match(/https:\/\/i\.pinimg\.com\/\d+x\/[a-z0-9/]+\.(?:jpg|jpeg|png|webp)/i)?.[0];
  if (firstPin) return pinimgSize(firstPin);
  if (!og || !/^https?:\/\//.test(og)) {
    throw new Error(
      "ดึงรูปจากลิงก์นี้ไม่ได้ (FB/IG มักต้องล็อกอิน) — เซฟรูปแล้วส่งเข้าแชทบอทแทนได้เลยค่ะ",
    );
  }
  return /pinimg\.com/.test(og) ? pinimgSize(og) : og;
}

async function downloadImage(url, maxBytes = 8 * 1024 * 1024) {
  const r = await fetch(url, {
    headers: { "user-agent": UA, accept: "image/*,*/*;q=0.5" },
    redirect: "follow",
  });
  if (!r.ok) throw new Error(`โหลดรูปไม่ได้ (${r.status})`);
  const ct = r.headers.get("content-type") || "";
  if (!ct.startsWith("image/")) throw new Error("ลิงก์นี้ไม่ใช่รูปภาพ");
  const buf = await r.arrayBuffer();
  if (buf.byteLength > maxBytes) throw new Error("รูปใหญ่เกิน 8MB");
  return new Uint8Array(buf);
}

async function handleRefs(request, env) {
  const user = await requireUser(request, env);
  if (!user) return json({ ok: false, error: "unauthorized" }, 401);
  const rows = await env.DB.prepare(
    `SELECT id, r2_key, source, src_url, style, created_at FROM refs WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 12`,
  )
    .bind(user.id)
    .all();
  return json({ ok: true, items: rows.results || [] });
}

async function handleRefUrl(request, env) {
  const user = await requireUser(request, env);
  if (!user) return json({ ok: false, error: "unauthorized" }, 401);
  const body = await request.json().catch(() => ({}));
  const input = String(body.url || "").slice(0, 2000);
  if (!input) return json({ ok: false, error: "วางลิงก์ก่อนค่ะ" }, 400);
  try {
    const imgUrl = await resolveImageUrl(input);
    const bytes = await downloadImage(imgUrl);
    const source = /pinterest\.|pinimg\./.test(input) ? "pinterest" : "url";
    const ref = await storeRef(env, user.id, bytes, {
      source,
      srcUrl: input.slice(0, 500),
    });
    return json({ ok: true, ref });
  } catch (err) {
    return json(
      { ok: false, error: String(err?.message || err).slice(0, 200) },
      400,
    );
  }
}

async function handleRefDel(request, env) {
  const user = await requireUser(request, env);
  if (!user) return json({ ok: false, error: "unauthorized" }, 401);
  const body = await request.json().catch(() => ({}));
  const row = await env.DB.prepare(
    `SELECT r2_key FROM refs WHERE id = ?1 AND user_id = ?2`,
  )
    .bind(String(body.id || ""), user.id)
    .first();
  if (!row) return json({ ok: false, error: "ไม่พบรูป" }, 404);
  await env.IMAGES.delete(row.r2_key).catch(() => {});
  await env.DB.prepare(`DELETE FROM refs WHERE id = ?1`)
    .bind(String(body.id))
    .run();
  return json({ ok: true });
}

/** ตรวจว่าจาก edge ดึง URL นี้ได้ไหม — เฉพาะแอดมิน ใช้ตอนไล่ปัญหา pinimg/Pinterest บล็อก */
async function handleDebugFetch(url, request, env) {
  const user = await requireUser(request, env);
  if (!user || user.id !== String(env.ADMIN_ID || ""))
    return json({ ok: false, error: "forbidden" }, 403);
  const u = url.searchParams.get("u") || "";
  const r = await fetch(u, {
    headers: { "user-agent": UA, accept: "text/html,image/*;q=0.9,*/*;q=0.5" },
    redirect: "follow",
  });
  const ct = r.headers.get("content-type") || "";
  const body = ct.startsWith("image/")
    ? `<${(await r.arrayBuffer()).byteLength} bytes>`
    : (await r.text()).slice(0, 600);
  return json({
    ok: true,
    status: r.status,
    ct,
    server: r.headers.get("server"),
    body,
  });
}

// ── ไอเดียจาก Pinterest ─────────────────────────────────────────────────

/**
 * หน้า search ของ Pinterest เป็น JS ล้วน (curl ได้ 0 รูป) แต่หน้า ideas/pin เสิร์ฟ HTML พร้อมรูป
 * → ใช้ Firecrawl หา URL หน้า ideas (เสียเครดิตต่อคำค้น) แล้ว worker ดึงรูปจากหน้าเหล่านั้นเองฟรี · แคช 7 วัน
 */
async function handleIdeas(url, request, env) {
  const user = await requireUser(request, env);
  if (!user) return json({ ok: false, error: "unauthorized" }, 401);

  const v = VERTICALS[url.searchParams.get("v")] || VERTICALS.casino;
  const q = String(url.searchParams.get("q") || "")
    .trim()
    .slice(0, 80);
  const keyword = (q || v.keywords[0]).toLowerCase();

  const cached = await env.DB.prepare(
    `SELECT items, fetched_at FROM ideas WHERE keyword = ?1`,
  )
    .bind(keyword)
    .first();
  if (cached && Date.now() - cached.fetched_at < 7 * 86400_000) {
    return json({
      ok: true,
      keyword,
      items: JSON.parse(cached.items),
      cached: true,
    });
  }
  if (!env.FIRECRAWL_API_KEY)
    return json({ ok: false, error: "ยังไม่ได้ตั้งค่า Firecrawl" }, 503);

  try {
    const sr = await fetch("https://api.firecrawl.dev/v2/search", {
      method: "POST",
      headers: {
        authorization: `Bearer ${env.FIRECRAWL_API_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        query: `site:pinterest.com ${keyword}`,
        limit: 5,
      }),
    });
    const sj = await sr.json().catch(() => ({}));
    const pages = (sj?.data?.web || sj?.data || [])
      .map((x) => x?.url)
      .filter(
        (u) =>
          typeof u === "string" && /pinterest\.[a-z.]+\/(ideas|pin)\//.test(u),
      )
      .slice(0, 5);

    const seen = new Set();
    const items = [];
    await Promise.all(
      pages.map(async (page) => {
        try {
          const r = await fetch(page, {
            headers: { "user-agent": UA, accept: "text/html" },
          });
          const t = (await r.text()).slice(0, 1_500_000);
          // เอาเฉพาะรูปที่มี size variant (170x/236x/...) — path originals/*.png คือ asset ของ Pinterest เอง ไม่ใช่พิน
          for (const m of t.matchAll(
            /https:\/\/i\.pinimg\.com\/\d+x\/[a-z0-9/]+\.(?:jpg|jpeg|png|webp)/gi,
          )) {
            const id = m[0].replace(/^.*\/\d+x\//, "");
            if (seen.has(id)) continue;
            seen.add(id);
            items.push({
              thumb: pinimgSize(m[0], "236x"),
              full: pinimgSize(m[0], "474x"),
              page,
            });
          }
        } catch (err) {
          console.warn("ideas page", page, String(err?.message || err));
        }
      }),
    );
    const top = items.slice(0, 30);
    if (top.length) {
      await env.DB.prepare(
        `INSERT INTO ideas (keyword, items, fetched_at) VALUES (?1, ?2, ?3)
         ON CONFLICT (keyword) DO UPDATE SET items = excluded.items, fetched_at = excluded.fetched_at`,
      )
        .bind(keyword, JSON.stringify(top), Date.now())
        .run();
    }
    return json({ ok: true, keyword, items: top, cached: false });
  } catch (err) {
    console.error("ideas", String(err?.message || err));
    return json(
      { ok: false, error: "ค้นไอเดียไม่สำเร็จ ลองใหม่อีกครั้ง" },
      502,
    );
  }
}

// ── ฝั่งแชท ─────────────────────────────────────────────────────────────

const VERTICAL_CMDS = {
  "/ball": "ball",
  "/lotto": "lotto",
  "/muay": "muay",
  "/casino": "casino",
  "/slot": "slot",
};

function appButton(env, vertical) {
  const u = vertical
    ? `${env.PUBLIC_BASE_URL}/?v=${vertical}`
    : env.PUBLIC_BASE_URL;
  return {
    inline_keyboard: [[{ text: "🎨 เปิดหน้าสร้างภาพ", web_app: { url: u } }]],
  };
}

async function handleWebhook(request, env, ctx) {
  if (
    env.TG_WEBHOOK_SECRET &&
    request.headers.get("x-telegram-bot-api-secret-token") !==
      env.TG_WEBHOOK_SECRET
  ) {
    return text("forbidden", 403);
  }

  const update = await request.json().catch(() => null);
  const msg = update?.message;
  if (!msg?.chat?.id) return text("ok");
  if (msg.chat.type !== "private") return text("ok"); // บอทนี้คุยในแชทส่วนตัวเท่านั้น

  const chatId = msg.chat.id;
  const from = msg.from || {};

  // รูปที่ส่งมา = รูปอ้างอิง (จาก FB/IG/Pinterest ที่พนักงานเซฟมา)
  const photo = pickPhoto(msg);
  if (photo) {
    ctx.waitUntil(ingestChatPhoto(env, chatId, from, photo));
    return text("ok");
  }

  const raw = (msg.text || "").trim();
  const cmd = raw.toLowerCase().split(/\s+/)[0].split("@")[0];

  if (cmd === "/start" || cmd === "/help" || cmd === "/app") {
    ctx.waitUntil(
      api(env, "sendMessage", {
        chat_id: chatId,
        text: [
          "🎨 <b>Graphic BOT 888</b> — กราฟิกสายพนันโดยเฉพาะ",
          "⚽ บอล · 🎱 หวย · 🥊 มวย · 🃏 คาสิโน · 🎰 สล็อต",
          "",
          "<b>วิธีใช้</b>",
          "1. กดปุ่มข้างล่าง เลือกสาย · โทน · ขนาด แล้วกดสร้าง",
          "2. อยากได้ลุคเหมือนรูปที่เห็นใน FB/IG/Pinterest → <b>ส่งรูปนั้นมาในแชทนี้</b> หรือวางลิงก์ในแอป",
          "3. รูปที่เสร็จจะเด้งกลับมาในแชทนี้ ใช้พร้อมกันหลายคนได้",
          "",
          "ทางลัด: /ball /lotto /muay /casino /slot",
          `โควตาคนละ <b>${env.DAILY_QUOTA || 15}</b> รูป/วัน`,
        ].join("\n"),
        parse_mode: "HTML",
        reply_markup: appButton(env),
      }),
    );
    return text("ok");
  }

  if (VERTICAL_CMDS[cmd]) {
    const v = VERTICAL_CMDS[cmd];
    ctx.waitUntil(
      api(env, "sendMessage", {
        chat_id: chatId,
        text: `${VERTICALS[v].label} — ${VERTICALS[v].hint}\nกดปุ่มเพื่อเริ่มสร้างภาพสายนี้`,
        reply_markup: appButton(env, v),
      }),
    );
    return text("ok");
  }

  if (cmd === "/ref") {
    ctx.waitUntil(
      api(env, "sendMessage", {
        chat_id: chatId,
        text: [
          "🖼 <b>รูปอ้างอิง</b> — ให้ AI วาดตามลุคของรูปที่ชอบ",
          "",
          "• ส่งรูปเข้ามาในแชทนี้ได้เลย (เซฟจาก FB / IG / Pinterest / TikTok)",
          '• หรือวางลิงก์ Pinterest ในแอปตรงช่อง "รูปอ้างอิง"',
          '• หรือกด "💡 ไอเดีย Pinterest" ในแอป แล้วแตะรูปที่ชอบ',
          "",
          "AI ใช้แค่โทนสี แสง และการจัดวาง — วาดฉากใหม่ทั้งหมด ไม่ได้ก๊อปรูป",
        ].join("\n"),
        parse_mode: "HTML",
        reply_markup: appButton(env),
      }),
    );
    return text("ok");
  }

  if (cmd === "/id") {
    ctx.waitUntil(
      api(env, "sendMessage", {
        chat_id: chatId,
        text: `chat id: ${chatId}\nuser id: ${from.id}`,
      }),
    );
    return text("ok");
  }

  if (raw) {
    ctx.waitUntil(
      api(env, "sendMessage", {
        chat_id: chatId,
        text: "หนูรับคำสั่งผ่านหน้าแอปค่ะ กดปุ่มด้านล่าง หรือส่ง<b>รูป</b>มาเพื่อใช้เป็นรูปอ้างอิง",
        parse_mode: "HTML",
        reply_markup: appButton(env),
      }),
    );
  }
  return text("ok");
}

/** เลือกไฟล์รูปจากข้อความ — Telegram ให้หลายขนาดมาแล้ว เอาอันใหญ่สุดที่ยังไม่เกิน 512 จะได้ไม่ต้องย่อ */
function pickPhoto(msg) {
  if (Array.isArray(msg.photo) && msg.photo.length) {
    const fit = msg.photo.filter(
      (p) => Math.max(p.width || 0, p.height || 0) <= 512,
    );
    const pick = (fit.length ? fit : msg.photo).sort(
      (a, b) => (b.width || 0) - (a.width || 0),
    )[0];
    return { file_id: pick.file_id };
  }
  if (
    msg.document &&
    /^image\/(jpeg|png|webp)$/.test(msg.document.mime_type || "") &&
    msg.document.file_size < 8e6
  ) {
    return { file_id: msg.document.file_id };
  }
  return null;
}

async function ingestChatPhoto(env, chatId, from, photo) {
  try {
    const user = await upsertUser(env, from.id || chatId, displayName(from));
    if (user.blocked) return;
    const f = await api(env, "getFile", { file_id: photo.file_id });
    if (!f.ok) throw new Error("getFile: " + f.description);
    const r = await fetch(
      `${TG_API}/file/bot${env.BOT_TOKEN}/${f.result.file_path}`,
    );
    const bytes = new Uint8Array(await r.arrayBuffer());
    const ref = await storeRef(env, user.id, bytes, { source: "chat" });
    await api(env, "sendMessage", {
      chat_id: chatId,
      text: [
        "✅ บันทึกรูปอ้างอิงแล้ว",
        ref.style
          ? `<i>${escapeHtml(ref.style.slice(0, 200))}${ref.style.length > 200 ? "…" : ""}</i>`
          : "",
        "",
        'เปิดแอป → รูปนี้จะถูกเลือกไว้ให้ในช่อง "รูปอ้างอิง" แล้วเลือกสาย/โทน/ขนาด กดสร้างได้เลย',
      ]
        .filter((x) => x !== "")
        .join("\n"),
      parse_mode: "HTML",
      reply_markup: appButton(env),
    });
  } catch (err) {
    console.error("ingestChatPhoto", String(err?.message || err));
    await api(env, "sendMessage", {
      chat_id: chatId,
      text: "❌ รับรูปไม่สำเร็จ ลองส่งใหม่อีกครั้งค่ะ",
    });
  }
}

async function api(env, method, payload) {
  const r = await fetch(`${TG_API}/bot${env.BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  const out = await r.json().catch(() => ({}));
  if (!out.ok) console.error(method, out.description || r.status);
  return out;
}

async function sendPhoto(env, chatId, bytes, caption) {
  const form = new FormData();
  form.set("chat_id", String(chatId));
  form.set("caption", caption);
  form.set("parse_mode", "HTML");
  form.set("photo", new Blob([bytes], { type: "image/jpeg" }), "graphic.jpg");
  const r = await fetch(`${TG_API}/bot${env.BOT_TOKEN}/sendPhoto`, {
    method: "POST",
    body: form,
  });
  const out = await r.json().catch(() => ({}));
  if (!out.ok) console.error("sendPhoto", out.description);
  return out;
}

// ── helpers ─────────────────────────────────────────────────────────────

const escapeHtml = (s) =>
  String(s).replace(
    /[<>&]/g,
    (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" })[c],
  );

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

const text = (body, status = 200) =>
  new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });

const html = (body) =>
  new Response(body, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
