import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      TEST_MIGRATIONS: D1Migration[];
      AGENT_NAME: string;
      AGENT_SKILL_ID: string;
      A2A_SHARED_KEY: string;
      BRAIN_API_URL: string;
    }
  }
}

export {};
