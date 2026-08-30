CREATE TABLE a2a_tasks (
  tenant TEXT NOT NULL,
  owner TEXT NOT NULL,
  task_id TEXT NOT NULL,
  context_id TEXT NOT NULL,
  status INTEGER,
  status_timestamp TEXT NOT NULL,
  task_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant, owner, task_id)
);

CREATE INDEX idx_a2a_tasks_list
  ON a2a_tasks (tenant, owner, status_timestamp DESC, task_id DESC);

CREATE INDEX idx_a2a_tasks_context
  ON a2a_tasks (tenant, owner, context_id, status_timestamp DESC, task_id DESC);
