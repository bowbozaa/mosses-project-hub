# OAuth2 Auto-Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ลด OAuth2 token expiration failures จาก 53 ครั้ง (78% of total) เหลือ < 5 ต่อ quarter โดยย้าย 9 credentials ไป Service Account + สร้าง health probe สำหรับ 4+ credentials ที่ต้องเป็น OAuth2

**Architecture:** สร้าง Google Service Account 1 ตัวใน project เดิม ใช้ JSON key credential ใน n8n แทน OAuth2 สำหรับ Drive/Sheets/Docs/Calendar/BigQuery. สร้าง n8n workflow ใหม่ `🔐 OAuth2 Token Probe` ที่ทดสอบ YouTube/Gmail API ทุก 6 ชม. แจ้งเตือนผ่าน Telegram + LINE เมื่อพบ 401. Log ผลลง Brain API.

**Tech Stack:** Google Cloud Console, n8n Cloud, Flyday Brain API, Telegram Bot API, LINE Messaging API

## Global Constraints

- ห้ามลบ OAuth2 credentials เก่าจนกว่า Phase 6 (monitor 1 สัปดาห์ผ่าน)
- ทุก workflow ที่ migrate ต้องทดสอบก่อน + หลัง
- Brain API endpoint: `https://flyday-brain-api.banknakorn39.workers.dev`
- Telegram bot: @friclawd_friday_bot
- LINE token: ใช้ `$vars.FRICLAWD_LINE_TOKEN` ผ่าน Code node เท่านั้น
- Secret files เก็บที่ `~/.claude/secrets/` — ห้าม commit

---

### Task 1: สร้าง Google Service Account + JSON Key

**Files:**

- Create: `~/.claude/secrets/google-service-account.json` (local only, ห้าม commit)

**Interfaces:**

- Consumes: Google Cloud Console access (manual)
- Produces: Service Account email (`xxx@project.iam.gserviceaccount.com`) + JSON key file

> **Task นี้ต้องทำมือใน browser** — ขั้นตอนด้านล่างเป็น guide ทีละ step

- [ ] **Step 1: เปิด Google Cloud Console**

ไปที่ https://console.cloud.google.com → เลือก project ที่ n8n ใช้อยู่ (project เดียวกับ OAuth2 credentials เดิม)

- [ ] **Step 2: สร้าง Service Account**

IAM & Admin → Service Accounts → Create Service Account:

- Name: `n8n-automation`
- ID: `n8n-automation`
- Description: `Service account for n8n workflows (Drive, Sheets, Docs, Calendar, BigQuery)`
- กด Create and Continue

- [ ] **Step 3: ให้ Role**

ไม่ต้องให้ project-level role (ใช้ resource-level sharing แทน ยกเว้น BigQuery):

- ถ้าใช้ BigQuery → เพิ่ม role `BigQuery Data Editor`
- กด Continue → Done

- [ ] **Step 4: สร้าง JSON Key**

คลิก Service Account ที่สร้าง → Keys → Add Key → Create New Key → JSON → Download

- [ ] **Step 5: เก็บ key file อย่างปลอดภัย**

```bash
mkdir -p ~/.claude/secrets
# ย้ายไฟล์ที่ download มา:
mv ~/Downloads/project-xxxxx.json ~/.claude/secrets/google-service-account.json
# ตรวจสอบ:
cat ~/.claude/secrets/google-service-account.json | python -m json.tool | head -5
```

Expected output:

```json
{
    "type": "service_account",
    "project_id": "your-project-id",
    "private_key_id": "...",
    "private_key": "-----BEGIN PRIVATE KEY-----\n..."
```

- [ ] **Step 6: เปิด APIs ที่ต้องการ**

APIs & Services → Library → เปิดทีละตัว (ถ้ายังไม่ได้เปิด):

- Google Drive API
- Google Sheets API
- Google Docs API
- Google Calendar API
- BigQuery API

- [ ] **Step 7: จดบันทึก Service Account email**

```bash
cat ~/.claude/secrets/google-service-account.json | python -c "import sys,json; print(json.load(sys.stdin)['client_email'])"
```

จด email นี้ไว้ใช้ใน Task 2 (share resources)

---

### Task 2: Share Google Resources กับ Service Account

**Files:** ไม่มี (ทำใน Google UI)

**Interfaces:**

- Consumes: Service Account email จาก Task 1
- Produces: Service Account สามารถเข้าถึง Drive folders, Sheets, Docs, Calendar ที่ workflow ใช้

> **Task นี้ต้องทำมือใน browser**

- [ ] **Step 1: หา Drive folders/files ที่ workflow ใช้**

ไปที่ n8n → เปิด workflow ที่ใช้ Google Drive credential → ดู folder ID / file ID ในแต่ละ node

- [ ] **Step 2: Share Drive folders กับ SA email**

