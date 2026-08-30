import { TaskState } from "@a2a-js/sdk";
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import {
  buildAgentCard,
  buildLegacyAgentCard,
  routeIntent,
  taskStateForOrchestration,
} from "../src/index";

const BRAIN_AUTH = { Authorization: "Bearer test-brain-key" };
const V1_HEADERS = {
  "Content-Type": "application/json",
  "x-a2a-key": "test-shared-key",
  "A2A-Version": "1.0",
};

describe("status + discovery", () => {
  it("serves the legacy status json", async () => {
    const res = await SELF.fetch("https://brain.test/");
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.agents).toHaveLength(5);
  });

  it("serves the v1 orchestrator card", async () => {
    const res = await SELF.fetch(
      "https://brain.test/.well-known/agent-card.json",
    );
    expect(res.status).toBe(200);
    const card: any = await res.json();
    expect(card.supportedInterfaces[0].url).toBe(
      "https://brain.test/a2a/jsonrpc",
    );
    expect(card.skills[0].id).toBe("claw_orchestrate");
  });

  it("serves the legacy card and aggregates specialist cards", async () => {
    const legacy = await SELF.fetch(
      "https://brain.test/.well-known/agent.json",
    );
    expect(((await legacy.json()) as any).skills[0].id).toBe(
      "claw_orchestrate",
    );

    const res = await SELF.fetch("https://brain.test/agents");
    const body: any = await res.json();
    expect(body.agents).toHaveLength(5);
    expect(body.agents[0].card.name).toBe("guardian");
  });

  it("builds cards consistently", () => {
    const identity = { AGENT_NAME: "CLAW BRAIN" };
    expect(buildAgentCard(identity, "https://x.test").skills[0].id).toBe(
      "claw_orchestrate",
    );
    expect(buildLegacyAgentCard(identity, "https://x.test").skills[0].id).toBe(
      "claw_orchestrate",
    );
  });
});

describe("routing", () => {
  it("routes intents deterministically (live table)", () => {
    expect(routeIntent("deploy worker x")).toEqual({
      agent: "devops",
      skill: "deploy",
    });
    expect(routeIntent("query recent tasks")).toEqual({
      agent: "data",
      skill: "query",
    });
    expect(routeIntent("broadcast to line")).toEqual({
      agent: "marketing",
      skill: "broadcast",
    });
    expect(routeIntent("translate hello")).toEqual({
      agent: "creative",
      skill: "translate",
    });
    expect(routeIntent("อะไรก็ไม่รู้")).toEqual({
      agent: "guardian",
      skill: "policy_check",
    });
  });

  it("maps orchestration results to task states", () => {
    expect(taskStateForOrchestration({ error: "x" })).toBe(
      TaskState.TASK_STATE_FAILED,
    );
    expect(taskStateForOrchestration({ verdict: "PENDING_APPROVAL" })).toBe(
      TaskState.TASK_STATE_INPUT_REQUIRED,
    );
    expect(taskStateForOrchestration({ verdict: "BLOCKED" })).toBe(
      TaskState.TASK_STATE_REJECTED,
    );
    expect(taskStateForOrchestration({ mock: "ok" })).toBe(
      TaskState.TASK_STATE_COMPLETED,
    );
  });
});

