import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => ({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations("migrations"),
          A2A_SHARED_KEY: "test-shared-key",
        },
        // ดัก outbound: Brain API ตอบ mock results, host อื่น 502
        async outboundService(request: Request) {
          const url = new URL(request.url);
          if (url.hostname === "flyday-brain-api.banknakorn39.workers.dev") {
            if (url.searchParams.get("q") === "__brain_down__") {
              return new Response("mock brain error", { status: 500 });
            }
            return Response.json({
              results: [{ title: "mock knowledge", score: 0.99 }],
            });
          }
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
