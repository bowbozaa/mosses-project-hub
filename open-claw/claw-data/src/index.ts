// claw-data — Open Claw Data Agent (A2A v1.0)
// deterministic: query D1 tables + Flyday Brain knowledge search
//
// v2.0.0 — migrate ขึ้น A2A v1.0 ด้วย official @a2a-js/sdk (ยึดโค้ด live เป็นฐาน):
//   - discovery ใหม่:  GET  /.well-known/agent-card.json   (A2A v1)
//   - JSON-RPC ใหม่:   POST /a2a/jsonrpc  (SendMessage + x-a2a-key + A2A-Version: 1.0)
//   - legacy คงไว้:    GET  /.well-known/agent.json, POST / (message/send), /health

import {
  A2A_VERSION_HEADER,
  AGENT_CARD_PATH,
  AgentCard,
  Role,
  TaskState,
  type Artifact,
  type Message,
  type Task,
} from "@a2a-js/sdk";
import {
  AgentEvent,
  DefaultRequestHandler,
  JsonRpcTransportHandler,
  ServerCallContext,
  type AgentExecutor,
  type ExecutionEventBus,
  type RequestContext,
} from "@a2a-js/sdk/server";

import { D1TaskStore } from "./d1-task-store";

export interface Env {
  DB: D1Database;
  AGENT_NAME: string;
  AGENT_SKILL_ID: string;
  AGENT_URL?: string;
  A2A_SHARED_KEY?: string;
  BRAIN_API_URL: string;
  BRAIN_API_KEY?: string;
}

const PROTOCOL_VERSION = "1.0";
const JSON_RPC_PATH = "/a2a/jsonrpc";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, x-a2a-key, A2A-Version",
};

// ── Agent Card (A2A v1) ──
function securityRequirement() {
  return { schemes: { a2aSharedKey: { list: [] } } };
}

type AgentIdentity = Pick<Env, "AGENT_NAME" | "AGENT_SKILL_ID" | "AGENT_URL">;

const SKILL_META = {
  name: "Data Query & Report",
  description: "query D1 task_history/guardian_policy หรือ search Flyday Brain",
  tags: ["data", "query", "d1", "brain", "report"],
  examples: [
    '{"op":"d1_recent","limit":10}',
    '{"op":"brain_search","query":"FRIDAY project status"}',
  ],
};

export function buildAgentCard(env: AgentIdentity, origin: string): AgentCard {
  const baseUrl = env.AGENT_URL || origin;
  const interfaceUrl = new URL(JSON_RPC_PATH, baseUrl).toString();
  const requirement = securityRequirement();

  return {
    name: env.AGENT_NAME || "Data Agent",
    description:
      "Query D1 tables และ Flyday Brain knowledge search — deterministic",
    supportedInterfaces: [
      {
        url: interfaceUrl,
        protocolBinding: "JSONRPC",
        protocolVersion: PROTOCOL_VERSION,
        tenant: "",
      },
    ],
    provider: undefined,
    version: "2.0.0",
    documentationUrl: undefined,
    capabilities: {
      streaming: false,
      pushNotifications: false,
      extensions: [],
      extendedAgentCard: false,
    },
    securitySchemes: {
      a2aSharedKey: {
        scheme: {
          $case: "apiKeySecurityScheme",
          value: {
            description:
              "Shared key provisioned as a Cloudflare Worker secret.",
            location: "header",
            name: "x-a2a-key",
          },
        },
      },
    },
    securityRequirements: [requirement],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: [
      {
        id: env.AGENT_SKILL_ID || "data_query_report",
        ...SKILL_META,
        inputModes: ["application/json"],
        outputModes: ["application/json"],
        securityRequirements: [requirement],
      },
    ],
    signatures: [],
    iconUrl: undefined,
  };
}

// ── Legacy Agent Card ──
export function buildLegacyAgentCard(env: AgentIdentity, origin: string) {
  const url = env.AGENT_URL || origin;
  return {
    name: env.AGENT_NAME || "Data Agent",
    description:
      "Query D1 tables และ Flyday Brain knowledge search — deterministic",
    version: "2.0.0",
    supportedInterfaces: [
      { url, protocolBinding: "JSONRPC", protocolVersion: "1.0" },
    ],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: [{ id: env.AGENT_SKILL_ID || "data_query_report", ...SKILL_META }],
  };
}

// ── shared helpers ──
export function extractDataInput(message: Message): Record<string, unknown> {
  for (const part of message.parts) {
    if (part.content?.$case !== "data") continue;
    const value = part.content.value;
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
  }
  return {};
}

export function taskStateForResult(result: Record<string, unknown>): TaskState {
  return result.verdict === "FAIL"
    ? TaskState.TASK_STATE_REJECTED
    : TaskState.TASK_STATE_COMPLETED;
}

