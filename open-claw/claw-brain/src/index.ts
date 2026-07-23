// claw-brain — CLAW BRAIN orchestrator (A2A v1.0)
// orchestrator เดียวของ Open Claw: route intent → specialist ผ่าน Service Bindings
//
// v2.0.0 — เพิ่มชั้น A2A v1.0 ด้วย official @a2a-js/sdk (logic เดิมคงครบทุกจุด):
//   - discovery ใหม่:  GET  /.well-known/agent-card.json + agent.json (orchestrator card)
//   - JSON-RPC ใหม่:   POST /a2a/jsonrpc  (SendMessage + x-a2a-key + A2A-Version: 1.0)
//     → ADK RemoteA2aAgent / A2A client ภายนอกสั่งงาน mesh ได้ตามมาตรฐาน
//   - legacy คงไว้:    GET /, GET /agents, POST /run, POST /dispatch, POST /pipeline
//     (auth ด้วย BRAIN_API_KEY เหมือนเดิม)
//   - specialist ทุกตัวยังเรียกผ่าน Service Binding ด้วย legacy message/send
//     (กัน same-zone loopback 404 — ห้ามเปลี่ยนเป็น URL fetch)

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
  AGENT_URL?: string;
  BRAIN_API_KEY?: string;
  A2A_SHARED_KEY?: string;
  GUARDIAN: Fetcher;
  DEVOPS: Fetcher;
  DATA: Fetcher;
  MARKETING: Fetcher;
  CREATIVE: Fetcher;
}

type AgentName = "guardian" | "devops" | "data" | "marketing" | "creative";

const PROTOCOL_VERSION = "1.0";
const JSON_RPC_PATH = "/a2a/jsonrpc";
const AGENT_NAMES: AgentName[] = [
  "guardian",
  "devops",
  "data",
  "marketing",
  "creative",
];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, x-brain-key, x-a2a-key, A2A-Version",
};

// ── routing (ตรงกับ live) ──
function agentBinding(env: Env, agent: AgentName): Fetcher {
  const map: Record<AgentName, Fetcher> = {
    guardian: env.GUARDIAN,
    devops: env.DEVOPS,
    data: env.DATA,
    marketing: env.MARKETING,
    creative: env.CREATIVE,
  };
  return map[agent];
}

export function routeIntent(intent: string): {
  agent: AgentName;
  skill: string;
} {
  const i = intent.toLowerCase();
  if (/deploy|rollback|purge.cache|worker.status/.test(i)) {
    if (/rollback/.test(i)) return { agent: "devops", skill: "rollback" };
    if (/purge/.test(i)) return { agent: "devops", skill: "purge" };
    if (/status/.test(i)) return { agent: "devops", skill: "status" };
    return { agent: "devops", skill: "deploy" };
  }
  if (/query|select|insert|update|delete|analytics|schema|table/.test(i)) {
    if (/analytics|stat|count/.test(i))
      return { agent: "data", skill: "analytics" };
    if (/schema|table|column/.test(i))
      return { agent: "data", skill: "schema" };
    if (/insert|update|delete/.test(i))
      return { agent: "data", skill: "mutate" };
    return { agent: "data", skill: "query" };
  }
  if (/broadcast|push.message|send.line|campaign|reply/.test(i)) {
    if (/broadcast/.test(i)) return { agent: "marketing", skill: "broadcast" };
    if (/reply/.test(i)) return { agent: "marketing", skill: "reply" };
    if (/campaign|status/.test(i))
      return { agent: "marketing", skill: "campaign_status" };
    return { agent: "marketing", skill: "push" };
  }
  if (/caption|translate|summarize|content/.test(i)) {
    if (/caption/.test(i)) return { agent: "creative", skill: "caption" };
    if (/translate/.test(i)) return { agent: "creative", skill: "translate" };
    if (/summarize/.test(i)) return { agent: "creative", skill: "summarize" };
    return { agent: "creative", skill: "text" };
  }
  return { agent: "guardian", skill: "policy_check" };
}

