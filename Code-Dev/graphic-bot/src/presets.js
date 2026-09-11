/**
 * สูตรภาพสายพนัน — บอทตัวนี้ทำแค่ 5 สายเท่านั้น: บอล หวย มวย คาสิโน สล็อต
 *
 * ทำไมล็อกสาย: พี่ Mosses สั่งให้เป็นบอท "เชี่ยวชาญกราฟิกสายพนันเท่านั้น" (12 ก.ย. 2026)
 * พนักงานเลือกสาย + โทน + ขนาด แล้วพิมพ์รายละเอียดเพิ่มได้ แต่ข้อความนอกเรื่องจะถูกตัดออก (ดู topicGuard ใน index.js)
 *
 * ทุกสูตรเป็น "plate เปล่า" — FLUX เขียนตัวอักษรไทยไม่ได้ ตัวเลขมักเพี้ยน ข้อความ/โลโก้ไปวางทับทีหลัง
 */

// ท่อนคุณภาพที่พิสูจน์แล้วว่าให้ลุค "เหมือนคนถ่ายจริง" ไม่ใช่กราฟิก AI
const PHOTOREAL =
  "photorealistic, hyper-detailed, true-to-life materials textures and reflections, " +
  "physically-accurate dramatic lighting, professional advertising photography, cinematic color grade, 8K";

const NOTEXT =
  "no text, no letters, no numbers, no watermark, clean empty space reserved for headline copy";

/** โทนภาพ — soft ผ่านตัวกรอง FB/IG ง่ายกว่า · hard สำหรับกลุ่มปิด/LINE */
export const TONES = {
  soft: { label: "🤍 กึ่งขาว", hint: "ไม่มีสัญลักษณ์พนันโจ่งแจ้ง โพสต์ FB/IG ได้" },
  hard: { label: "🔥 เต็มตัว", hint: "ชิป ไพ่ เงิน สล็อต จัดเต็ม สำหรับกลุ่มปิด/LINE" },
};

/** ขนาดภาพ — klein-4b กำหนด width/height ได้ (schnell ล็อก 1024²) ตัวเลขต้องหาร 16 ลงตัว */
export const SIZES = {
  square: { label: "◼ 1:1", hint: "โพสต์ FB", w: 1024, h: 1024 },
  portrait: { label: "▮ 4:5", hint: "ฟีด IG/FB", w: 896, h: 1120 },
  story: { label: "▯ 9:16", hint: "สตอรี่/Reels", w: 768, h: 1344 },
  wide: { label: "▬ 16:9", hint: "ปกเพจ/แบนเนอร์", w: 1344, h: 768 },
};

