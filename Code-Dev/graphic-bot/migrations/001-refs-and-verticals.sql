-- 2026-09-12: บอทสายพนัน — เพิ่มรูปอ้างอิง + สาย/โทน/ขนาด
ALTER TABLE jobs ADD COLUMN vertical TEXT;
ALTER TABLE jobs ADD COLUMN tone TEXT;
ALTER TABLE jobs ADD COLUMN size TEXT;
ALTER TABLE jobs ADD COLUMN ref_id TEXT;

-- รูปอ้างอิงที่พนักงานส่งเข้ามา (จากแชท / URL / Pinterest) เก็บย่อ ≤512px ใน R2
CREATE TABLE IF NOT EXISTS refs (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  r2_key     TEXT NOT NULL,
  source     TEXT NOT NULL,   -- chat | url | pinterest
  src_url    TEXT,
  style      TEXT,            -- คำบรรยายสไตล์จาก vision model
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_refs_user ON refs (user_id, created_at DESC);

-- แคชผลค้นไอเดีย Pinterest ต่อคำค้น — Firecrawl คิดเครดิตต่อครั้ง ค้นซ้ำต้องไม่เสียซ้ำ
CREATE TABLE IF NOT EXISTS ideas (
  keyword    TEXT PRIMARY KEY,
  items      TEXT NOT NULL,   -- JSON [{thumb, full, page}]
  fetched_at INTEGER NOT NULL
);