async function callAgent(
  env: Env,
  agent: AgentName,
  skill: string,
  data: Record<string, unknown>,
): Promise<unknown> {
  const binding = agentBinding(env, agent);
  const hdrs: Record<string, string> = { "Content-Type": "application/json" };
  if (env.A2A_SHARED_KEY) hdrs["x-a2a-key"] = env.A2A_SHARED_KEY;
  const agentReq = new Request("https://agent/", {
    method: "POST",
    headers: hdrs,
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: crypto.randomUUID().slice(0, 8),
      method: "message/send",
      params: {
        message: { parts: [{ kind: "data", data: { skill, ...data } }] },
      },
    }),
  });
  const res = await binding.fetch(agentReq);
  if (!res.ok) return { error: "agent " + agent + " returned " + res.status };
  const body: any = await res.json();
  if (body?.error) return { error: body.error.message ?? "agent error" };
  return body?.result?.parts?.[0]?.data ?? body?.result ?? {};
}

async function classifyWithAI(
  env: Env,
  intent: string,
): Promise<{ agent: AgentName; skill: string; data: Record<string, unknown> }> {
  const system =
    "Intent classifier. Output JSON: {agent,skill,data}. Agents: guardian,devops,data,marketing,creative. JSON only.";
  try {
    const res = (await env.AI!.run(
      "@cf/meta/llama-3.1-8b-instruct" as any,
      {
        messages: [
          { role: "system", content: system },
          { role: "user", content: intent },
        ],
        max_tokens: 300,
      } as any,
    )) as any;
    const m = (res?.response ?? "").match(/\{[\s\S]*\}/);
    if (m) {
      const p = JSON.parse(m[0]);
      return {
        agent: p.agent ?? "creative",
        skill: p.skill ?? "text",
        data: p.data ?? {},
      };
    }
  } catch (_) {}
  return { ...routeIntent(intent), data: { prompt: intent } };
}

async function logBrain(
  env: Env,
  intent: string,
  route: string,
  result: unknown,
  ok: boolean,
) {
  try {
    await env.DB.prepare(
      "INSERT INTO task_history (id, agent, skill, result, ok, created_at) VALUES (?,?,?,?,?,?)",
    )
      .bind(
        "brain_" + crypto.randomUUID().slice(0, 8),
        "CLAW BRAIN",
        route,
        JSON.stringify({ intent: intent.slice(0, 200), result }),
        ok ? 1 : 0,
        new Date().toISOString(),
      )
      .run();
  } catch (_) {}
}

// ── A2A v1: Agent Card ──
function securityRequirement() {
  return { schemes: { a2aSharedKey: { list: [] } } };
}

type AgentIdentity = Pick<Env, "AGENT_NAME" | "AGENT_URL">;

const ORCH_SKILL = {
  id: "claw_orchestrate",
  name: "Open Claw Orchestrator",
  description:
    "รับ intent หรือ {agent,skill,data} → route ไป specialist ตัวเดียว (guardian/devops/data/marketing/creative)",
  tags: ["orchestrator", "routing", "open-claw"],
  examples: [
    '{"intent":"translate สวัสดี to english"}',
    '{"agent":"devops","skill":"ops_check","data":{"op":"list"}}',
  ],
};

export function buildAgentCard(env: AgentIdentity, origin: string): AgentCard {
  const baseUrl = env.AGENT_URL || origin;
  const interfaceUrl = new URL(JSON_RPC_PATH, baseUrl).toString();
  const requirement = securityRequirement();

  return {
    name: env.AGENT_NAME || "CLAW BRAIN",
    description: "CLAW BRAIN — orchestrator เดียวของ Open Claw mesh (A2A v1.0)",
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
        ...ORCH_SKILL,
        inputModes: ["application/json"],
        outputModes: ["application/json"],
        securityRequirements: [requirement],
      },
    ],
    signatures: [],
    iconUrl: undefined,
  };
}

