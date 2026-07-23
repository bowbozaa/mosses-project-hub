import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Mock specialist: ตอบ agent.json + message/send ตาม protocol legacy
// - ตรวจ x-a2a-key ว่า brain ส่ง key มาจริง
// - guardian: action มี "deploy" → PENDING_APPROVAL, อื่น ๆ → PASS
// - skill "boom" → JSON-RPC error (ใช้เทสต์ pipeline fail → manual_review)
function mockSpecialist(name: string) {
  return async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    if (url.pathname === "/.well-known/agent.json") {
      return Response.json({ name, skills: [{ id: name + "_skill" }] });
    }
    if (request.method === "POST" && url.pathname === "/") {
      if (request.headers.get("x-a2a-key") !== "test-shared-key") {
        return Response.json({
          jsonrpc: "2.0",
          id: null,
          error: { code: -32001, message: "unauthorized" },
        });
      }
      const body: any = await request.json();
      const data = body?.params?.message?.parts?.[0]?.data ?? {};
      if (data.skill === "boom") {
        return Response.json({
          jsonrpc: "2.0",
          id: body.id,
          error: { code: -32000, message: "boom failed" },
        });
      }
      let result: Record<string, unknown> = {
        mock: name,
        echo_skill: data.skill,
      };
      if (name === "guardian") {
        result = String(data.action ?? "").includes("deploy")
          ? {
              verdict: "PENDING_APPROVAL",
              approval_id: "appr_test1",
              approval_needed: true,
            }
          : { verdict: "PASS", approval_needed: false };
      }
      return Response.json({
        jsonrpc: "2.0",
        id: body.id,
        result: {
          task: { state: "completed" },
          parts: [{ kind: "data", data: result }],
        },
      });
    }
    return new Response("mock " + name, { status: 200 });
  };
}

export default defineConfig(async () => ({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.test.toml" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations("migrations"),
          BRAIN_API_KEY: "test-brain-key",
          A2A_SHARED_KEY: "test-shared-key",
        },
        serviceBindings: {
          GUARDIAN: mockSpecialist("guardian"),
          DEVOPS: mockSpecialist("devops"),
          DATA: mockSpecialist("data"),
          MARKETING: mockSpecialist("marketing"),
          CREATIVE: mockSpecialist("creative"),
        },
        async outboundService(request: Request) {
          const url = new URL(request.url);
          return new Response("outbound blocked in tests: " + url.hostname, {
            status: 502,
          });
        },
      },
    }),
  ],
  test: {
    setupFiles: ["./test/apply-migrations.ts"],
  },
}));
