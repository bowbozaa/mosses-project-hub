import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      TEST_MIGRATIONS: D1Migration[];
      AGENT_NAME: string;
      AGENT_SKILL_ID: string;
      A2A_SHARED_KEY: string;
      TG_BOT_TOKEN: string;
      TG_CHAT_ID: string;
      GUARDIAN_APPROVER_UID: string;
    }
  }
}

export {};
