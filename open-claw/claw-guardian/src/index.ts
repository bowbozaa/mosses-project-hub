// claw-guardian — Open Claw A2A Guardian Agent (A2A v1.0)
// HITL gate: ตรวจ policy + ขอ approve ผ่าน Telegram ก่อนงาน irreversible
//
// v2.0.0 — migrate ขึ้น A2A v1.0 ด้วย official @a2a-js/sdk
// (reconcile กับโค้ด live ที่ deploy อยู่ ซึ่งเป็นสาย Telegram — ไม่ใช่ LINE ตาม source เก่าในดิสก์):
//   - discovery ใหม่:  GET  /.well-known/agent-card.json   (A2A v1)
//   - JSON-RPC ใหม่:   POST /a2a/jsonrpc  (SendMessage + x-a2a-key + A2A-Version: 1.0)
//   - legacy คงไว้:    GET  /.well-known/agent.json, POST / (message/send),
//                      POST /health, POST /tasks/get, POST /approvals/resolve
//     (claw-brain เรียกผ่าน Service Binding ด้วย message/send และ n8n ยิง /approvals/resolve)
//   - fail-closed:     ไม่เจอ policy → MANUAL_REVIEW (live เดิม fail-open เป็น PASS)
//   - UID check เป็น opt-in: ตั้ง GUARDIAN_REQUIRE_UID="1" เมื่อไหร่ resolve ต้องส่ง
//     requester_uid ตรง GUARDIAN_APPROVER_UID; ไม่ตั้ง = พฤติกรรม live เดิม

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
  TG_BOT_TOKEN: string;
  TG_CHAT_ID: string;
  GUARDIAN_APPROVER_UID?: string;
  GUARDIAN_REQUIRE_UID?: string; // "1" = บังคับตรวจ requester_uid ตอน resolve
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

export function buildAgentCard(env: AgentIdentity, origin: string): AgentCard {
  const baseUrl = env.AGENT_URL || origin;
  const interfaceUrl = new URL(JSON_RPC_PATH, baseUrl).toString();
  const requirement = securityRequirement();

  return {
    name: env.AGENT_NAME || "Guardian Agent",
    description:
      "Open Claw HITL gate — ตรวจ policy + ขอ approve ผ่าน Telegram ก่อนงาน irreversible",
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
        id: env.AGENT_SKILL_ID || "guardian_policy_check",
        name: "Guardian Policy Check",
        description:
          "ตรวจ action เทียบ policy — เสี่ยงสูงขอ approve ผ่าน Telegram, ไม่เจอ policy = MANUAL_REVIEW (fail-closed)",
        tags: ["guardian", "policy", "hitl", "approval"],
        examples: ["deploy worker X", "delete table Y", "broadcast message Z"],
        inputModes: ["application/json"],
        outputModes: ["application/json"],
        securityRequirements: [requirement],
      },
    ],
    signatures: [],
    iconUrl: undefined,
  };
}

