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
          // ค่า test-only — secret จริงตั้งผ่าน wrangler secret put เท่านั้น
          A2A_SHARED_KEY: "test-shared-key",
          FRICLAWD_LINE_TOKEN: "test-line-token",
          GUARDIAN_APPROVER_UID: "U_test_approver",
        },
        // ดัก outbound ทั้งหมดให้เทสต์ hermetic:
        // - LINE push → 200 ปกติ, ถ้า body มี __LINE_FAIL__ → 500 (จำลอง fail-closed)
        // - host อื่น → 502 กันเทสต์แอบยิงเน็ตจริง
        async outboundService(request: Request) {
          const url = new URL(request.url);
          if (url.hostname === "api.line.me") {
            const body = await request.text();
            return body.includes("__LINE_FAIL__")
              ? new Response("mock line error", { status: 500 })
              : Response.json({});
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
