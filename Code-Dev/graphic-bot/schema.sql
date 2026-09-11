-- คิวงานสร้างภาพ — พนักงานหลายคนกดพร้อมกันได้ ทุกงานเป็นแถวเดียวในนี้
CREATE TABLE IF NOT EXISTS jobs (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,
  user_name   TEXT,
  chat_id     TEXT,               -- ปลายทางที่จะส่งรูปกลับ (แชทของคนสั่ง)
  preset      TEXT NOT NULL,
  extra       TEXT,               -- รายละเอียดที่พนักงานพิมพ์เพิ่ม
  prompt      TEXT NOT NULL,
  status      TEXT NOT NULL,      -- queued | running | done | failed
  r2_key      TEXT,
  error       TEXT,
  model       TEXT,
  date_th     TEXT NOT NULL,      -- ใช้นับโควตารายวัน
  created_at  INTEGER NOT NULL,
  finished_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_jobs_user_day ON jobs (user_id, date_th);
CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs (created_at DESC);

-- ทะเบียนคนใช้งาน — รู้ว่าใครใช้ไปเท่าไหร่ และปิดสิทธิ์รายคนได้โดยไม่ต้องแก้โค้ด
CREATE TABLE IF NOT EXISTS users (
  user_id    TEXT PRIMARY KEY,
  user_name  TEXT,
  first_seen TEXT,
  blocked    INTEGER DEFAULT 0,
  quota      INTEGER              -- NULL = ใช้ค่ากลางจาก DAILY_QUOTA
);