Google Drive → คลิกขวา folder → Share → ใส่ Service Account email → role: Editor → Send

- ทำซ้ำกับทุก folder/file ที่ workflow ใช้
- ถ้ามี root folder ที่เป็น parent → share folder เดียวก็พอ (inherit permissions)

- [ ] **Step 3: Share Google Sheets กับ SA email**

เปิด Google Sheet → Share → ใส่ SA email → role: Editor

- ทำซ้ำกับทุก sheet ที่ workflow ใช้

- [ ] **Step 4: Share Google Docs กับ SA email**

เปิด Google Doc → Share → ใส่ SA email → role: Editor

- ทำซ้ำกับทุก doc ที่ workflow ใช้

- [ ] **Step 5: Share Google Calendar กับ SA email**

Google Calendar → Settings → Calendar ที่ใช้ → Share with specific people → Add SA email → role: Make changes to events

- [ ] **Step 6: Verify BigQuery access (ถ้ามี)**

ถ้าใช้ BigQuery ตรวจสอบว่า IAM role จาก Task 1 Step 3 ครอบคลุม dataset ที่ใช้

---

### Task 3: สร้าง Service Account Credential ใน n8n + ทดสอบ

**Files:** ไม่มี (ทำใน n8n UI)

**Interfaces:**

- Consumes: JSON key file จาก Task 1, shared resources จาก Task 2
- Produces: n8n credential `Google SA — n8n-automation` พร้อมใช้งาน

- [ ] **Step 1: สร้าง credential ใน n8n**

n8n → Credentials → Add Credential → ค้นหา "Google Service Account API"

- Name: `Google SA — n8n-automation`
- Service Account Email: (จาก Task 1 Step 7)
- Private Key: copy จาก JSON key file (field `private_key` — รวม `-----BEGIN/END PRIVATE KEY-----`)
- Scopes: เว้นว่าง (ใช้ default — ครอบคลุม Drive/Sheets/Docs/Calendar)

- [ ] **Step 2: ทดสอบ credential**

กด Test → ต้องได้ "Connection tested successfully"
ถ้า fail → ตรวจสอบ:

- Private key copy ครบมั้ย (ต้องมี `\n` ครบ)
- Email ถูกต้องมั้ย
- API เปิดแล้วมั้ย (Task 1 Step 6)

- [ ] **Step 3: ทดสอบ Drive access จริง**

สร้าง workflow ชั่วคราว:

- Google Drive node → List Files → credential: `Google SA — n8n-automation`
- Folder ID: ใส่ folder ที่ share แล้ว
- Execute → ต้องเห็นไฟล์ใน folder

- [ ] **Step 4: ทดสอบ Sheets access จริง**

เพิ่ม node:

- Google Sheets node → Read Rows → credential: `Google SA — n8n-automation`
- Document ID: ใส่ sheet ที่ share แล้ว
- Execute → ต้องเห็นข้อมูล

- [ ] **Step 5: ลบ workflow ทดสอบ**

ลบ workflow ชั่วคราวที่สร้างใน Step 3-4

---

### Task 4: Migrate Workflows จาก OAuth2 → Service Account

**Files:** ไม่มี (ทำใน n8n UI)

**Interfaces:**

- Consumes: credential `Google SA — n8n-automation` จาก Task 3
- Produces: Workflows ทั้งหมดที่ใช้ Google Drive/Sheets/Docs/Calendar/BigQuery เปลี่ยนไปใช้ SA credential

- [ ] **Step 1: List workflows ที่ใช้ OAuth2 credentials เดิม**

ค้นหาใน n8n ว่า credential แต่ละตัวผูกกับ workflow ไหน:

| Credential ID    | Credential Name         | ใช้ใน Workflow |
| ---------------- | ----------------------- | -------------- |
| 9Q86JgytBq5WREc2 | Google Drive account    | (หา)           |
| GMLeAfbm8mwe3Mtj | email bank888office     | (หา)           |
| QgAdAd9GCyeEBRnM | Google Sheets account 2 | (หา)           |
| UxqEAEIFJrhm4pI5 | Google Sheets account 3 | (หา)           |
| wCrfsPo73bjfnKfR | Google Sheets account 4 | (หา)           |
| USpewmd8SfqSqYK7 | Google Docs account     | (หา)           |
| p0oJUqbgFULuhNd7 | Google Docs account 2   | (หา)           |
| lmeMfL5zo2KvKQZO | Google Calendar account | (หา)           |
| z9nhriCxLAIjSF1w | Google BigQuery account | (หา)           |

ใช้ Health Monitor v4.6 หรือ n8n API เพื่อดู credential-workflow mapping

- [ ] **Step 2: Migrate ทีละ workflow (pattern เดียวกันทุกตัว)**

สำหรับแต่ละ workflow:

