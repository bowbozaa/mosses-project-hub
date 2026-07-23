import { TaskState } from "@a2a-js/sdk";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import {
  buildAgentCard,
  buildLegacyAgentCard,
  runDevopsSkill,
  taskStateForResult,
} from "../src/index";

const V1_HEADERS = {
  "Content-Type": "application/json",
  "x-a2a-key": "test-shared-key",
  "A2A-Version": "1.0",
};

async function legacySend(data: Record<string, unknown>) {
  const res = await SELF.fetch("https://devops.test/", {
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
      "https://devops.test/.well-known/agent-card.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.supportedInterfaces[0].url).toBe(
      "https://devops.test/a2a/jsonrpc",
    );
    expect(card.skills[0].id).toBe("devops_ops_check");
  });

  it("keeps the legacy card path", async () => {
    const res = await SELF.fetch("https://devops.test/.well-known/agent.json");
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.skills[0].id).toBe("devops_ops_check");
  });

  it("builds a v1 card with the shared-key security scheme", () => {
    const card = buildAgentCard(
      { AGENT_NAME: "DevOps Agent", AGENT_SKILL_ID: "devops_ops_check" },
      "https://devops.example.com",
    );
    expect(card.securitySchemes.a2aSharedKey?.scheme?.$case).toBe(
      "apiKeySecurityScheme",
    );
    expect(
      buildLegacyAgentCard(
        { AGENT_NAME: "DevOps Agent", AGENT_SKILL_ID: "devops_ops_check" },
        "https://devops.example.com",
      ).skills[0].id,
    ).toBe("devops_ops_check");
  });
});

describe("devops skill", () => {
  it("lists known workers", async () => {
    const result = await runDevopsSkill({ op: "list" });
    expect(result.count).toBe(7);
    expect(result.workers).toContain("claw-guardian.banknakorn39.workers.dev");
  });

  it("checks health of a target (mocked outbound)", async () => {
    const result: any = await runDevopsSkill({
      op: "health",
      target: "claw-guardian.banknakorn39.workers.dev",
    });
    expect(result.ok).toBe(true);
    expect(result.worker).toBe("claw-guardian.banknakorn39.workers.dev");
  });

  it("runs drift check across all workers", async () => {
    const result: any = await runDevopsSkill({ op: "drift" });
    expect(result.checked).toBe(7);
    expect(result.statuses).toHaveLength(7);
    expect(result.all_ok).toBe(true);
  });

  it("fails unknown ops", async () => {
    const result = await runDevopsSkill({ op: "explode" });
    expect(result.verdict).toBe("FAIL");
    expect(taskStateForResult(result)).toBe(TaskState.TASK_STATE_REJECTED);
    expect(taskStateForResult({ ok: true })).toBe(
      TaskState.TASK_STATE_COMPLETED,
    );
  });
});

describe("A2A v1 JSON-RPC endpoint", () => {
  it("rejects requests without the shared key", async () => {
    const res = await SELF.fetch("https://devops.test/a2a/jsonrpc", {
      method: "POST",
      headers: { "Content-Type": "application/json", "A2A-Version": "1.0" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("rejects requests without the A2A-Version header", async () => {
    const res = await SELF.fetch("https://devops.test/a2a/jsonrpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: "{}",
    });
    expect(res.status).toBe(400);
  });

  it("completes a SendMessage list op", async () => {
    const res = await SELF.fetch("https://devops.test/a2a/jsonrpc", {
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
            parts: [{ data: { op: "list" }, mediaType: "application/json" }],
          },
        },
      }),
    });
    expect(res.status).toBe(200);
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_COMPLETED");
    expect(serialized).toContain("workers");
  });
});

describe("legacy message/send", () => {
  it("keeps the legacy response shape claw-brain parses", async () => {
    const data = await legacySend({ op: "list" });
    expect(data.count).toBe(7);
  });

  it("serves /health", async () => {
    const res = await SELF.fetch("https://devops.test/health");
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.version).toBe("2.0.0");
  });

  it("rejects wrong shared key", async () => {
    const res = await SELF.fetch("https://devops.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-a2a-key": "wrong" },
      body: JSON.stringify({ jsonrpc: "2.0", id: "x", method: "message/send" }),
    });
    const body: any = await res.json();
    expect(body.error.code).toBe(-32001);
  });
});