export const VERTICALS = {
  ball: {
    label: "⚽ บอล",
    hint: "สนามบอล นักเตะ ถ้วยแชมป์ โทนน้ำเงิน-ทอง / เขียวสนาม",
    keywords: ["football betting poster design", "sports betting banner"],
    soft:
      "Premium football advertising background plate: floodlit football stadium at night seen from pitch level, " +
      "fictional athletic player in a plain unbranded jersey in dynamic action, dramatic stadium spotlights and light rays, " +
      "flying grass particles, packed blurred crowd, deep navy and gold color grade, premium sports-lifestyle mood",
    hard:
      "Football betting promotional background plate: golden football trophy and a glowing football on a reflective black surface, " +
      "stacks of gold coins and banknotes around it, blurred floodlit stadium behind, gold neon rim light, " +
      "golden particles and light streaks, deep navy black and gold palette, luxury jackpot mood",
  },

  lotto: {
    label: "🎱 หวย",
    hint: "ลูกบอลตัวเลข เงินทอง โชคลาภ โทนแดง-ทอง / เขียว-ทอง",
    keywords: ["lottery poster design", "lucky jackpot banner design"],
    soft:
      "Lucky fortune advertising background plate: glowing golden lottery balls floating in the air, gold coins and golden light bokeh, " +
      "elegant Thai-inspired gold ornaments and lotus motifs, deep crimson and gold gradient backdrop, soft dramatic spotlight, " +
      "auspicious prosperous mood, wide empty space for headline copy",
    hard:
      "Lottery jackpot promotional background plate: a burst of golden lottery balls, piles of banknotes and gold bars, " +
      "golden coins raining down, giant golden ingot, glossy reflective black-red surface, gold neon glow, " +
      "confetti and sparkles, rich prosperous jackpot mood, empty center space for a big number",
  },

  muay: {
    label: "🥊 มวย",
    hint: "สังเวียน นวม ชกกลางแสงไฟ โทนแดง-ดำ / น้ำเงิน-แดง",
    keywords: ["muay thai fight poster design", "boxing event poster"],
    soft:
      "Muay Thai fight night advertising background plate: dramatic boxing ring under spotlight with smoke and haze, " +
      "fictional fighter in plain shorts and gloves in a powerful stance seen from behind, ropes glowing with rim light, " +
      "dust and sweat particles in the air, deep red and black color grade with electric blue accent, intense epic mood",
    hard:
      "Muay Thai betting promotional background plate: red and blue boxing gloves clashing at center with impact sparks, " +
      "golden championship belt and gold coins on a reflective surface, dark ring with dramatic spotlight beams, " +
      "gold neon rim light, red black and gold palette, high-energy jackpot mood, empty space at top for headline",
  },

  casino: {
    label: "🃏 คาสิโน",
    hint: "ไพ่ ชิป รูเล็ต ลูกเต๋า บาคาร่า โทนดำ-ทอง-แดง หรูหรา",
    keywords: ["casino poster design", "baccarat promotion banner"],
    soft:
      "Luxury nightlife advertising background plate: elegant dark lounge with golden chandelier bokeh, " +
      "glossy black marble table with a single golden dice and champagne glass, deep black and gold palette with crimson accent, " +
      "dramatic spotlight from above, premium exclusive VIP mood, wide empty space for headline copy",
    hard:
      "Luxury online casino promotional background plate: golden roulette wheel, fanned playing cards, stacks of red and gold casino chips, " +
      "golden dice mid-air, gold coins bursting, deep black and crimson backdrop with gold neon rim light, " +
      "dramatic spotlight, glossy reflective surface, premium jackpot mood, empty space at top for headline",
  },

  slot: {
    label: "🎰 สล็อต",
    hint: "วงล้อสล็อต 777 เหรียญกระจาย นีออน โทนม่วง-ทอง / แดง-ทอง",
    keywords: ["slot game poster design", "slot jackpot banner"],
    soft:
      "Vibrant game-night advertising background plate: glowing neon arcade lights and bokeh, golden light streaks, " +
      "purple magenta and gold gradient backdrop, floating golden particles and confetti, glossy reflective floor, " +
      "fun exciting premium mood, wide empty space for headline copy",
    hard:
      "Slot jackpot promotional background plate: giant golden slot machine reels glowing with lucky sevens and fruit symbols, " +
      "explosion of gold coins and sparkles, purple and gold neon lights, dramatic spotlight, glossy reflective surface, " +
      "mega-win celebration mood, empty space at top for headline",
  },
};

/**
 * ประกอบ prompt สุดท้าย
 * - styleText: คำบรรยายสไตล์ที่ vision model อ่านจากรูปอ้างอิง (ถ้ามี)
 * - hasRef: มีรูปอ้างอิงส่งเข้า klein ด้วย → ต้องบอกโมเดลว่าเป็น "แรงบันดาลใจ" ไม่ใช่ให้ก๊อป
 * FLUX รับได้ ~2000 ตัวอักษร ตัดกันพังไว้ก่อน
 */
export function buildPrompt({ vertical, tone, extra = "", styleText = "", hasRef = false }) {
  const v = VERTICALS[vertical];
  if (!v) return null;
  const parts = [];
  if (hasRef) {
    parts.push(
      "Use image 0 only as inspiration for color palette, lighting and composition. Create a completely new original scene",
    );
  }
  parts.push(v[tone === "soft" ? "soft" : "hard"]);
  if (styleText) parts.push(`Style reference: ${styleText}`);
  if (extra.trim()) parts.push(extra.trim());
  return `${parts.join(". ")}. ${PHOTOREAL}. ${NOTEXT}`.slice(0, 2000);
}
