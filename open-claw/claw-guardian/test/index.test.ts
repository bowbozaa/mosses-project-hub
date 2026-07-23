import { TaskState } from "@a2a-js/sdk";
import { SELF } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  buildAgentCard,
  buildLegacyAgentCard,
  runGuardianSkill,
  taskStateForVerdict,
} from "../src/index";

// Telegram outbound ถูกดักใน vitest.config.ts (outboundService):
// ปกติตอบ 200, ถ้า action มี __fail_push__ ตอบ 500 เพื่อจำลอง Telegram ล่ม

const V1_HEADERS = {
  "Content-Type": "application/json",
  "x-a2a-key": "test-shared-key",
  "A2A-Version": "1.0",
};

async function legacySend(data: Record<string, unknown>) {
  const res = await SELF.fetch("https://guardian.test/", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-a2a-key": "test-shared-key",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: "req-1",
      method: "message/send",
      params: { message: { parts: [{ kind: "data", data }] } },
    }),
  });
  expect(res.status).toBe(200);
  const body: any = await res.json();
  expect(body.error).toBeUndefined();
  return body.result.parts[0].data;
}

describe("agent cards", () => {
  it("serves an A2A v1 card at the v1 well-known path", async () => {
    const res = await SELF.fetch(
      "https://guardian.test/.well-known/agent-card.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.supportedInterfaces[0].url).toBe(
      "https://guardian.test/a2a/jsonrpc",
    );
    expect(card.supportedInterfaces[0].protocolVersion).toBe("1.0");
    expect(card.skills[0].id).toBe("guardian_policy_check");
  });

  it("keeps the legacy card path for claw-brain /agents", async () => {
    const res = await SELF.fetch(
      "https://guardian.test/.well-known/agent.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.skills[0].id).toBe("guardian_policy_check");
  });

  it("builds a v1 card with the shared-key security scheme", () => {
    const card = buildAgentCard(
      { AGENT_NAME: "Guardian Agent", AGENT_SKILL_ID: "guardian_policy_check" },
      "https://guardian.example.com",
    );
    expect(card.securitySchemes.a2aSharedKey?.scheme?.$case).toBe(
      "apiKeySecurityScheme",
    );
    expect(card.securityRequirements).toHaveLength(1);
    expect(
      buildLegacyAgentCard(
        {
          AGENT_NAME: "Guardian Agent",
          AGENT_SKILL_ID: "guardian_policy_check",
        },
        "https://guardian.example.com",
      ).skills[0].id,
    ).toBe("guardian_policy_check");
  });
});

describe("verdict → task state mapping (fail-closed)", () => {
  it("maps verdicts per the A2A v1 blueprint", () => {
    expect(taskStateForVerdict("PASS")).toBe(TaskState.TASK_STATE_COMPLETED);
    expect(taskStateForVerdict("FAIL")).toBe(TaskState.TASK_STATE_REJECTED);
    expect(taskStateForVerdict("BLOCKED")).toBe(TaskState.TASK_STATE_REJECTED);
    expect(taskStateForVerdict("PENDING_APPROVAL")).toBe(
      TaskState.TASK_STATE_INPUT_REQUIRED,
    );
    expect(taskStateForVerdict("MANUAL_REVIEW")).toBe(
      TaskState.TASK_STATE_INPUT_REQUIRED,
    );
    expect(taskStateForVerdict("UNRECOGNIZED")).toBe(
      TaskState.TASK_STATE_INPUT_REQUIRED,
    );
  });
});

describe("guardian skill (fail-closed policy)", () => {
  it("passes LOW-risk actions that match a policy", async () => {
    const verdict = await runGuardianSkill({ action: "read logs" }, env as any);
    expect(verdict.verdict).toBe("PASS");
    expect(verdict.approval_needed).toBe(false);
  });

  it("fails closed to MANUAL_REVIEW when no policy matches", async () => {
    const verdict = await runGuardianSkill(
      { action: "frobnicate the flux capacitor" },
      env as any,
    );
    expect(verdict.verdict).toBe("MANUAL_REVIEW");
    expect(verdict.reason).toBe("no_matching_policy");
    expect(verdict.approval_needed).toBe(true);
  });

  it("fails a malformed request with no action (live behavior)", async () => {
    const verdict = await runGuardianSkill({}, env as any);
    expect(verdict.verdict).toBe("FAIL");
    expect(verdict.reason).toBe("missing 'action' field");
  });

  it("blocks and cleans up the pending row when the Telegram push fails", async () => {
    const verdict = await runGuardianSkill(
      { action: "deploy __fail_push__ worker", requested_by: "test" },
      env as any,
    );
    expect(verdict.verdict).toBe("BLOCKED");
    expect(verdict.reason).toContain("telegram_push_failed");
    // pending row ต้องถูกลบทิ้ง (fail-closed cleanup)
    const row = await env.DB.prepare(
      "SELECT id FROM pending_approvals WHERE id = ?",
    )
      .bind(verdict.approval_id)
      .first();
    expect(row).toBeNull();
  });
});

describe("A2A v1 JSON-RPC endpoint", () => {
  it("rejects requests without the shared key", async () => {
    const res = await SELF.fetch("https://guardian.test/a2a/jsonrpc", {
      method: "POST",
      headers: { "Content-Type": "application/json", "A2A-Version": "1.0" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("rejects requests without the A2A-Version header", async () => {
    const res = await SELF.fetch("https://guardian.test/a2a/jsonrpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: "{}",
    });
    expect(res.status).toBe(400);
  });

  it("completes a SendMessage task for a LOW-risk action", async () => {
    const res = await SELF.fetch("https://guardian.test/a2a/jsonrpc", {
      method: "POST",
      headers: V1_HEADERS,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "v1-req-1",
        method: "SendMessage",
        params: {
          message: {
            messageId: "message-1",
            role: "ROLE_USER",
            parts: [
              {
                data: { action: "read task history" },
                mediaType: "application/json",
              },
            ],
          },
        },
      }),
    });
    expect(res.status).toBe(200);
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("PASS");
    expect(serialized).toContain("TASK_STATE_COMPLETED");
  });

  it("returns INPUT_REQUIRED for a HIGH-risk action pending approval", async () => {
    const res = await SELF.fetch("https://guardian.test/a2a/jsonrpc", {
      method: "POST",
      headers: V1_HEADERS,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "v1-req-2",
        method: "SendMessage",
        params: {
          message: {
            messageId: "message-2",
            role: "ROLE_USER",
            parts: [
              {
                data: { action: "deploy worker x", requested_by: "vitest" },
                mediaType: "application/json",
              },
            ],
          },
        },
      }),
    });
    expect(res.status).toBe(200);
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("PENDING_APPROVAL");
    expect(serialized).toContain("TASK_STATE_INPUT_REQUIRED");
  });
});

describe("legacy message/send + approval lifecycle", () => {
  it("keeps the legacy response shape claw-brain parses", async () => {
    const data = await legacySend({ action: "read logs" });
    expect(data.verdict).toBe("PASS");
  });

  it("runs the full approve lifecycle: pending → resolve → completed", async () => {
    const pending = await legacySend({
      action: "deploy worker x",
      requested_by: "vitest",
    });
    expect(pending.verdict).toBe("PENDING_APPROVAL");
    const approvalId = pending.approval_id as string;
    expect(approvalId).toMatch(/^appr_/);

    // ยัง pending → /tasks/get = working
    let poll = await SELF.fetch("https://guardian.test/tasks/get", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ approval_id: approvalId }),
    });
    expect(((await poll.json()) as any).state).toBe("working");

    // UID ผิด → ปฏิเสธ
    const badUid = await SELF.fetch("https://guardian.test/approvals/resolve", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: JSON.stringify({
        approval_id: approvalId,
        status: "approved",
        requester_uid: "U_intruder",
      }),
    });
    expect(((await badUid.json()) as any).ok).toBe(false);

    // ไม่มี key → 401
    const noKey = await SELF.fetch("https://guardian.test/approvals/resolve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        approval_id: approvalId,
        status: "approved",
        requester_uid: "U_test_approver",
      }),
    });
    expect(noKey.status).toBe(401);

    // status แปลก → ปฏิเสธ
    const badStatus = await SELF.fetch(
      "https://guardian.test/approvals/resolve",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-a2a-key": "test-shared-key",
        },
        body: JSON.stringify({
          approval_id: approvalId,
          status: "maybe",
          requester_uid: "U_test_approver",
        }),
      },
    );
    expect(((await badStatus.json()) as any).ok).toBe(false);

    // approve จริง → ok
    const resolve = await SELF.fetch(
      "https://guardian.test/approvals/resolve",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-a2a-key": "test-shared-key",
        },
        body: JSON.stringify({
          approval_id: approvalId,
          status: "approved",
          requester_uid: "U_test_approver",
        }),
      },
    );
    const resolved: any = await resolve.json();
    expect(resolved.ok).toBe(true);

    // resolve ซ้ำ → ปฏิเสธ (conditional update)
    const twice = await SELF.fetch("https://guardian.test/approvals/resolve", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: JSON.stringify({
        approval_id: approvalId,
        status: "rejected",
        requester_uid: "U_test_approver",
      }),
    });
    expect(((await twice.json()) as any).ok).toBe(false);

    // approved แล้ว → /tasks/get = completed
    poll = await SELF.fetch("https://guardian.test/tasks/get", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ approval_id: approvalId }),
    });
    expect(((await poll.json()) as any).state).toBe("completed");
  });

  it("rejects legacy calls with a wrong shared key", async () => {
    const res = await SELF.fetch("https://guardian.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-a2a-key": "wrong" },
      body: JSON.stringify({ jsonrpc: "2.0", id: "x", method: "message/send" }),
    });
    const body: any = await res.json();
    expect(body.error.code).toBe(-32001);
  });
});

