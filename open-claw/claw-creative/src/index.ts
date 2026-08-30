// claw-creative — Open Claw Creative Agent (A2A v1.0)
// LLM: text/caption/translate/summarize ด้วย Workers AI
//
// v2.0.0 — migrate ขึ้น A2A v1.0 ด้วย official @a2a-js/sdk (ยึดโค้ด live เป็นฐาน):
//   - discovery ใหม่:  GET  /.well-known/agent-card.json   (A2A v1)
//   - JSON-RPC ใหม่:   POST /a2a/jsonrpc  (SendMessage + x-a2a-key + A2A-Version: 1.0)
//   - legacy คงไว้:    GET / (status json), agent.json, POST / (message/send)
//   - เพิ่ม /health (additive) + ปิดรูโหว่: ต้องตั้ง A2A_SHARED_KEY หลัง deploy
//     (live เดิมไม่มี key = เปิดโล่ง)

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
}

const PROTOCOL_VERSION = "1.0";
const JSON_RPC_PATH = "/a2a/jsonrpc";
const MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, x-a2a-key, A2A-Version",
};

// ── Skill metadata (ตรงกับ live: 4 sub-skills) ──
const SUB_SKILLS = [
  {
    id: "creative_text",
    name: "Generate Text",
    description: "สร้างข้อความตาม prompt",
    tags: ["creative", "text", "ai"],
  },
  {
    id: "creative_caption",
    name: "Generate Caption",
    description: "สร้าง caption social media",
    tags: ["creative", "caption", "social"],
  },
  {
    id: "creative_translate",
    name: "Translate",
    description: "แปลภาษา EN↔TH",
    tags: ["creative", "translate"],
  },
  {
    id: "creative_summarize",
    name: "Summarize",
    description: "สรุปข้อความยาว",
    tags: ["creative", "summarize"],
  },
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
    name: env.AGENT_NAME || "Creative Agent",
    description:
      "Open Claw Creative Agent — สร้าง content/caption/translate/summarize ด้วย Workers AI",
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
    skills: SUB_SKILLS.map((s) => ({
      ...s,
      examples: [],
      inputModes: ["application/json"],
      outputModes: ["application/json"],
      securityRequirements: [requirement],
    })),
    signatures: [],
    iconUrl: undefined,
  };
}

