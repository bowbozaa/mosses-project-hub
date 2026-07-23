import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => ({
  plugins: [
    cloudflareTest({
      // ใช้ wrangler.test.toml — ไม่มี [ai] binding (เทสต์ห้ามยิง Workers AI จริง)
      wrangler: { configPath: "./wrangler.test.toml" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations("migrations"),
          A2A_SHARED_KEY: "test-shared-key",
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
