-- Guardian tables — ย้ายมาจาก schema.sql เดิม (idempotent ทั้งหมด
-- เพราะ friclawd-db remote มีตารางเหล่านี้อยู่แล้วจากการรัน schema.sql ครั้งแรก)

CREATE TABLE IF NOT EXISTS task_history (
  id         TEXT PRIMARY KEY,
  agent      TEXT,
  skill      TEXT,
  result     TEXT,
  ok         INTEGER,
  created_at TEXT
);

CREATE TABLE IF NOT EXISTS guardian_policy (
  id               TEXT PRIMARY KEY,
  action_pattern   TEXT,
  risk_level       TEXT,
  requires_approval INTEGER
);

INSERT OR IGNORE INTO guardian_policy (id, action_pattern, risk_level, requires_approval) VALUES
  ('pol_deploy',    'deploy',    'HIGH', 1),
  ('pol_delete',    'delete',    'HIGH', 1),
  ('pol_broadcast', 'broadcast', 'HIGH', 1),
  ('pol_read',      'read',      'LOW',  0);

CREATE TABLE IF NOT EXISTS pending_approvals (
  id           TEXT PRIMARY KEY,
  action       TEXT,
  requested_by TEXT,
  status       TEXT,
  created_at   TEXT
);