describe("telegram webhook (HITL listener)", () => {
  const TG_SECRET = { "X-Telegram-Bot-Api-Secret-Token": "test-shared-key" };

  function tgUpdate(text: string, chatId: string | number = "-100999") {
    return JSON.stringify({
      update_id: 1,
      message: { chat: { id: chatId }, text },
    });
  }

  it("rejects updates without the webhook secret token", async () => {
    const res = await SELF.fetch("https://guardian.test/telegram/webhook", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: tgUpdate("approve appr_x"),
    });
    expect(res.status).toBe(401);
  });

  it("ignores messages from other chats and non-commands", async () => {
    const wrongChat = await SELF.fetch(
      "https://guardian.test/telegram/webhook",
      {
        method: "POST",
        headers: { "Content-Type": "application/json", ...TG_SECRET },
        body: tgUpdate("approve appr_x", "999123"),
      },
    );
    expect(((await wrongChat.json()) as any).ignored).toBe("wrong chat");

    const chatter = await SELF.fetch("https://guardian.test/telegram/webhook", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...TG_SECRET },
      body: tgUpdate("สวัสดีตอนเช้า"),
    });
    expect(((await chatter.json()) as any).ignored).toBe("no command");
  });

  it("resolves a pending approval from a telegram reply", async () => {
    // สร้าง pending ผ่าน legacy path (Telegram push ถูก mock ใน outboundService)
    const pending = await legacySend({
      action: "deploy webhook test",
      requested_by: "vitest",
    });
    const approvalId = pending.approval_id as string;

    const res = await SELF.fetch("https://guardian.test/telegram/webhook", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...TG_SECRET },
      body: tgUpdate(`approve ${approvalId}`),
    });
    const body: any = await res.json();
    expect(body.resolved).toBe(true);
    expect(body.status).toBe("approved");

    // ตอบซ้ำ → resolved:false (conditional update)
    const twice = await SELF.fetch("https://guardian.test/telegram/webhook", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...TG_SECRET },
      body: tgUpdate(`reject ${approvalId}`),
    });
    expect(((await twice.json()) as any).resolved).toBe(false);

    // สถานะกลายเป็น completed
    const poll = await SELF.fetch("https://guardian.test/tasks/get", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ approval_id: approvalId }),
    });
    expect(((await poll.json()) as any).state).toBe("completed");
  });

  it("registers the webhook via /telegram/setup (auth required)", async () => {
    const noKey = await SELF.fetch("https://guardian.test/telegram/setup", {
      method: "POST",
    });
    expect(noKey.status).toBe(401);

    const res = await SELF.fetch("https://guardian.test/telegram/setup", {
      method: "POST",
      headers: { "x-a2a-key": "test-shared-key" },
    });
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.webhook).toBe("https://guardian.test/telegram/webhook");
  });
});
