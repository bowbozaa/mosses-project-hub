# OAuth2 Auto-Refresh — Hybrid Approach (Service Account + Health Probe)

**Date:** 2026-07-11
**Status:** Approved
**Approach:** C (Hybrid)

## Problem

OAuth2 token expiration เป็นสาเหตุ ~78% ของ workflow failures ทั้งหมด (53 ครั้ง)
ระบบปัจจุบันเป็น reactive — รอจน workflow พังแล้วค่อย re-auth มือ

## Solution Overview

1. **Service Account Migration** — ย้าย Google Drive/Sheets/Docs/Calendar/BigQuery credentials (9 ตัว) ไปใช้ Service Account ที่ไม่มี token expiration
2. **OAuth2 Health Probe** — สร้าง n8n workflow เช็ค YouTube/Gmail credentials ทุก 6 ชม. แจ้งเตือนทันทีเมื่อพบ token หมดอายุ
3. **Brain Logging** — บันทึกผลทุกรอบลง Brain decision_log + error_patterns

---

## Part 1: Service Account Migration

### 1.1 สร้าง Google Service Account

- สร้างใน Google Cloud Console (project เดิม)
- เปิด API: Drive, Sheets, Docs, Calendar, BigQuery
- ดาวน์โหลด JSON key file

### 1.2 Share resources กับ Service Account email

- Google Drive folders → share กับ `xxxxx@project.iam.gserviceaccount.com`
- Google Calendar → เพิ่มเป็น editor
- BigQuery → IAM role `bigquery.dataViewer` / `dataEditor`

### 1.3 สร้าง credentials ใน n8n

- เพิ่ม "Google Service Account" credential
- ใส่ JSON key
- credential เดียว cover ได้หลาย service

### 1.4 Credentials ที่จะ migrate (9 ตัว)

| #   | Credential              | ID               | Type                    |
| --- | ----------------------- | ---------------- | ----------------------- |
| 1   | Google Drive account    | 9Q86JgytBq5WREc2 | googleDriveOAuth2Api    |
| 2   | email bank888office     | GMLeAfbm8mwe3Mtj | googleDriveOAuth2Api    |
| 3   | Google Sheets account 2 | QgAdAd9GCyeEBRnM | googleSheetsOAuth2Api   |
| 4   | Google Sheets account 3 | UxqEAEIFJrhm4pI5 | googleSheetsOAuth2Api   |
| 5   | Google Sheets account 4 | wCrfsPo73bjfnKfR | googleSheetsOAuth2Api   |
| 6   | Google Docs account     | USpewmd8SfqSqYK7 | googleDocsOAuth2Api     |
| 7   | Google Docs account 2   | p0oJUqbgFULuhNd7 | googleDocsOAuth2Api     |
| 8   | Google Calendar account | lmeMfL5zo2KvKQZO | googleCalendarOAuth2Api |
| 9   | Google BigQuery account | z9nhriCxLAIjSF1w | googleBigQueryOAuth2Api |

### 1.5 Credentials ที่คงเป็น OAuth2

| #   | Credential             | ID                                                     | Type             | เหตุผล                    |
| --- | ---------------------- | ------------------------------------------------------ | ---------------- | ------------------------- |
| 1   | SRIWICHAI. FILM STUDIO | 5MQ4bBZ3vA0bkLjz                                       | youTubeOAuth2Api | YouTube ต้อง user consent |
| 2   | YouTube account 3      | MXwrlUsL8q3LQlwo                                       | youTubeOAuth2Api | เช่นกัน                   |
| 3   | Gmail account          | xh1B0vFC0zjbQzap                                       | gmailOAuth2      | Gmail send ต้อง OAuth2    |
| 4   | Gmail account 2        | OUhkgbinCKSGYS3k                                       | gmailOAuth2      | เช่นกัน                   |
| 5   | Google account / 2 / 3 | z32uJls0K9jBuirn / R6I0Ajabc1NYgsoR / ffV4Qiu54vu036y2 | googleOAuth2Api  | ต้องเช็คการใช้งานจริง     |