// ── Legacy Agent Card ──
export function buildLegacyAgentCard(env: AgentIdentity, origin: string) {
  const url = env.AGENT_URL || origin;
  return {
    name: env.AGENT_NAME || "Creative Agent",
    description:
      "Open Claw Creative Agent — สร้าง content/caption/translate/summarize ด้วย Workers AI",
    version: "2.0.0",
    supportedInterfaces: [
      { url, protocolBinding: "JSONRPC", protocolVersion: "1.0" },
    ],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: SUB_SKILLS,
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
  // creative ใช้ field `error` (ตาม live) — มี error → REJECTED
  return result.error
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
async function logTask(env: Env, skill: string, result: unknown, ok: boolean) {
  try {
    await env.DB.prepare(
      "INSERT INTO task_history (id, agent, skill, result, ok, created_at) VALUES (?,?,?,?,?,?)",
    )
      .bind(
        "task_" + crypto.randomUUID().slice(0, 8),
        env.AGENT_NAME,
        skill,
        JSON.stringify(result),
        ok ? 1 : 0,
        new Date().toISOString(),
      )
      .run();
  } catch (_) {
    // log ล้มไม่ควรทำ agent ตาย
  }
}

// ── Creative skill logic (ตรงกับ live) ──
async function aiRun(env: Env, prompt: string, system?: string) {
  if (!env.AI) throw new Error("AI binding unavailable");
  const messages: Array<{ role: string; content: string }> = [];
  if (system) messages.push({ role: "system", content: system });
  messages.push({ role: "user", content: prompt });
  const res: any = await env.AI.run(
    MODEL as any,
    { messages, max_tokens: 500 } as any,
  );
  return res?.response ?? "";
}

async function skillText(input: Record<string, unknown>, env: Env) {
  const prompt = String(input.prompt ?? "");
  if (!prompt) return { error: "prompt required" };
  const lang = String(input.language ?? "th");
  const tone = String(input.tone ?? "friendly");
  const system =
    lang === "th"
      ? `คุณเป็นนักเขียนผู้เชี่ยวชาญ กรุณาตอบเป็นภาษาไทย น้ำเสียง: ${tone}`
      : `You are a creative writer. Tone: ${tone}. Respond in English.`;
  const text = await aiRun(env, prompt, system);
  return { text, model: MODEL };
}

async function skillCaption(input: Record<string, unknown>, env: Env) {
  const topic = String(input.topic ?? "");
  if (!topic) return { error: "topic required" };
  const platform = String(input.platform ?? "LINE");
  const hashtags = input.hashtags !== false;
  const prompt = `สร้าง caption สำหรับ ${platform} เกี่ยวกับ: ${topic}${
    hashtags ? " พร้อม hashtag ที่เกี่ยวข้อง" : " ไม่ต้องมี hashtag"
  }`;
  const caption = await aiRun(
    env,
    prompt,
    "คุณเป็นผู้เชี่ยวชาญ social media กรุณาตอบเป็นภาษาไทย",
  );
  return { caption, platform, topic };
}

async function skillTranslate(input: Record<string, unknown>, env: Env) {
  const text = String(input.text ?? "");
  if (!text) return { error: "text required" };
  const to = String(input.to ?? "th");
  const from = String(input.from ?? "auto");
  const prompt =
    to === "th"
      ? `แปลข้อความต่อไปนี้เป็นภาษาไทย (แปลเท่านั้น ไม่ต้องอธิบาย): "${text.slice(0, 2000)}"`
      : `Translate the following to ${to} (translation only, no explanation): "${text.slice(0, 2000)}"`;
  const translation = await aiRun(env, prompt);
  return { translation, from, to };
}

async function skillSummarize(input: Record<string, unknown>, env: Env) {
  const text = String(input.text ?? "");
  if (!text) return { error: "text required" };
  const maxSentences = Number(input.max_sentences ?? 3);
  const prompt = `สรุปข้อความต่อไปนี้ในไม่เกิน ${maxSentences} ประโยค (ภาษาเดียวกับต้นฉบับ):\n"${text.slice(0, 3000)}"`;
  const summary = await aiRun(env, prompt);
  return { summary, max_sentences: maxSentences };
}

export async function runCreativeSkill(
  input: Record<string, unknown>,
  env: Env,
): Promise<Record<string, unknown>> {
  const skill = String(input.skill ?? "text");
  if (skill === "text") return skillText(input, env);
  if (skill === "caption") return skillCaption(input, env);
  if (skill === "translate") return skillTranslate(input, env);
  if (skill === "summarize") return skillSummarize(input, env);
  return {
    error: `unknown skill: ${skill}. ใช้ text|caption|translate|summarize`,
  };
}

// ── A2A v1 executor ──
class CreativeExecutor implements AgentExecutor {
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

    const input = extractDataInput(userMessage);
    const result = await runCreativeSkill(input, this.env);
    await logTask(this.env, String(input.skill ?? "text"), result, true);

    const artifact: Artifact = {
      artifactId: crypto.randomUUID(),
      name: "creative-content",
      description: "Generated creative content.",
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

    // ── status (ตาม live) ──
    if (req.method === "GET" && url.pathname === "/") {
      return Response.json(
        { ok: true, name: "claw-creative", ts: Date.now() },
        { headers: CORS },
      );
    }

    // ── /health — monitoring probe (เพิ่มใหม่ v2) ──
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
        new CreativeExecutor(env),
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
        const result = await runCreativeSkill(input, env);
        await logTask(env, String(input.skill ?? "text"), result, true);
        return rpcResult(body.id, {
          task: { state: "completed" },
          parts: [{ kind: "data", data: result }],
        });
      } catch (e: any) {
        await logTask(env, String(input.skill ?? "text"), String(e), false);
        return rpcError(body.id, -32000, "skill failed: " + e.message);
      }
    }

    return new Response("claw-creative alive 🎨", { headers: CORS });
  },
} satisfies ExportedHandler<Env>;