// ── JSON-RPC helpers (legacy path) ──
function rpcResult(id: unknown, result: unknown) {
  return Response.json({ jsonrpc: "2.0", id, result }, { headers: CORS });
}
function rpcError(id: unknown, code: number, message: string) {
  return Response.json(
    { jsonrpc: "2.0", id, error: { code, message } },
    { headers: CORS },
  );
}

// ── Log task ลง D1 ──
async function logTask(
  env: Env,
  skillId: string,
  result: unknown,
  ok: boolean,
) {
  try {
    await env.DB.prepare(
      "INSERT INTO task_history (id, agent, skill, result, ok, created_at) VALUES (?,?,?,?,?,?)",
    )
      .bind(
        "task_" + crypto.randomUUID().slice(0, 8),
        env.AGENT_NAME,
        skillId,
        JSON.stringify(result),
        ok ? 1 : 0,
        new Date().toISOString(),
      )
      .run();
  } catch (_) {
    // log ล้มไม่ควรทำ agent ตาย
  }
}

// ── Data skill logic (ตรงกับ live) ──
export async function runDataSkill(
  input: Record<string, unknown>,
  env: Env,
): Promise<Record<string, unknown>> {
  const op = String(input.op ?? "").toLowerCase();

  if (op === "d1_recent") {
    const limit = Math.min(Number(input.limit ?? 10), 100);
    const { results } = await env.DB.prepare(
      `SELECT id, agent, skill, ok, created_at
       FROM task_history
       ORDER BY created_at DESC
       LIMIT ?`,
    )
      .bind(limit)
      .all();
    return { op, rows: results, count: results.length };
  }

  if (op === "d1_policy") {
    const { results } = await env.DB.prepare(
      `SELECT * FROM guardian_policy ORDER BY risk_level DESC`,
    ).all();
    return { op, rows: results, count: results.length };
  }

  if (op === "brain_search") {
    const query = String(input.query ?? "").trim();
    if (!query) {
      return {
        verdict: "FAIL",
        reason: "missing 'query' field for brain_search",
      };
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);
    try {
      const res = await fetch(
        `${env.BRAIN_API_URL}/api/search?q=${encodeURIComponent(query)}&limit=5`,
        {
          headers: { Authorization: `Bearer ${env.BRAIN_API_KEY ?? ""}` },
          signal: controller.signal,
        },
      );
      clearTimeout(timeout);
      if (!res.ok) {
        const text = await res.text();
        return { verdict: "FAIL", reason: `Brain API ${res.status}: ${text}` };
      }
      const data = await res.json();
      return { op, query, results: data };
    } catch (e: any) {
      clearTimeout(timeout);
      return {
        verdict: "FAIL",
        reason:
          e.name === "AbortError" ? "brain_search timeout (10s)" : String(e),
      };
    }
  }

  return {
    verdict: "FAIL",
    reason: "unknown op, use d1_recent|d1_policy|brain_search",
  };
}

// ── A2A v1 executor ──
class DataExecutor implements AgentExecutor {
  private readonly canceledTasks = new Set<string>();

  constructor(private readonly env: Env) {}

  cancelTask = async (taskId: string): Promise<void> => {
    this.canceledTasks.add(taskId);
  };

  async execute(
    requestContext: RequestContext,
    eventBus: ExecutionEventBus,
  ): Promise<void> {
    const { contextId, taskId, userMessage } = requestContext;
    const task: Task = requestContext.task ?? {
      id: taskId,
      contextId,
      status: {
        state: TaskState.TASK_STATE_SUBMITTED,
        message: undefined,
        timestamp: new Date().toISOString(),
      },
      artifacts: [],
      history: [userMessage],
      metadata: userMessage.metadata,
    };
    eventBus.publish(AgentEvent.task(task));

    if (this.canceledTasks.delete(taskId)) {
      eventBus.publish(
        AgentEvent.statusUpdate({
          taskId,
          contextId,
          status: {
            state: TaskState.TASK_STATE_CANCELED,
            message: undefined,
            timestamp: new Date().toISOString(),
          },
          metadata: undefined,
        }),
      );
      return;
    }

    const result = await runDataSkill(extractDataInput(userMessage), this.env);
    await logTask(this.env, this.env.AGENT_SKILL_ID, result, true);

    const artifact: Artifact = {
      artifactId: crypto.randomUUID(),
      name: "data-result",
      description: "Deterministic data query result.",
      parts: [
        {
          content: { $case: "data", value: result },
          metadata: undefined,
          filename: "",
          mediaType: "application/json",
        },
      ],
      metadata: undefined,
      extensions: [],
    };
    eventBus.publish(
      AgentEvent.artifactUpdate({
        taskId,
        contextId,
        artifact,
        append: false,
        lastChunk: true,
        metadata: undefined,
      }),
    );
    eventBus.publish(
      AgentEvent.statusUpdate({
        taskId,
        contextId,
        status: {
          state: taskStateForResult(result),
          message: {
            messageId: crypto.randomUUID(),
            contextId,
            taskId,
            role: Role.ROLE_AGENT,
            parts: artifact.parts,
            metadata: undefined,
            extensions: [],
            referenceTaskIds: [],
          },
          timestamp: new Date().toISOString(),
        },
        metadata: undefined,
      }),
    );
  }
}