---

## Part 2: OAuth2 Health Probe Workflow

### 2.1 Workflow: `🔐 OAuth2 Token Probe`

```
Schedule Trigger (ทุก 6 ชม.)
    │
    ├─→ Probe YouTube API (channels.list?mine=true&maxResults=1)
    │     ├─ credential: SRIWICHAI. FILM STUDIO
    │     └─ credential: YouTube account 3
    │
    ├─→ Probe Gmail API (users.me.getProfile)
    │     ├─ credential: Gmail account
    │     └─ credential: Gmail account 2
    │
    ├─→ Probe Google generic (ถ้ายังใช้อยู่)
    │     ├─ credential: Google account
    │     ├─ credential: Google account 2
    │     └─ credential: Google account 3
    │
    └─→ Aggregate results
          │
          ├─ ทุกตัว 200 → log "all healthy" ลง Brain
          │
          └─ มีตัวที่ 401 →
                ├─ แจ้ง Telegram (@friclawd_friday_bot)
                ├─ แจ้ง LINE (FRICLAWD_LINE_TOKEN)
                ├─ log ลง Brain error_patterns
                └─ update error count
```

### 2.2 Probe Logic

- HTTP Request node + credential
- Lightweight endpoint (ไม่กิน quota)
- Timeout 10s
- Response ≠ 200 → token มีปัญหา

### 2.3 Integration กับ Health Monitor v4.6

- v4.6: usage-based (credential ผูก workflow + execution สำเร็จ)
- Probe: direct API call → จับ token expiry แม่นกว่า
- ไม่ซ้ำซ้อนกัน

---

## Part 3: Brain Logging + Rollout

### 3.1 Brain Logging

| Event            | Table          | Data                                                   |
| ---------------- | -------------- | ------------------------------------------------------ |
| ทุกรอบ probe     | decision_log   | timestamp, credentials tested, results, response times |
| พบ token หมดอายุ | error_patterns | update ID:1 occurrence count + last_occurrence         |

### 3.2 Rollout Plan

| Phase | งาน                                            | Timeline     | Risk |
| ----- | ---------------------------------------------- | ------------ | ---- |
| 1     | สร้าง Google Service Account + JSON key        | วันแรก       | ต่ำ  |
| 2     | Share Drive folders/Sheets/Docs กับ SA email   | วันแรก       | ต่ำ  |
| 3     | สร้าง SA credential ใน n8n + ทดสอบ             | วันแรก       | ต่ำ  |
| 4     | Migrate workflows ทีละตัว                      | 1-2 วัน      | กลาง |
| 5     | สร้าง OAuth2 Token Probe workflow              | วันที่ 2-3   | ต่ำ  |
| 6     | Monitor 1 สัปดาห์ → ลบ OAuth2 credentials เก่า | สัปดาห์ถัดไป | ต่ำ  |

### 3.3 Rollback Plan

- OAuth2 credentials เก่าไม่ลบจนกว่า Phase 6 ผ่าน
- Switch กลับ OAuth2 ได้ทันทีใน n8n node
- Probe workflow เป็น read-only ไม่กระทบ production

### 3.4 Success Criteria

| Metric                       | ก่อน                      | เป้าหมาย                |
| ---------------------------- | ------------------------- | ----------------------- |
| OAuth2 credentials ที่เสี่ยง | 16 ตัว                    | 4 ตัว (YouTube + Gmail) |
| Token expiry failures        | 53 ครั้ง (78% of total)   | < 5 ต่อ quarter         |
| Mean time to detect          | ไม่รู้จนกว่า workflow พัง | < 6 ชม.                 |
| Mean time to fix             | ไม่แน่นอน                 | < 1 ชม. หลังได้ alert   |

### 3.5 Manual Steps (ทำอัตโนมัติไม่ได้)

1. สร้าง Service Account ใน Google Cloud Console
2. Share files/folders กับ SA email
3. Re-auth OAuth2 เมื่อ Probe แจ้ง (กด reconnect ใน n8n UI)