1. เปิด workflow ใน n8n editor
2. คลิก Google node → Credential → เปลี่ยนเป็น `Google SA — n8n-automation`
3. ทำซ้ำกับทุก Google node ใน workflow
4. กด Save
5. Execute workflow → ตรวจสอบว่าผ่าน
6. ถ้า fail → switch กลับ OAuth2 credential เดิม + debug

- [ ] **Step 3: บันทึก migration log**

หลัง migrate ครบ บันทึกลง Brain:

```
POST https://flyday-brain-api.banknakorn39.workers.dev/brain/decisions
Content-Type: application/json

{
  "decision": "Service Account Migration",
  "context": "Migrated N workflows from OAuth2 to Service Account credential. Credentials migrated: [list]. All workflows tested and passing.",
  "outcome": "success",
  "category": "infrastructure"
}
```

- [ ] **Step 4: Verify — รัน Health Monitor v4.6**

Trigger Health Monitor v4.6 manually → ตรวจสอบว่าไม่มี credential warnings ใหม่

---

### Task 5: สร้าง OAuth2 Token Probe Workflow

**Files:** ไม่มี (สร้างใน n8n UI ด้วย SDK หรือ manual)

**Interfaces:**

- Consumes: OAuth2 credentials ที่เหลือ (YouTube × 2, Gmail × 2, Google generic × 3)
- Produces: Workflow `🔐 OAuth2 Token Probe` ที่เช็คทุก 6 ชม. + แจ้งเตือน + log Brain

- [ ] **Step 1: สร้าง workflow ใหม่ใน n8n**

ชื่อ: `🔐 OAuth2 Token Probe`
Description: `Every 6h probes YouTube/Gmail/Google OAuth2 tokens with lightweight API calls. Alerts via Telegram+LINE on 401. Logs to Brain.`

- [ ] **Step 2: เพิ่ม Schedule Trigger**

- Trigger every 6 hours (0:00, 6:00, 12:00, 18:00)
- Timezone: Asia/Bangkok

- [ ] **Step 3: เพิ่ม YouTube probe nodes**

Node: HTTP Request

- URL: `https://www.googleapis.com/youtube/v3/channels?part=id&mine=true&maxResults=1`
- Authentication: Predefined Credential Type → YouTube OAuth2 API
- Credential: `SRIWICHAI. FILM STUDIO`
- Settings: On Error → Continue (ไม่ให้ workflow หยุด)
- Timeout: 10000ms

ทำซ้ำอีก node สำหรับ credential `YouTube account 3`

- [ ] **Step 4: เพิ่ม Gmail probe nodes**

Node: HTTP Request

- URL: `https://gmail.googleapis.com/gmail/v1/users/me/profile`
- Authentication: Predefined Credential Type → Gmail OAuth2
- Credential: `Gmail account`
- Settings: On Error → Continue
- Timeout: 10000ms

ทำซ้ำอีก node สำหรับ credential `Gmail account 2`

- [ ] **Step 5: เพิ่ม Google generic probe nodes (ถ้ายังใช้อยู่)**

Node: HTTP Request

- URL: `https://www.googleapis.com/oauth2/v1/userinfo`
- Authentication: Predefined Credential Type → Google OAuth2
- Credential: `Google account` / `Google account 2` / `Google account 3`
- Settings: On Error → Continue
- Timeout: 10000ms

- [ ] **Step 6: เพิ่ม Aggregate + IF node**

Node: Code

```javascript
const probeResults = $input.all();
const failures = [];
const successes = [];

for (const item of probeResults) {
  const status = item.json.statusCode || item.json.$response?.statusCode || 200;
  const name = item.json.$credential?.name || "unknown";

  if (status === 401 || status === 403) {
    failures.push({ name, status });
  } else {
    successes.push({ name, status });
  }
}

return [
  {
    json: {
      timestamp: new Date().toISOString(),
      total: probeResults.length,
      healthy: successes.length,
      failed: failures.length,
      failures,
      successes,
      allHealthy: failures.length === 0,
    },
  },
];
```

IF node: `{{ $json.allHealthy }}` === false → alert branch

- [ ] **Step 7: เพิ่ม Alert branch (เมื่อมี failure)**

**Telegram node:**

- Bot: @friclawd_friday_bot
- Chat ID: (ใส่ chat ID ของพี่ Mosses)
- Message:

```
⚠️ OAuth2 Token Alert

พบ credential หมดอายุ:
{{ $json.failures.map(f => `• ${f.name} → ${f.status}`).join('\n') }}

👉 ไป re-auth ที่ n8n UI
Healthy: {{ $json.healthy }}/{{ $json.total }}
```

**LINE node (Code node):**