// ── Legacy Agent Card (รุ่นเก่า — claw-brain GET /agents ยังใช้อยู่) ──
export function buildLegacyAgentCard(env: AgentIdentity, origin: string) {
  const url = env.AGENT_URL || origin;
  return {
    name: env.AGENT_NAME || "Guardian Agent",
    description:
      "Open Claw HITL gate — ตรวจ policy + ขอ approve ผ่าน Telegram ก่อนงาน irreversible",
    version: "2.0.0",
    supportedInterfaces: [
      { url, protocolBinding: "JSONRPC", protocolVersion: "1.0" },
    ],
    defaultInputModes: ["application/json"],
    defaultOutputModes: ["application/json"],
    skills: [
      {
        id: env.AGENT_SKILL_ID || "guardian_policy_check",
        name: "Guardian Policy Check",
        description:
          "ตรวจสถานะ action เทียบ policy — เสี่ยงสูงขอ approve ผ่าน Telegram ก่อนปล่อยผ่าน",
        tags: ["guardian", "policy", "hitl", "approval"],
        examples: ["deploy worker X", "delete table Y", "broadcast message Z"],
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

export function taskStateForVerdict(verdict: string): TaskState {
  if (verdict === "PASS") return TaskState.TASK_STATE_COMPLETED;
  if (verdict === "FAIL" || verdict === "BLOCKED") {
    return TaskState.TASK_STATE_REJECTED;
  }
  // PENDING_APPROVAL / MANUAL_REVIEW / ไม่รู้จัก → fail-closed รอคน
  return TaskState.TASK_STATE_INPUT_REQUIRED;
}

export function isAuthorizedA2ARequest(
  request: Request,
  env: Pick<Env, "A2A_SHARED_KEY">,
): boolean {
  return Boolean(
    env.A2A_SHARED_KEY &&
    request.headers.get("x-a2a-key") === env.A2A_SHARED_KEY &&
    request.headers.get(A2A_VERSION_HEADER) === PROTOCOL_VERSION,
  );
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

// ── Telegram push approval request (พฤติกรรมเดียวกับ live) ──
async function pushTelegramApproval(
  env: Env,
  action: string,
  approvalId: string,
  requestedBy: string,
  riskLevel: string,
) {
  if (!env.TG_BOT_TOKEN) throw new Error("TG_BOT_TOKEN not set");
  const text =
    `🛡️ *Guardian ขออนุมัติ*\n\n` +
    `Action: \`${action}\`\n` +
    `Requested by: ${requestedBy}\n` +
    `Risk: *${riskLevel}*\n` +
    `ID: \`${approvalId}\`\n\n` +
    `ตอบ:\n✅ \`approve ${approvalId}\`\n❌ \`reject ${approvalId}\``;
  const res = await fetch(
    `https://api.telegram.org/bot${env.TG_BOT_TOKEN}/sendMessage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: env.TG_CHAT_ID,
        text,
        parse_mode: "Markdown",
      }),
    },
  );
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Telegram API ${res.status}: ${body}`);
  }
}

// ── Guardian skill logic (ใช้ร่วมทั้ง legacy และ v1 path) ──
export interface GuardianVerdict {
  verdict: "PASS" | "FAIL" | "BLOCKED" | "PENDING_APPROVAL" | "MANUAL_REVIEW";
  action?: string;
  risk_level?: string;
  reason?: string;
  approval_id?: string;
  approval_needed: boolean;
  poll_hint?: string;
}

export async function runGuardianSkill(
  input: Record<string, unknown>,
  env: Env,
): Promise<GuardianVerdict> {
  const action = String(input.action ?? "")
    .toLowerCase()
    .trim();
  const requestedBy = String(input.requested_by ?? "unknown");

  // ไม่มี action = คำขอผิดรูป → FAIL (พฤติกรรมเดียวกับ live)
  if (!action) {
    return {
      verdict: "FAIL",
      reason: "missing 'action' field",
      approval_needed: false,
    };
  }

  // เช็ก policy จาก D1 — แก้กฎได้โดยไม่ต้อง deploy ใหม่
  const policy = await env.DB.prepare(
    "SELECT * FROM guardian_policy WHERE ? LIKE '%' || action_pattern || '%' ORDER BY requires_approval DESC LIMIT 1",
  )
    .bind(action)
    .first<{ risk_level: string; requires_approval: number }>();

  // fail-closed: ไม่เจอ policy → MANUAL_REVIEW (live เดิม fail-open เป็น PASS — รูรั่วที่ audit เจอ)
  if (!policy) {
    return {
      verdict: "MANUAL_REVIEW",
      reason: "no_matching_policy",
      action,
      approval_needed: true,
    };
  }

  // LOW risk (requires_approval=0) → PASS
  if (policy.requires_approval === 0) {
    return {
      verdict: "PASS",
      risk_level: policy.risk_level,
      action,
      approval_needed: false,
    };
  }

  // HIGH risk → สร้าง pending approval + ยิง Telegram
  const approvalId = "appr_" + crypto.randomUUID().slice(0, 8);
  await env.DB.prepare(
    "INSERT INTO pending_approvals (id, action, requested_by, status, created_at) VALUES (?,?,?,?,?)",
  )
    .bind(approvalId, action, requestedBy, "pending", new Date().toISOString())
    .run();

  try {
    await pushTelegramApproval(
      env,
      action,
      approvalId,
      requestedBy,
      policy.risk_level,
    );
  } catch (e) {
    // fail-closed: ส่ง Telegram ไม่ได้ → ลบ pending ทิ้ง + BLOCKED ทันที ไม่ปล่อยผ่าน
    await env.DB.prepare("DELETE FROM pending_approvals WHERE id = ?")
      .bind(approvalId)
      .run();
    return {
      verdict: "BLOCKED",
      reason: "telegram_push_failed: " + String(e),
      approval_id: approvalId,
      approval_needed: true,
    };
  }

  return {
    verdict: "PENDING_APPROVAL",
    approval_id: approvalId,
    risk_level: policy.risk_level,
    action,
    approval_needed: true,
    poll_hint: "POST /tasks/get { approval_id } เพื่อเช็คสถานะ",
  };
}

// ── resolve approval (ใช้ร่วม /approvals/resolve และ /telegram/webhook) ──
async function resolveApproval(
  env: Env,
  approvalId: string,
  status: "approved" | "rejected",
  reason?: string,
): Promise<{ ok: boolean; error?: string }> {
  // conditional update กัน resolve ซ้ำ (atomic — ไม่มีช่อง race ระหว่าง SELECT กับ UPDATE)
  const updated = await env.DB.prepare(
    "UPDATE pending_approvals SET status = ? WHERE id = ? AND status = 'pending'",
  )
    .bind(status, approvalId)
    .run();
  if (!updated.meta.changes) {
    return { ok: false, error: "approval not found or already resolved" };
  }

  await logTask(
    env,
    "guardian_resolve",
    { approval_id: approvalId, status, reason },
    true,
  );

  // แจ้งผลกลับเข้า Telegram (best-effort — ล้มไม่ทำให้ resolve fail)
  try {
    const emoji = status === "approved" ? "✅" : "❌";
    await fetch(`https://api.telegram.org/bot${env.TG_BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: env.TG_CHAT_ID,
        text: `${emoji} *${status.toUpperCase()}* \`${approvalId}\`${
          reason ? `\nเหตุผล: ${reason}` : ""
        }`,
        parse_mode: "Markdown",
      }),
    });
  } catch (_) {
    // notify ล้มไม่กระทบผล resolve
  }

  return { ok: true };
}

// ── A2A v1 executor ──
class GuardianExecutor implements AgentExecutor {
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

    const result = await runGuardianSkill(
      extractDataInput(userMessage),
      this.env,
    );
    await logTask(this.env, this.env.AGENT_SKILL_ID, result, true);

    const artifact: Artifact = {
      artifactId: crypto.randomUUID(),
      name: "guardian-verdict",
      description: "Guardian policy verdict.",
      parts: [
        {
          content: {
            $case: "data",
            value: result as unknown as Record<string, unknown>,
          },
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
          state: taskStateForVerdict(result.verdict),
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

    // ── Discovery legacy (claw-brain /agents ยังเรียกอยู่) ──
    if (url.pathname === "/.well-known/agent.json") {
      return Response.json(buildLegacyAgentCard(env, origin), {
        headers: CORS,
      });
    }

    // ── /health — monitoring probe (พฤติกรรมเดียวกับ live) ──
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
        new GuardianExecutor(env),
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
        const result = await runGuardianSkill(input, env);
        await logTask(env, env.AGENT_SKILL_ID, result, true);
        const isPending = result.verdict === "PENDING_APPROVAL";
        return rpcResult(body.id, {
          task: { state: isPending ? "working" : "completed" },
          parts: [{ kind: "data", data: result }],
        });
      } catch (e: any) {
        await logTask(env, env.AGENT_SKILL_ID, String(e), false);
        return rpcError(body.id, -32000, "skill failed: " + e.message);
      }
    }

    // ── /tasks/get — CLAW BRAIN / poll_approval tool เช็คสถานะ approval ──
    if (req.method === "POST" && url.pathname === "/tasks/get") {
      let body: any;
      try {
        body = await req.json();
      } catch {
        return Response.json(
          { error: "parse error" },
          { status: 400, headers: CORS },
        );
      }
      const approvalId = String(body?.approval_id ?? "");
      if (!approvalId) {
        return Response.json(
          { error: "missing approval_id" },
          { status: 400, headers: CORS },
        );
      }
      const row = await env.DB.prepare(
        "SELECT status FROM pending_approvals WHERE id = ?",
      )
        .bind(approvalId)
        .first<{ status: string }>();

      if (!row) {
        return Response.json(
          { error: "not found" },
          { status: 404, headers: CORS },
        );
      }

      const state =
        row.status === "approved"
          ? "completed"
          : row.status === "rejected"
            ? "failed"
            : "working";
      return Response.json(
        { state, status: row.status, approval_id: approvalId },
        { headers: CORS },
      );
    }

    // ── /approvals/resolve — n8n ส่งผล approve/reject ──
    if (req.method === "POST" && url.pathname === "/approvals/resolve") {
      // key semantics เดียวกับ live: ตั้ง key เมื่อไหร่ต้องตรง, ไม่ตั้ง = เปิด
      if (
        env.A2A_SHARED_KEY &&
        req.headers.get("x-a2a-key") !== env.A2A_SHARED_KEY
      ) {
        return Response.json(
          { ok: false, error: "unauthorized" },
          { status: 401, headers: CORS },
        );
      }

      let body: any;
      try {
        body = await req.json();
      } catch {
        return Response.json(
          { ok: false, error: "parse error" },
          { status: 400, headers: CORS },
        );
      }

      const { approval_id, status, requester_uid, reason } = body;

      // opt-in strict: เปิด GUARDIAN_REQUIRE_UID="1" เมื่อไหร่ requester_uid ต้องตรง
      // GUARDIAN_APPROVER_UID. ค่า default = พฤติกรรม live เดิม (shared key อย่างเดียว)
      // — เหตุผล: secret GUARDIAN_APPROVER_UID บน worker เป็น LINE UID ยุคเก่า
      // แต่ flow ปัจจุบันคือ Telegram/n8n ที่ไม่ได้ส่ง requester_uid
      if (
        env.GUARDIAN_REQUIRE_UID === "1" &&
        requester_uid !== env.GUARDIAN_APPROVER_UID
      ) {
        return Response.json(
          { ok: false, error: "not authorized approver" },
          { headers: CORS },
        );
      }
      if (status !== "approved" && status !== "rejected") {
        return Response.json(
          { ok: false, error: "invalid status" },
          { headers: CORS },
        );
      }

      const resolved = await resolveApproval(
        env,
        String(approval_id ?? ""),
        status,
        reason,
      );
      if (!resolved.ok) {
        return Response.json(
          { ok: false, error: resolved.error },
          { headers: CORS },
        );
      }

      return Response.json(
        { ok: true, approval_id, status },
        { headers: CORS },
      );
    }

    // ── /telegram/webhook — Telegram ส่งคำตอบ approve/reject ตรงเข้า worker ──
    // (ปิดวง HITL โดยไม่ต้องพึ่ง n8n — เดิม listener มีแต่ฝั่ง LINE)
    if (req.method === "POST" && url.pathname === "/telegram/webhook") {
      // Telegram แนบ secret token ที่ตั้งตอน setWebhook มาใน header นี้เสมอ
      if (
        !env.A2A_SHARED_KEY ||
        req.headers.get("X-Telegram-Bot-Api-Secret-Token") !==
          env.A2A_SHARED_KEY
      ) {
        return Response.json({ ok: false }, { status: 401, headers: CORS });
      }

      let update: any;
      try {
        update = await req.json();
      } catch {
        return Response.json({ ok: false }, { status: 400, headers: CORS });
      }

      const msg = update?.message;
      const text = String(msg?.text ?? "").trim();

      // รับเฉพาะแชทของผู้อนุมัติ (TG_CHAT_ID) เท่านั้น — ตอบ 200 เสมอกัน Telegram retry
      if (String(msg?.chat?.id ?? "") !== String(env.TG_CHAT_ID)) {
        return Response.json(
          { ok: true, ignored: "wrong chat" },
          { headers: CORS },
        );
      }

      const m = text.match(/^(approve|reject)\s+(appr_[A-Za-z0-9]+)/i);
      if (!m) {
        return Response.json(
          { ok: true, ignored: "no command" },
          { headers: CORS },
        );
      }

      const status = m[1].toLowerCase() === "approve" ? "approved" : "rejected";
      const resolved = await resolveApproval(env, m[2], status);
      if (!resolved.ok) {
        // แจ้งกลับว่า resolve ไม่สำเร็จ (เช่น ตอบซ้ำ/ไม่พบ) — best-effort
        try {
          await fetch(
            `https://api.telegram.org/bot${env.TG_BOT_TOKEN}/sendMessage`,
            {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                chat_id: env.TG_CHAT_ID,
                text: `⚠️ ${m[2]}: ${resolved.error}`,
              }),
            },
          );
        } catch (_) {}
      }
      return Response.json(
        { ok: true, approval_id: m[2], status, resolved: resolved.ok },
        { headers: CORS },
      );
    }

    // ── /telegram/setup — สั่ง setWebhook จากใน worker (token ไม่ออกจาก secret) ──
    if (req.method === "POST" && url.pathname === "/telegram/setup") {
      if (
        !env.A2A_SHARED_KEY ||
        req.headers.get("x-a2a-key") !== env.A2A_SHARED_KEY
      ) {
        return Response.json(
          { ok: false, error: "unauthorized" },
          { status: 401, headers: CORS },
        );
      }
      const webhookUrl = `${origin}/telegram/webhook`;
      const res = await fetch(
        `https://api.telegram.org/bot${env.TG_BOT_TOKEN}/setWebhook`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            url: webhookUrl,
            secret_token: env.A2A_SHARED_KEY,
            allowed_updates: ["message"],
          }),
        },
      );
      const tg = await res.json();
      return Response.json(
        { ok: res.ok, webhook: webhookUrl, telegram: tg },
        { headers: CORS },
      );
    }

    return new Response("claw-guardian A2A agent alive 🛡️", { headers: CORS });
  },
} satisfies ExportedHandler<Env>;