describe("legacy endpoints (BRAIN_API_KEY auth)", () => {
  it("rejects /run without auth", async () => {
    const res = await SELF.fetch("https://brain.test/run", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ intent: "translate hello" }),
    });
    expect(res.status).toBe(401);
  });

  it("routes /run intents to the mocked specialist", async () => {
    const res = await SELF.fetch("https://brain.test/run", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...BRAIN_AUTH },
      body: JSON.stringify({ intent: "translate hello to thai" }),
    });
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.agent).toBe("creative");
    expect(body.result.mock).toBe("creative");
  });

  it("dispatches directly and validates agent names", async () => {
    const ok = await SELF.fetch("https://brain.test/dispatch", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...BRAIN_AUTH },
      body: JSON.stringify({
        agent: "devops",
        skill: "ops_check",
        data: { op: "list" },
      }),
    });
    const okBody: any = await ok.json();
    expect(okBody.ok).toBe(true);
    expect(okBody.result.mock).toBe("devops");

    const bad = await SELF.fetch("https://brain.test/dispatch", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...BRAIN_AUTH },
      body: JSON.stringify({ agent: "hacker", skill: "x" }),
    });
    expect(bad.status).toBe(400);
  });

  it("runs a pipeline and fails closed to manual_review", async () => {
    const res = await SELF.fetch("https://brain.test/pipeline", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...BRAIN_AUTH },
      body: JSON.stringify({
        steps: [
          { agent: "data", skill: "d1_recent" },
          { agent: "devops", skill: "boom" },
          { agent: "creative", skill: "text" },
        ],
      }),
    });
    const body: any = await res.json();
    expect(body.ok).toBe(false);
    expect(body.state).toBe("manual_review");
    expect(body.failed_at_step).toBe(1);
    expect(body.steps_completed).toBe(1);
  });

  it("continues past optional failing steps", async () => {
    const res = await SELF.fetch("https://brain.test/pipeline", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...BRAIN_AUTH },
      body: JSON.stringify({
        steps: [
          { agent: "devops", skill: "boom", optional: true },
          { agent: "creative", skill: "text" },
        ],
      }),
    });
    const body: any = await res.json();
    expect(body.ok).toBe(true);
    expect(body.state).toBe("completed");
    expect(body.steps_completed).toBe(1);
  });
});

describe("A2A v1 ingress", () => {
  it("rejects without key / version", async () => {
    const noKey = await SELF.fetch("https://brain.test/a2a/jsonrpc", {
      method: "POST",
      headers: { "Content-Type": "application/json", "A2A-Version": "1.0" },
      body: "{}",
    });
    expect(noKey.status).toBe(401);

    const noVersion = await SELF.fetch("https://brain.test/a2a/jsonrpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-a2a-key": "test-shared-key",
      },
      body: "{}",
    });
    expect(noVersion.status).toBe(400);
  });

  it("orchestrates a direct dispatch via SendMessage", async () => {
    const res = await SELF.fetch("https://brain.test/a2a/jsonrpc", {
      method: "POST",
      headers: V1_HEADERS,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "v1-1",
        method: "SendMessage",
        params: {
          message: {
            messageId: "m1",
            role: "ROLE_USER",
            parts: [
              {
                data: {
                  agent: "devops",
                  skill: "ops_check",
                  data: { op: "list" },
                },
                mediaType: "application/json",
              },
            ],
          },
        },
      }),
    });
    const body: any = await res.json();
    expect(body.error).toBeUndefined();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_COMPLETED");
    expect(serialized).toContain("devops/ops_check");
  });

  it("orchestrates intent routing via SendMessage", async () => {
    const res = await SELF.fetch("https://brain.test/a2a/jsonrpc", {
      method: "POST",
      headers: V1_HEADERS,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "v1-2",
        method: "SendMessage",
        params: {
          message: {
            messageId: "m2",
            role: "ROLE_USER",
            parts: [
              {
                data: { intent: "summarize this text", data: { text: "hi" } },
                mediaType: "application/json",
              },
            ],
          },
        },
      }),
    });
    const body: any = await res.json();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_COMPLETED");
    expect(serialized).toContain("creative/summarize");
  });

  it("surfaces guardian PENDING_APPROVAL as INPUT_REQUIRED", async () => {
    const res = await SELF.fetch("https://brain.test/a2a/jsonrpc", {
      method: "POST",
      headers: V1_HEADERS,
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "v1-3",
        method: "SendMessage",
        params: {
          message: {
            messageId: "m3",
            role: "ROLE_USER",
            parts: [
              {
                data: {
                  agent: "guardian",
                  skill: "policy_check",
                  data: { action: "deploy worker x" },
                },
                mediaType: "application/json",
              },
            ],
          },
        },
      }),
    });
    const body: any = await res.json();
    const serialized = JSON.stringify(body.result);
    expect(serialized).toContain("TASK_STATE_INPUT_REQUIRED");
    expect(serialized).toContain("appr_test1");
  });
});