```javascript
const token = $vars.FRICLAWD_LINE_TOKEN;
const message = `⚠️ OAuth2 Alert: ${$json.failed} credential(s) expired. Check n8n.`;

await this.helpers.httpRequest({
  method: "POST",
  url: "https://api.line.me/v2/bot/message/push",
  headers: {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
  },
  body: {
    to: "USER_ID",
    messages: [{ type: "text", text: message }],
  },
});

return $input.all();
```

- [ ] **Step 8: เพิ่ม Brain logging (ทั้ง success + failure)**

Node: HTTP Request

- Method: POST
- URL: `https://flyday-brain-api.banknakorn39.workers.dev/brain/decisions`
- Body (JSON):

```json
{
  "decision": "OAuth2 Probe",
  "context": "Probed {{ $json.total }} credentials. Healthy: {{ $json.healthy }}, Failed: {{ $json.failed }}. Failures: {{ $json.failures.map(f => f.name).join(', ') || 'none' }}",
  "outcome": "{{ $json.allHealthy ? 'success' : 'alert_sent' }}",
  "category": "monitoring"
}
```

- [ ] **Step 9: ทดสอบ workflow**

1. Execute manually → ตรวจสอบว่าทุก probe ได้ 200
2. ตรวจสอบว่า Brain log ถูกสร้าง
3. ตรวจสอบว่า alert branch ไม่ trigger (เพราะ token ยังดีอยู่)

- [ ] **Step 10: Activate workflow**

Toggle workflow เป็น Active
ตรวจสอบว่า Schedule Trigger แสดง next run time ถูกต้อง

- [ ] **Step 11: Commit + log ลง Brain**

```
POST https://flyday-brain-api.banknakorn39.workers.dev/brain/decisions
{
  "decision": "Feature Launch",
  "context": "Deployed OAuth2 Token Probe workflow. Probes YouTube (2), Gmail (2), Google generic (3) every 6h. Alerts via Telegram + LINE. Logs to Brain.",
  "outcome": "success",
  "category": "monitoring"
}
```

---

### Task 6: Monitor + Cleanup (1 สัปดาห์หลัง)

**Files:** ไม่มี

**Interfaces:**

- Consumes: ผลจาก Task 4 (migrated workflows) + Task 5 (probe running)
- Produces: Confirmed stable state, old OAuth2 credentials cleaned up

- [ ] **Step 1: ตรวจสอบ Brain logs ทุกวัน**

```
GET https://flyday-brain-api.banknakorn39.workers.dev/brain/decisions?search=OAuth2+Probe
```

ตรวจสอบว่า:

- Probe ทำงานทุก 6 ชม.
- ไม่มี failures ใหม่
- Migrated workflows ทำงานปกติ

- [ ] **Step 2: ตรวจสอบ Health Monitor v4.6**

ดู execution history ของ Health Monitor v4.6:

- ไม่มี credential warnings ใหม่
- ไม่มี workflow failures ที่เกี่ยวกับ Google services

- [ ] **Step 3: ถ้าผ่าน 1 สัปดาห์ไม่มีปัญหา → ลบ OAuth2 credentials เก่า**

ใน n8n → Credentials → ลบทีละตัว:

1. Google Drive account (9Q86JgytBq5WREc2)
2. email bank888office (GMLeAfbm8mwe3Mtj)
3. Google Sheets account 2 (QgAdAd9GCyeEBRnM)
4. Google Sheets account 3 (UxqEAEIFJrhm4pI5)
5. Google Sheets account 4 (wCrfsPo73bjfnKfR)
6. Google Docs account (USpewmd8SfqSqYK7)
7. Google Docs account 2 (p0oJUqbgFULuhNd7)
8. Google Calendar account (lmeMfL5zo2KvKQZO)
9. Google BigQuery account (z9nhriCxLAIjSF1w)

⚠️ ลบเฉพาะ credentials ที่ไม่มี workflow ใช้อยู่แล้วเท่านั้น — ตรวจสอบก่อนลบทุกตัว

- [ ] **Step 4: Log completion ลง Brain**

```
POST https://flyday-brain-api.banknakorn39.workers.dev/brain/decisions
{
  "decision": "OAuth2 Migration Complete",
  "context": "Completed Service Account migration. 9 OAuth2 credentials retired. OAuth2 Token Probe active for remaining 4-7 credentials. Monitoring stable for 1 week.",
  "outcome": "success",
  "category": "infrastructure"
}
```

- [ ] **Step 5: Update Brain error_patterns**

```
PUT https://flyday-brain-api.banknakorn39.workers.dev/brain/errors/1
{
  "resolution": "Migrated 9 Google credentials to Service Account (no expiry). Remaining OAuth2 (YouTube/Gmail) monitored by Token Probe every 6h with Telegram+LINE alerts. Pre-emptive 7-day refresh still recommended for remaining OAuth2 tokens.",
  "status": "mitigated"
}
```
