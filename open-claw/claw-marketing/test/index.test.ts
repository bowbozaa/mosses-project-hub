import { TaskState } from "@a2a-js/sdk";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import {
  buildAgentCard,
  buildLegacyAgentCard,
  runMarketingSkill,
  taskStateForResult,
} from "../src/index";

const V1_HEADERS = {
  "Content-Type": "application/json",
  "x-a2a-key": "test-shared-key",
  "A2A-Version": "1.0",
};

// AI double สำหรับ unit test — ไม่ยิง Workers AI จริง
const fakeEnv = (aiResponse?: string) =>
  ({
    AGENT_NAME: "Marketing Agent",
    AGENT_SKILL_ID: "marketing_content_gen",
    AI: aiResponse
      ? { run: async () => ({ response: aiResponse }) }
      : undefined,
  }) as any;

describe("agent cards", () => {
  it("serves an A2A v1 card at the v1 well-known path", async () => {
    const res = await SELF.fetch(
      "https://mkt.test/.well-known/agent-card.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.supportedInterfaces[0].url).toBe(
      "https://mkt.test/a2a/jsonrpc",
    );
    expect(card.skills[0].id).toBe("marketing_content_gen");
  });

  it("keeps the legacy card path", async () => {
    const res = await SELF.fetch("https://mkt.test/.well-known/agent.json");
    const card: any = await res.json();
    expect(card.skills[0].id).toBe("marketing_content_gen");
  });

  it("builds v1 and legacy cards with matching skill id", () => {
    const identity = {
      AGENT_NAME: "Marketing Agent",
      AGENT_SKILL_ID: "marketing_content_gen",
    };
    expect(
      buildAgentCard(identity, "https://x.test").securitySchemes.a2aSharedKey
        ?.scheme?.$case,
    ).toBe("apiKeySecurityScheme");
    expect(buildLegacyAgentCard(identity, "https://x.test").skills[0].id).toBe(
      "marketing_content_gen",
    );
  });
});

describe("marketing skill", () => {
  it("generates a caption via the AI double", async () => {
    const result: any = await runMarketingSkill(
      { topic: "บอลโลก 2026", platform: "facebook", tone: "exciting" },
      fakeEnv("🔥 บอลโลกมาแล้ว! #WorldCup2026"),
    );
    expect(result.caption).toContain("บอลโลก");
    expect(result.platform).toBe("facebook");
  });

  it("fails without a topic", async () => {
    const result = await runMarketingSkill({}, fakeEnv("x"));
    expect(result.verdict).toBe("FAIL");
    expect(taskStateForResult(result)).toBe(TaskState.TASK_STATE_REJECTED);
  });

  it("fails cleanly when the AI binding is unavailable", async () => {
    const result = await runMarketingSkill({ topic: "test" }, fakeEnv());
    expect(result.verdict).toBe("FAIL");
    expect(result.reason).toBe("AI binding unavailable");
  });
});

describe("A2A v1 JSON-RPC endpoint", () => {
  it("rejects requests without the shared key / version header", async () => {
    const noKey = await SELF.fetch("https://mkt.test/a2a/jsonrpc", {
      method: "POST",
      headers: { "Content-Type": "application/json", "A2A-Version": "1.0" },
      body: "{}",
    });
    expect(noKey.status).toBe(401);

    const noVersion = await SELF.fetch("https://mkt.test/a2a/jsonrpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: "{}",
    });
    expect(noVersion.status).toBe(400);
  });

  it("runs the full v1 pipeline (missing topic → REJECTED, task persisted)", async () => {
    // ใน test env ไม่มี AI binding — เคส missing topic จบก่อนถึง AI จึงเทสต์ v1 flow ได้เต็มวง
    const res = await SELF.fetch("https://mkt.test/a2a/jsonrpc", {
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
              { data: { note: "no topic" }, mediaType: "application/json" },
            ],
          },
        },
      }),
    });
    expect(res.status).toBe(200);
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_REJECTED");
    expect(serialized).toContain("missing topic");
  });
});

describe("legacy surface", () => {
  it("keeps the legacy message/send shape (FAIL path)", async () => {
    const res = await SELF.fetch("https://mkt.test/", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "req-1",
        method: "message/send",
        params: { message: { parts: [{ kind: "data", data: {} }] } },
      }),
    });
    const body: any = await res.json();
    expect(body.result.parts[0].data.verdict).toBe("FAIL");
  });

  it("serves /health with v2", async () => {
    const res = await SELF.fetch("https://mkt.test/health");
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.version).toBe("2.0.0");
  });

  it("rejects wrong shared key", async () => {
    const res = await SELF.fetch("https://mkt.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-a2a-key": "wrong" },
      body: JSON.stringify({ jsonrpc: "2.0", id: "x", method: "message/send" }),
    });
    const body: any = await res.json();
    expect(body.error.code).toBe(-32001);
  });
});
