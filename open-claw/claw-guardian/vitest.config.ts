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
          TG_BOT_TOKEN: "test-tg-token",
          TG_CHAT_ID: "-100999",
          GUARDIAN_APPROVER_UID: "U_test_approver",
          GUARDIAN_REQUIRE_UID: "1", // เทสต์ strict path (prod default = ปิด)
          JARVIS_FORWARD_URL: "https://n8n.test/webhook/jarvis-cmd",
        },
        // ดัก outbound ทั้งหมดให้เทสต์ hermetic:
        // - Telegram push → 200 ปกติ, ถ้า body มี __fail_push__ → 500 (จำลอง fail-closed)
        // - host อื่น → 502 กันเทสต์แอบยิงเน็ตจริง
        async outboundService(request: Request) {
          const url = new URL(request.url);
          if (url.hostname === "api.telegram.org") {
            const body = await request.text();
            return body.includes("__fail_push__")
              ? new Response("mock telegram error", { status: 500 })
              : Response.json({ ok: true });
          }
          if (url.hostname === "n8n.test") {
            return Response.json({ ok: true });
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