// ── v1 response helpers ──
function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { ...CORS, [A2A_VERSION_HEADER]: PROTOCOL_VERSION },
  });
}

function isAsyncIterable(
  value: unknown,
): value is AsyncGenerator<Record<string, unknown>, void, undefined> {
  return Boolean(
    value && typeof value === "object" && Symbol.asyncIterator in value,
  );
}

function streamingResponse(
  events: AsyncGenerator<Record<string, unknown>, void, undefined>,
): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const event of events) {
          controller.enqueue(
            encoder.encode(`data: ${JSON.stringify(event)}\n\n`),
          );
        }
      } finally {
        controller.close();
      }
    },
  });
  return new Response(stream, {
    headers: {
      ...CORS,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      [A2A_VERSION_HEADER]: PROTOCOL_VERSION,
    },
  });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const origin = `${url.protocol}//${url.host}`;

    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

    // ── Discovery v1: Agent Card ──
    if (req.method === "GET" && url.pathname === `/${AGENT_CARD_PATH}`) {
      const card = buildAgentCard(env, origin);
      return jsonResponse(AgentCard.toJSON(card));
    }

    // ── Discovery legacy ──
    if (url.pathname === "/.well-known/agent.json") {
      return Response.json(buildLegacyAgentCard(env, origin), {
        headers: CORS,
      });
    }

    // ── /health — monitoring probe ──
    if (url.pathname === "/health") {
      return Response.json(
        {
          ok: true,
          agent: env.AGENT_NAME,
          version: "2.0.0",
          ts: new Date().toISOString(),
        },
        { headers: CORS },
      );
    }

    // ── A2A v1: JSON-RPC ผ่าน official SDK ──
    if (req.method === "POST" && url.pathname === JSON_RPC_PATH) {
      if (
        !env.A2A_SHARED_KEY ||
        req.headers.get("x-a2a-key") !== env.A2A_SHARED_KEY
      ) {
        return jsonResponse({ error: "unauthorized" }, 401);
      }
      if (req.headers.get(A2A_VERSION_HEADER) !== PROTOCOL_VERSION) {
        return jsonResponse({ error: "A2A-Version 1.0 is required" }, 400);
      }

      const card = buildAgentCard(env, origin);
      const requestHandler = new DefaultRequestHandler(
        card,
        new D1TaskStore(env.DB),
        new DataExecutor(env),
      );
      const context = new ServerCallContext({
        requestedVersion: PROTOCOL_VERSION,
        user: { isAuthenticated: true, userName: "shared-key-client" },
      });
      const transport = new JsonRpcTransportHandler(requestHandler);
      const result = await transport.handle(await req.text(), context);
      return isAsyncIterable(result)
        ? streamingResponse(result)
        : jsonResponse(result);
    }

    // ── Legacy: JSON-RPC message/send (claw-brain Service Binding) ──
    if (req.method === "POST" && url.pathname === "/") {
      if (
        env.A2A_SHARED_KEY &&
        req.headers.get("x-a2a-key") !== env.A2A_SHARED_KEY
      ) {
        return rpcError(null, -32001, "unauthorized");
      }

      let body: any;
      try {
        body = await req.json();
      } catch {
        return rpcError(null, -32700, "parse error");
      }

      if (body?.method !== "message/send") {
        return rpcError(body?.id, -32601, "method not found");
      }

      const parts = body?.params?.message?.parts ?? [];
      const dataPart = parts.find((p: any) => p.kind === "data" || p.data);
      const input = dataPart?.data ?? {};

      try {
        const result = await runDataSkill(input, env);
        await logTask(env, env.AGENT_SKILL_ID, result, true);
        return rpcResult(body.id, {
          task: { state: "completed" },
          parts: [{ kind: "data", data: result }],
        });
      } catch (e: any) {
        await logTask(env, env.AGENT_SKILL_ID, String(e), false);
        return rpcError(body?.id, -32000, "skill failed: " + e.message);
      }
    }

    return new Response("claw-data A2A agent alive 📊", { headers: CORS });
  },
} satisfies ExportedHandler<Env>;