export function buildLegacyAgentCard(env: AgentIdentity, origin: string) {
  const url = env.AGENT_URL || origin;
  return {
    name: env.AGENT_NAME || "CLAW BRAIN",
    description: "CLAW BRAIN — orchestrator เดียวของ Open Claw mesh (A2A v1.0)",
    version: "2.0.0",
    supportedInterfaces: [
      { url, protocolBinding: "JSONRPC", protocolVersion: "1.0" },
    ],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: [ORCH_SKILL],
  };
}

// ── A2A v1: helpers + executor ──
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

export function taskStateForOrchestration(
  result: Record<string, unknown>,
): TaskState {
  if (result.error) return TaskState.TASK_STATE_FAILED;
  if (
    result.verdict === "PENDING_APPROVAL" ||
    result.verdict === "MANUAL_REVIEW"
  ) {
    return TaskState.TASK_STATE_INPUT_REQUIRED;
  }
  if (result.verdict === "FAIL" || result.verdict === "BLOCKED") {
    return TaskState.TASK_STATE_REJECTED;
  }
  return TaskState.TASK_STATE_COMPLETED;
}

// รับ input จาก v1 SendMessage → route แบบเดียวกับ /run และ /dispatch
export async function orchestrate(
  input: Record<string, unknown>,
  env: Env,
): Promise<Record<string, unknown>> {
  const requestedBy = String(input.requested_by ?? "a2a-client");

  // โหมด dispatch ตรง: {agent, skill, data}
  const agent = input.agent as AgentName | undefined;
  if (agent) {
    if (!AGENT_NAMES.includes(agent)) {
      return { error: "invalid agent: " + agent };
    }
    const skill = String(input.skill ?? "");
    if (!skill) return { error: "skill required when agent is specified" };
    const result = (await callAgent(env, agent, skill, {
      ...((input.data as Record<string, unknown>) ?? {}),
      requested_by: requestedBy,
    })) as Record<string, unknown>;
    await logBrain(
      env,
      `a2a:${agent}/${skill}`,
      `${agent}/${skill}`,
      result,
      !result.error,
    );
    return { agent, skill, result };
  }

  // โหมด intent routing
  const intent = String(input.intent ?? input.message ?? "").trim();
  if (!intent) return { error: "intent or {agent,skill} required" };

  const route =
    input.use_ai === true
      ? await classifyWithAI(env, intent)
      : {
          ...routeIntent(intent),
          data: (input.data as Record<string, unknown>) ?? { prompt: intent },
        };

  const merged = {
    ...route.data,
    ...((input.data as Record<string, unknown>) ?? {}),
    requested_by: requestedBy,
  };
  const result = (await callAgent(
    env,
    route.agent,
    route.skill,
    merged,
  )) as Record<string, unknown>;
  await logBrain(
    env,
    intent,
    `${route.agent}/${route.skill}`,
    result,
    !result.error,
  );
  return { agent: route.agent, skill: route.skill, result };
}

class BrainExecutor implements AgentExecutor {
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

    const outcome = await orchestrate(extractDataInput(userMessage), this.env);
    const flat: Record<string, unknown> = outcome.error
      ? outcome
      : {
          ...(outcome.result as Record<string, unknown>),
          _routed_to: `${outcome.agent}/${outcome.skill}`,
        };

