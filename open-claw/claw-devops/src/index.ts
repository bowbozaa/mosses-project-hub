// claw-devops — Open Claw DevOps Agent (A2A v1.0)
// deterministic: health check, service list, drift detection
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
}

const PROTOCOL_VERSION = "1.0";
const JSON_RPC_PATH = "/a2a/jsonrpc";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, x-a2a-key, A2A-Version",
};

// รายชื่อ worker ที่ตรวจ — ตรงกับ live
const KNOWN_WORKERS = [
  "friday-brain.banknakorn39.workers.dev",
  "friday-chat.banknakorn39.workers.dev",
  "friday-vault.banknakorn39.workers.dev",
  "jarvis-dashboard.banknakorn39.workers.dev",
  "worldcup-engine.banknakorn39.workers.dev",
  "claw-guardian.banknakorn39.workers.dev",
  "claw-devops.banknakorn39.workers.dev",
];

// ── Agent Card (A2A v1) ──
function securityRequirement() {
  return { schemes: { a2aSharedKey: { list: [] } } };
}

type AgentIdentity = Pick<Env, "AGENT_NAME" | "AGENT_SKILL_ID" | "AGENT_URL">;

export function buildAgentCard(env: AgentIdentity, origin: string): AgentCard {
  const baseUrl = env.AGENT_URL || origin;
  const interfaceUrl = new URL(JSON_RPC_PATH, baseUrl).toString();
  const requirement = securityRequirement();

  return {
    name: env.AGENT_NAME || "DevOps Agent",
    description:
      "Open Claw DevOps: health check, service list, drift detection — deterministic",
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
        id: env.AGENT_SKILL_ID || "devops_ops_check",
        name: "DevOps Ops Check",
        description: "ตรวจสถานะ CF Workers และ services แบบ deterministic",
        tags: ["devops", "ops", "healthcheck", "drift"],
        examples: [
          '{"op":"health","target":"friday-brain.banknakorn39.workers.dev"}',
          '{"op":"list"}',
          '{"op":"drift"}',
        ],
        inputModes: ["application/json"],
        outputModes: ["application/json"],
        securityRequirements: [requirement],
      },
    ],
    signatures: [],
    iconUrl: undefined,
  };
}

// ── Legacy Agent Card (claw-brain GET /agents ยังใช้อยู่) ──
export function buildLegacyAgentCard(env: AgentIdentity, origin: string) {
  const url = env.AGENT_URL || origin;
  return {
    name: env.AGENT_NAME || "DevOps Agent",
    description:
      "Open Claw DevOps: health check, service list, drift detection — deterministic",
    version: "2.0.0",
    supportedInterfaces: [
      { url, protocolBinding: "JSONRPC", protocolVersion: "1.0" },
    ],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: [
      {
        id: env.AGENT_SKILL_ID || "devops_ops_check",
        name: "DevOps Ops Check",
        description: "ตรวจสถานะ CF Workers และ services แบบ deterministic",
        tags: ["devops", "ops", "healthcheck", "drift"],
        examples: [
          '{"op":"health","target":"friday-brain.banknakorn39.workers.dev"}',
          '{"op":"list"}',
          '{"op":"drift"}',
        ],
      },
    ],
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
  // ผลลัพธ์ devops ส่วนใหญ่เป็นข้อมูล → COMPLETED, ยกเว้น verdict FAIL → REJECTED
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

// ── DevOps skill logic (ตรงกับ live) ──
async function checkHealth(host: string) {
  const base = host.startsWith("http") ? host : `https://${host}`;
  for (const path of ["/health", "/"]) {
    try {
      const res = await fetch(base + path, {
        signal: AbortSignal.timeout(8000),
      });
      if (res.status !== 404) {
        return {
          ok: res.ok,
          status: res.status,
          worker: host,
          endpoint: path,
          checked_at: new Date().toISOString(),
        };
      }
    } catch (e: any) {
      return {
        ok: false,
        status: 0,
        worker: host,
        error: e.message,
        checked_at: new Date().toISOString(),
      };
    }
  }
  return {
    ok: false,
    status: 404,
    worker: host,
    error: "no health endpoint",
    checked_at: new Date().toISOString(),
  };
}

export async function runDevopsSkill(
  input: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const op = String(input.op ?? "health");
  const target = String(input.target ?? "");

  switch (op) {
    case "health":
      return await checkHealth(target || KNOWN_WORKERS[0]);
    case "list":
      return { workers: KNOWN_WORKERS, count: KNOWN_WORKERS.length };
    case "drift": {
      const results = await Promise.allSettled(
        KNOWN_WORKERS.map((w) => checkHealth(w)),
      );
      const statuses = results.map((r, i) => ({
        ...(r.status === "fulfilled"
          ? r.value
          : { ok: false, error: String(r.reason) }),
        worker: KNOWN_WORKERS[i],
      }));
      const down = statuses.filter((s: any) => !s.ok);
      return {
        checked: KNOWN_WORKERS.length,
        all_ok: down.length === 0,
        down_count: down.length,
        down,
        statuses,
        checked_at: new Date().toISOString(),
      };
    }
    default:
      return { verdict: "FAIL", reason: `unknown op: ${op}` };
  }
}

// ── A2A v1 executor ──
class DevopsExecutor implements AgentExecutor {
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

    const result = await runDevopsSkill(extractDataInput(userMessage));
    await logTask(this.env, this.env.AGENT_SKILL_ID, result, true);

    const artifact: Artifact = {
      artifactId: crypto.randomUUID(),
      name: "devops-result",
      description: "Deterministic devops check result.",
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
        new DevopsExecutor(env),
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
        const result = await runDevopsSkill(input);
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

    return new Response("claw-devops A2A agent alive ⚙️", { headers: CORS });
  },
} satisfies ExportedHandler<Env>;
