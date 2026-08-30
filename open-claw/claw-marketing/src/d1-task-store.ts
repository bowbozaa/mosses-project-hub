import {
  TaskState,
  type ListTasksRequest,
  type ListTasksResponse,
  type Task,
} from "@a2a-js/sdk";
import {
  RequestMalformedError,
  resolveUserScope,
  type ServerCallContext,
  type TaskStore,
} from "@a2a-js/sdk/server";

interface TaskRow {
  task_id: string;
  status_timestamp: string;
  task_json: string;
}

interface CountRow {
  total: number;
}

interface Cursor {
  timestamp: string;
  taskId: string;
}

const DEFAULT_PAGE_SIZE = 50;
const MAX_PAGE_SIZE = 100;

function scope(context: ServerCallContext): { tenant: string; owner: string } {
  return {
    tenant: context.tenant ?? "",
    owner: resolveUserScope(context),
  };
}

function encodeCursor(cursor: Cursor): string {
  const bytes = new TextEncoder().encode(JSON.stringify(cursor));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

function decodeCursor(token: string): Cursor {
  try {
    if (!/^[A-Za-z0-9_-]+$/u.test(token)) throw new Error("invalid encoding");
    const base64 = token.replaceAll("-", "+").replaceAll("_", "/");
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const parsed = JSON.parse(new TextDecoder().decode(bytes)) as Partial<Cursor>;
    if (typeof parsed.timestamp !== "string" || typeof parsed.taskId !== "string") {
      throw new Error("invalid cursor shape");
    }
    return { timestamp: parsed.timestamp, taskId: parsed.taskId };
  } catch (error) {
    if (error instanceof RequestMalformedError) throw error;
    throw new RequestMalformedError("Invalid page token.");
  }
}

function pageSize(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested)) {
    return DEFAULT_PAGE_SIZE;
  }
  return Math.min(MAX_PAGE_SIZE, Math.max(1, Math.trunc(requested)));
}

function shapeTask(
  task: Task,
  historyLength: number | undefined,
  includeArtifacts: boolean,
): Task {
  const result = structuredClone(task);
  if (!includeArtifacts) result.artifacts = [];
  if (historyLength !== undefined) {
    const length = Math.max(0, Math.trunc(historyLength));
    result.history = length === 0 ? [] : result.history?.slice(-length) ?? [];
  }
  return result;
}

export class D1TaskStore implements TaskStore {
  constructor(private readonly db: D1Database) {}

  async save(task: Task, context: ServerCallContext): Promise<void> {
    const { tenant, owner } = scope(context);
    const now = new Date().toISOString();
    await this.db
      .prepare(
        `INSERT INTO a2a_tasks (
          tenant, owner, task_id, context_id, status, status_timestamp,
          task_json, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (tenant, owner, task_id) DO UPDATE SET
          context_id = excluded.context_id,
          status = excluded.status,
          status_timestamp = excluded.status_timestamp,
          task_json = excluded.task_json,
          updated_at = excluded.updated_at`,
      )
      .bind(
        tenant,
        owner,
        task.id,
        task.contextId,
        task.status?.state ?? TaskState.TASK_STATE_UNSPECIFIED,
        task.status?.timestamp ?? "",
        JSON.stringify(task),
        now,
      )
      .run();
  }

  async load(taskId: string, context: ServerCallContext): Promise<Task | undefined> {
    const { tenant, owner } = scope(context);
    const row = await this.db
      .prepare(
        `SELECT task_json
         FROM a2a_tasks
         WHERE tenant = ? AND owner = ? AND task_id = ?`,
      )
      .bind(tenant, owner, taskId)
      .first<Pick<TaskRow, "task_json">>();
    return row ? (JSON.parse(row.task_json) as Task) : undefined;
  }

  async list(
    params: ListTasksRequest,
    context: ServerCallContext,
  ): Promise<ListTasksResponse> {
    const { tenant, owner } = scope(context);
    const conditions = ["tenant = ?", "owner = ?"];
    const values: Array<string | number> = [tenant, owner];

    if (params.contextId) {
      conditions.push("context_id = ?");
      values.push(params.contextId);
    }
    if (
      params.status !== undefined &&
      params.status !== TaskState.TASK_STATE_UNSPECIFIED
    ) {
      conditions.push("status = ?");
      values.push(params.status);
    }
    if (params.statusTimestampAfter) {
      conditions.push("status_timestamp >= ?");
      values.push(params.statusTimestampAfter);
    }

    const filterSql = conditions.join(" AND ");
    const count = await this.db
      .prepare(`SELECT COUNT(*) AS total FROM a2a_tasks WHERE ${filterSql}`)
      .bind(...values)
      .first<CountRow>();

    if (params.pageToken) {
      const cursor = decodeCursor(params.pageToken);
      conditions.push(
        "(status_timestamp < ? OR (status_timestamp = ? AND task_id < ?))",
      );
      values.push(cursor.timestamp, cursor.timestamp, cursor.taskId);
    }

    const effectivePageSize = pageSize(params.pageSize);
    const rows = await this.db
      .prepare(
        `SELECT task_id, status_timestamp, task_json
         FROM a2a_tasks
         WHERE ${conditions.join(" AND ")}
         ORDER BY status_timestamp DESC, task_id DESC
         LIMIT ?`,
      )
      .bind(...values, effectivePageSize + 1)
      .all<TaskRow>();

    const hasNextPage = rows.results.length > effectivePageSize;
    const pageRows = rows.results.slice(0, effectivePageSize);
    const lastRow = pageRows.at(-1);

    return {
      tasks: pageRows.map((row) =>
        shapeTask(
          JSON.parse(row.task_json) as Task,
          params.historyLength,
          params.includeArtifacts ?? false,
        ),
      ),
      nextPageToken:
        hasNextPage && lastRow
          ? encodeCursor({
              timestamp: lastRow.status_timestamp,
              taskId: lastRow.task_id,
            })
          : "",
      pageSize: effectivePageSize,
      totalSize: count?.total ?? 0,
    };
  }
}
