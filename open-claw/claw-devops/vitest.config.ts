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
        // ดัก outbound ให้เทสต์ hermetic: *.workers.dev ตอบ health ok, host อื่น 502
        async outboundService(request: Request) {
          const url = new URL(request.url);
          if (url.hostname.endsWith(".workers.dev")) {
            return Response.json({ ok: true, mock: true });
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