    const artifact: Artifact = {
      artifactId: crypto.randomUUID(),
      name: "orchestration-result",
      description: "Result from the routed specialist.",
      parts: [
        {
          content: { $case: "data", value: flat },
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
          state: taskStateForOrchestration(flat),
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
        {
          ok: true,
          name: "claw-brain",
          agents: AGENT_NAMES,
          ts: Date.now(),
        },
        { headers: CORS },
      );
    }

    // ── Discovery v1 + legacy card (เปิด public เหมือน card ของ specialist) ──
    if (req.method === "GET" && url.pathname === `/${AGENT_CARD_PATH}`) {
      return jsonResponse(AgentCard.toJSON(buildAgentCard(env, origin)));
    }
    if (url.pathname === "/.well-known/agent.json") {
      return Response.json(buildLegacyAgentCard(env, origin), {
        headers: CORS,
      });
    }

    // ── /agents — รวม legacy card ของ specialist (ตาม live) ──
    if (req.method === "GET" && url.pathname === "/agents") {
      const cards = await Promise.allSettled(
        AGENT_NAMES.map((n) =>
          agentBinding(env, n)
            .fetch(new Request("https://agent/.well-known/agent.json"))
            .then((r) => r.json()),
        ),
      );
      return Response.json(
        {
          agents: AGENT_NAMES.map((n, i) => ({
            name: n,
            card:
              cards[i].status === "fulfilled"
                ? (cards[i] as PromiseFulfilledResult<unknown>).value
                : { error: "unavailable" },
          })),
        },
        { headers: CORS },
      );
    }

    // ── A2A v1: JSON-RPC ingress (auth ด้วย x-a2a-key — คนละชุดกับ BRAIN_API_KEY) ──
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
        new BrainExecutor(env),
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

    // ── legacy auth gate (BRAIN_API_KEY) สำหรับ /run /dispatch /pipeline ──
    if (env.BRAIN_API_KEY) {
      const auth =
        req.headers.get("Authorization") ??
        req.headers.get("x-brain-key") ??
        "";
      if (auth.replace(/^Bearer\s+/, "") !== env.BRAIN_API_KEY) {
        return Response.json(
          { error: "unauthorized" },
          { status: 401, headers: CORS },
        );
      }
    }

    if (req.method === "POST" && url.pathname === "/run") {
      let body: any;
      try {
        body = await req.json();
      } catch {
        return Response.json(
          { error: "parse error" },
          { status: 400, headers: CORS },
        );
      }
      const intent = String(body?.intent ?? body?.message ?? "");
      if (!intent)
        return Response.json(
          { error: "intent required" },
          { status: 400, headers: CORS },
        );
      let route: {
        agent: AgentName;
        skill: string;
        data: Record<string, unknown>;
      };
      if (body?.use_ai === true) {
        route = await classifyWithAI(env, intent);
      } else {
        route = {
          ...routeIntent(intent),
          data: body?.data ?? { prompt: intent },
        };
      }
      const merged = {
        ...route.data,
        ...(body?.data ?? {}),
        requested_by: body?.requested_by ?? "claw-brain",
      };
      try {
        const result = await callAgent(env, route.agent, route.skill, merged);
        await logBrain(
          env,
          intent,
          route.agent + "/" + route.skill,
          result,
          true,
        );
        return Response.json(
          { ok: true, agent: route.agent, skill: route.skill, result },
          { headers: CORS },
        );
      } catch (e: any) {
        await logBrain(
          env,
          intent,
          route.agent + "/" + route.skill,
          String(e),
          false,
        );
        return Response.json(
          { ok: false, error: e.message },
          { status: 500, headers: CORS },
        );
      }
    }

    if (req.method === "POST" && url.pathname === "/dispatch") {
      let body: any;
      try {
        body = await req.json();
      } catch {
        return Response.json(
          { error: "parse error" },
          { status: 400, headers: CORS },
        );
      }
      const agent = body?.agent as AgentName;
      const skill = String(body?.skill ?? "");
      if (!agent || !skill)
        return Response.json(
          { error: "agent and skill required" },
          { status: 400, headers: CORS },
        );
      if (!AGENT_NAMES.includes(agent))
        return Response.json(
          { error: "invalid agent: " + agent },
          { status: 400, headers: CORS },
        );
      try {
        const result = await callAgent(env, agent, skill, {
          ...(body?.data ?? {}),
          requested_by: body?.requested_by ?? "claw-brain",
        });
        await logBrain(
          env,
          agent + "/" + skill,
          agent + "/" + skill,
          result,
          true,
        );
        return Response.json(
          { ok: true, agent, skill, result },
          { headers: CORS },
        );
      } catch (e: any) {
        return Response.json(
          { ok: false, error: e.message },
          { status: 500, headers: CORS },
        );
      }
    }

    // ── /pipeline — SequentialAgent: chain หลาย agent ต่อเนื่อง (ตาม live) ──
    if (req.method === "POST" && url.pathname === "/pipeline") {
      let body: any;
      try {
        body = await req.json();
      } catch {
        return Response.json(
          { error: "parse error" },
          { status: 400, headers: CORS },
        );
      }

      type PipelineStep = {
        agent: AgentName;
        skill: string;
        data?: Record<string, unknown>;
        input_from?: "prev";
        optional?: boolean;
      };

      const steps: PipelineStep[] = body?.steps ?? [];
      if (!steps.length) {
        return Response.json(
          { error: "steps array required" },
          { status: 400, headers: CORS },
        );
      }

      for (const s of steps) {
        if (!AGENT_NAMES.includes(s.agent) || !s.skill) {
          return Response.json(
            { error: `invalid step: agent=${s.agent} skill=${s.skill}` },
            { status: 400, headers: CORS },
          );
        }
      }

      const pipelineId = "pipe_" + crypto.randomUUID().slice(0, 8);
      const requestedBy = String(body?.requested_by ?? "claw-brain");
      const results: unknown[] = [];
      let prevResult: Record<string, unknown> = {};
      let state: "running" | "completed" | "failed" | "manual_review" =
        "running";
      let failedStep = -1;

      for (let i = 0; i < steps.length; i++) {
        const step = steps[i];
        const stepData: Record<string, unknown> = {
          ...(step.data ?? {}),
          requested_by: requestedBy,
          ...(step.input_from === "prev" ? { prev_result: prevResult } : {}),
        };

        try {
          const result = await callAgent(env, step.agent, step.skill, stepData);
          const r = result as any;
          if (r?.error) throw new Error(String(r.error));
          const failStatus = ["blocked", "timeout", "rejected"];
          if (r?.status && failStatus.includes(r.status)) {
            throw new Error(
              `${r.status}: ${r.reason ?? r.message ?? r.approval_id ?? ""}`,
            );
          }
          results.push({
            step: i,
            agent: step.agent,
            skill: step.skill,
            state: "completed",
            result,
          });
          prevResult = result as Record<string, unknown>;
          await logBrain(
            env,
            pipelineId + ":step" + i,
            step.agent + "/" + step.skill,
            result,
            true,
          );
        } catch (e: any) {
          const errResult = {
            step: i,
            agent: step.agent,
            skill: step.skill,
            state: "failed",
            error: e.message,
          };
          results.push(errResult);
          await logBrain(
            env,
            pipelineId + ":step" + i,
            step.agent + "/" + step.skill,
            errResult,
            false,
          );
          if (step.optional) {
            prevResult = {};
            continue;
          }
          state = "manual_review";
          failedStep = i;
          break;
        }
      }

      if (state === "running") state = "completed";
      await logBrain(
        env,
        pipelineId,
        "pipeline",
        { steps: results, state },
        state === "completed",
      );
      return Response.json(
        {
          ok: state === "completed",
          pipeline_id: pipelineId,
          state,
          steps_total: steps.length,
          steps_completed: (results as any[]).filter(
            (r) => r.state === "completed",
          ).length,
          ...(failedStep >= 0 ? { failed_at_step: failedStep } : {}),
          results,
          final_result: prevResult,
        },
        { headers: CORS },
      );
    }

    return new Response("claw-brain alive 🧠", { headers: CORS });
  },
} satisfies ExportedHandler<Env>;
