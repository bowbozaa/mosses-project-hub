import { TaskState } from "@a2a-js/sdk";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import {
  buildAgentCard,
  buildLegacyAgentCard,
  runCreativeSkill,
  taskStateForResult,
} from "../src/index";

const V1_HEADERS = {
  "Content-Type": "application/json",
  "x-a2a-key": "test-shared-key",
  "A2A-Version": "1.0",
};

// AI double — ไม่ยิง Workers AI จริง
const fakeEnv = (aiResponse?: string) =>
  ({
    AGENT_NAME: "Creative Agent",
    AGENT_SKILL_ID: "creative_generate",
    AI: aiResponse
      ? { run: async () => ({ response: aiResponse }) }
      : undefined,
  }) as any;

describe("agent cards", () => {
  it("serves an A2A v1 card with the 4 sub-skills", async () => {
    const res = await SELF.fetch(
      "https://creative.test/.well-known/agent-card.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.supportedInterfaces[0].url).toBe(
      "https://creative.test/a2a/jsonrpc",
    );
    expect(card.skills.map((s: any) => s.id)).toEqual([
      "creative_text",
      "creative_caption",
      "creative_translate",
      "creative_summarize",
    ]);
  });

  it("keeps the legacy card path", async () => {
    const res = await SELF.fetch(
      "https://creative.test/.well-known/agent.json",
    );
    const card: any = await res.json();
    expect(card.skills).toHaveLength(4);
  });

  it("builds v1 and legacy cards consistently", () => {
    const identity = {
      AGENT_NAME: "Creative Agent",
      AGENT_SKILL_ID: "creative_generate",
    };
    expect(buildAgentCard(identity, "https://x.test").skills).toHaveLength(4);
    expect(
      buildLegacyAgentCard(identity, "https://x.test").skills,
    ).toHaveLength(4);
  });
});

describe("creative skill", () => {
  it("generates text via the AI double", async () => {
    const result: any = await runCreativeSkill(
      { skill: "text", prompt: "เขียนคำคม" },
      fakeEnv("ชีวิตคือการเดินทาง ✨"),
    );
    expect(result.text).toContain("เดินทาง");
  });

  it("translates via the AI double", async () => {
    const result: any = await runCreativeSkill(
      { skill: "translate", text: "hello", to: "th" },
      fakeEnv("สวัสดี"),
    );
    expect(result.translation).toBe("สวัสดี");
    expect(result.to).toBe("th");
  });

  it("errors per-skill on missing input (live shape: error field)", async () => {
    expect(
      (await runCreativeSkill({ skill: "text" }, fakeEnv("x"))).error,
    ).toBe("prompt required");
    expect(
      (await runCreativeSkill({ skill: "caption" }, fakeEnv("x"))).error,
    ).toBe("topic required");
    expect(
      (await runCreativeSkill({ skill: "translate" }, fakeEnv("x"))).error,
    ).toBe("text required");
    expect(
      (await runCreativeSkill({ skill: "summarize" }, fakeEnv("x"))).error,
    ).toBe("text required");
    const unknown = await runCreativeSkill({ skill: "dance" }, fakeEnv("x"));
    expect(String(unknown.error)).toContain("unknown skill");
  });

  it("maps error results to REJECTED", () => {
    expect(taskStateForResult({ error: "x" })).toBe(
      TaskState.TASK_STATE_REJECTED,
    );
    expect(taskStateForResult({ text: "ok" })).toBe(
      TaskState.TASK_STATE_COMPLETED,
    );
  });
});

describe("A2A v1 JSON-RPC endpoint", () => {
  it("rejects requests without the shared key / version header", async () => {
    const noKey = await SELF.fetch("https://creative.test/a2a/jsonrpc", {
      method: "POST",
      headers: { "Content-Type": "application/json", "A2A-Version": "1.0" },
      body: "{}",
    });
    expect(noKey.status).toBe(401);

    const noVersion = await SELF.fetch("https://creative.test/a2a/jsonrpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: "{}",
    });
    expect(noVersion.status).toBe(400);
  });

  it("runs the full v1 pipeline (missing prompt → REJECTED)", async () => {
    const res = await SELF.fetch("https://creative.test/a2a/jsonrpc", {
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
            parts: [{ data: { skill: "text" }, mediaType: "application/json" }],
          },
        },
      }),
    });
    expect(res.status).toBe(200);
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_REJECTED");
    expect(serialized).toContain("prompt required");
  });
});

describe("legacy surface", () => {
  it("serves the legacy status json at GET /", async () => {
    const res = await SELF.fetch("https://creative.test/");
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.name).toBe("claw-creative");
  });

  it("keeps the legacy message/send shape (error path)", async () => {
    const res = await SELF.fetch("https://creative.test/", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "req-1",
        method: "message/send",
        params: {
          message: { parts: [{ kind: "data", data: { skill: "text" } }] },
        },
      }),
    });
    const body: any = await res.json();
    expect(body.result.parts[0].data.error).toBe("prompt required");
  });

  it("serves /health with v2", async () => {
    const res = await SELF.fetch("https://creative.test/health");
    const body: any = await res.json();
    expect(body.version).toBe("2.0.0");
  });

  it("rejects wrong shared key on legacy path", async () => {
    const res = await SELF.fetch("https://creative.test/", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-a2a-key": "wrong" },
      body: JSON.stringify({ jsonrpc: "2.0", id: "x", method: "message/send" }),
    });
    const body: any = await res.json();
    expect(body.error.code).toBe(-32001);
  });
});
