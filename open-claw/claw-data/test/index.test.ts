import { TaskState } from "@a2a-js/sdk";
import { SELF } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  buildAgentCard,
  buildLegacyAgentCard,
  runDataSkill,
  taskStateForResult,
} from "../src/index";

const V1_HEADERS = {
  "Content-Type": "application/json",
  "x-a2a-key": "test-shared-key",
  "A2A-Version": "1.0",
};

async function legacySend(data: Record<string, unknown>) {
  const res = await SELF.fetch("https://data.test/", {
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
      "https://data.test/.well-known/agent-card.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.supportedInterfaces[0].url).toBe(
      "https://data.test/a2a/jsonrpc",
    );
    expect(card.skills[0].id).toBe("data_query_report");
  });

  it("keeps the legacy card path", async () => {
    const res = await SELF.fetch("https://data.test/.well-known/agent.json");
    const card: any = await res.json();
    expect(card.skills[0].id).toBe("data_query_report");
  });

  it("builds v1 and legacy cards with matching skill id", () => {
    const identity = {
      AGENT_NAME: "Data Agent",
      AGENT_SKILL_ID: "data_query_report",
    };
    expect(
      buildAgentCard(identity, "https://x.test").securitySchemes.a2aSharedKey
        ?.scheme?.$case,
    ).toBe("apiKeySecurityScheme");
    expect(buildLegacyAgentCard(identity, "https://x.test").skills[0].id).toBe(
      "data_query_report",
    );
  });
});

describe("data skill", () => {
  it("queries recent task history", async () => {
    await env.DB.prepare(
      "INSERT INTO task_history (id, agent, skill, result, ok, created_at) VALUES ('t1','Test','s','{}',1,'2026-07-23T00:00:00Z')",
    ).run();
    const result: any = await runDataSkill({ op: "d1_recent" }, env as any);
    expect(result.op).toBe("d1_recent");
    expect(result.count).toBeGreaterThanOrEqual(1);
  });

  it("queries guardian policies (seeded)", async () => {
    const result: any = await runDataSkill({ op: "d1_policy" }, env as any);
    expect(result.count).toBe(4);
  });

  it("searches the brain (mocked outbound)", async () => {
    const result: any = await runDataSkill(
      { op: "brain_search", query: "FRIDAY status" },
      env as any,
    );
    expect(result.op).toBe("brain_search");
    expect(JSON.stringify(result.results)).toContain("mock knowledge");
  });

  it("fails brain_search without a query", async () => {
    const result = await runDataSkill({ op: "brain_search" }, env as any);
    expect(result.verdict).toBe("FAIL");
  });

  it("fails brain_search when the Brain API errors", async () => {
    const result: any = await runDataSkill(
      { op: "brain_search", query: "__brain_down__" },
      env as any,
    );
    expect(result.verdict).toBe("FAIL");
    expect(String(result.reason)).toContain("Brain API 500");
  });

  it("fails unknown ops and maps to REJECTED", async () => {
    const result = await runDataSkill({ op: "explode" }, env as any);
    expect(result.verdict).toBe("FAIL");
    expect(taskStateForResult(result)).toBe(TaskState.TASK_STATE_REJECTED);
  });
});

describe("A2A v1 JSON-RPC endpoint", () => {
  it("rejects requests without the shared key / version header", async () => {
    const noKey = await SELF.fetch("https://data.test/a2a/jsonrpc", {
      method: "POST",
      headers: { "Content-Type": "application/json", "A2A-Version": "1.0" },
      body: "{}",
    });
    expect(noKey.status).toBe(401);

    const noVersion = await SELF.fetch("https://data.test/a2a/jsonrpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: "{}",
    });
    expect(noVersion.status).toBe(400);
  });

  it("completes a SendMessage d1_policy op", async () => {
    const res = await SELF.fetch("https://data.test/a2a/jsonrpc", {
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
              { data: { op: "d1_policy" }, mediaType: "application/json" },
            ],
          },
        },
      }),
    });
    expect(res.status).toBe(200);
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_COMPLETED");
    expect(serialized).toContain("pol_deploy");
  });
});

describe("legacy surface", () => {
  it("keeps the legacy message/send shape", async () => {
    const data = await legacySend({ op: "d1_policy" });
    expect(data.count).toBe(4);
  });

  it("serves /health with v2", async () => {
    const res = await SELF.fetch("https://data.test/health");
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.version).toBe("2.0.0");
  });

  it("rejects wrong shared key", async () => {
    const res = await SELF.fetch("https://data.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-a2a-key": "wrong" },
      body: JSON.stringify({ jsonrpc: "2.0", id: "x", method: "message/send" }),
    });
    const body: any = await res.json();
    expect(body.error.code).toBe(-32001);
  });
});
