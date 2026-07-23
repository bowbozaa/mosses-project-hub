// claw-marketing — Open Claw Marketing Agent (A2A v1.0)
// LLM: สร้าง caption/hook สำหรับ Facebook, LINE, Telegram ด้วย Workers AI
//
// v2.0.0 — migrate ขึ้น A2A v1.0 ด้วย official @a2a-js/sdk (ยึดโค้ด live เป็นฐาน):
//   - discovery ใหม่:  GET  /.well-known/agent-card.json   (A2A v1)
//   - JSON-RPC ใหม่:   POST /a2a/jsonrpc  (SendMessage + x-a2a-key + A2A-Version: 1.0)
//   - legacy คงไว้:    GET  /.well-known/agent.json, POST / (message/send), /health
//   - เพิ่ม DB binding (friclawd-db) ให้ D1TaskStore — logTask ยังลง console ตาม live

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
  AI?: Ai;
  AGENT_NAME: string;
  AGENT_SKILL_ID: string;
  AGENT_URL?: string;
  A2A_SHARED_KEY?: string;
  LINE_CHANNEL_TOKEN?: string;
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
  name: "Marketing Content Generator",
  description: "รับ topic/product/tone → สร้าง caption พร้อมใช้",
  tags: ["marketing", "caption", "content", "facebook", "line"],
  examples: [
    '{"topic":"บอลโลก 2026","platform":"facebook","tone":"exciting"}',
    '{"topic":"Sabi Shop ลด 20%","platform":"line","tone":"friendly"}',
  ],
};

export function buildAgentCard(env: AgentIdentity, origin: string): AgentCard {
  const baseUrl = env.AGENT_URL || origin;
  const interfaceUrl = new URL(JSON_RPC_PATH, baseUrl).toString();
  const requirement = securityRequirement();

  return {
    name: env.AGENT_NAME || "Marketing Agent",
    description: "สร้าง caption/hook สำหรับ Facebook, LINE, Telegram ด้วย AI",
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
        id: env.AGENT_SKILL_ID || "marketing_content_gen",
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
    name: env.AGENT_NAME || "Marketing Agent",
    description: "สร้าง caption/hook สำหรับ Facebook, LINE, Telegram ด้วย AI",
    version: "2.0.0",
    supportedInterfaces: [
      { url, protocolBinding: "JSONRPC", protocolVersion: "1.0" },
    ],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: [
      { id: env.AGENT_SKILL_ID || "marketing_content_gen", ...SKILL_META },
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

// ── Log task ลง console (ตาม live — marketing ไม่ log ลง D1) ──
function logTask(env: Env, skill: string, result: unknown, ok: boolean) {
  console.log(
    JSON.stringify({
      agent: env.AGENT_NAME,
      skill,
      ok,
      ts: new Date().toISOString(),
      result,
    }),
  );
}

// ── Marketing skill logic (ตรงกับ live) ──
export async function runMarketingSkill(
  input: Record<string, unknown>,
  env: Env,
): Promise<Record<string, unknown>> {
  const topic = String(input.topic ?? "").trim();
  const platform = String(input.platform ?? "facebook").toLowerCase();
  const tone = String(input.tone ?? "friendly").toLowerCase();
  const lang = String(input.lang ?? "th").toLowerCase();

  if (!topic) {
    return { verdict: "FAIL", reason: "missing topic" };
  }
  if (!env.AI) {
    return { verdict: "FAIL", reason: "AI binding unavailable" };
  }

  const prompt = `เขียน caption สำหรับ ${platform} เรื่อง: ${topic}. Tone: ${tone}. ภาษา: ${lang}. ความยาวไม่เกิน 3 ประโยค พร้อม emoji และ hashtag ที่เหมาะสม`;
  const result: any = await env.AI.run(
    "@cf/meta/llama-3.3-70b-instruct-fp8-fast" as any,
    { prompt, max_tokens: 300 } as any,
  );
  const caption = String(result?.response ?? result?.result ?? "").trim();
  return {
    caption,
    topic,
    platform,
    tone,
    lang,
    generated_at: new Date().toISOString(),
  };
}

// ── A2A v1 executor ──
class MarketingExecutor implements AgentExecutor {
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

    const result = await runMarketingSkill(
      extractDataInput(userMessage),
      this.env,
    );
    logTask(this.env, this.env.AGENT_SKILL_ID, result, true);

    const artifact: Artifact = {
      artifactId: crypto.randomUUID(),
      name: "marketing-content",
      description: "Generated marketing caption.",
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
        new MarketingExecutor(env),
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
        const result = await runMarketingSkill(input, env);
        logTask(env, env.AGENT_SKILL_ID, result, true);
        return rpcResult(body.id, {
          task: { state: "completed" },
          parts: [{ kind: "data", data: result }],
        });
      } catch (e: any) {
        logTask(env, env.AGENT_SKILL_ID, String(e), false);
        return rpcError(body?.id, -32000, "skill failed: " + e.message);
      }
    }

    return new Response("claw-marketing A2A agent alive 📣", { headers: CORS });
  },
} satisfies ExportedHandler<Env>;
