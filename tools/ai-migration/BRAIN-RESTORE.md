# BRAIN RESTORE — Flyday Brain

> ไฟล์นี้เป็นแม่แบบ ให้เติมข้อมูลจากผลสแกนของ `02-Discover-Projects.ps1` เพราะการสแกนอย่างเดียวรู้ไม่ได้ทุกอย่าง

## แหล่งข้อมูลหลัก (ยืนยันจาก repo `flyday-brain-mcp`)

| ส่วนประกอบ | ที่เก็บข้อมูล | อยู่ที่ไหน | อยู่บนโน้ตบุ๊กไหม |
|---|---|---|---|
| ข้อมูล Brain (knowledge, decisions, errors, registry) | Cloudflare D1 `friclawd-db` | Cloudflare (remote) | ไม่อยู่ — อยู่ remote อย่างเดียว |
| ดัชนีค้นหาตามความหมาย | Cloudflare Vectorize `flyday-brain-vectors` | Cloudflare | ไม่อยู่ |
| Brain API | Worker `flyday-brain-api` | Cloudflare | มีแค่โค้ดใน repo |
| MCP proxy | Worker `flyday-brain-mcp` + KV `OAUTH_KV` | Cloudflare | มีแค่โค้ดใน repo |
| Brain / RAG / vector ที่เก็บในเครื่อง | ? | ดู `AI-BRAIN-MAP.md` กับ `DATABASE-INVENTORY.md` | **ยังไม่รู้ จนกว่าจะรันสแกน** |

ล้างโน้ตบุ๊กแล้ว Brain บน Cloudflare **ไม่หาย** ความเสี่ยงจริงมีสองอย่าง คือโค้ดที่ยังไม่ได้ push และ secret เช่น `BRAIN_API_KEY`, `MCP_AUTH_TOKEN`

## วิธี Backup

1. โค้ด: git audit (สคริปต์ 02) กับ bundle (สคริปต์ 05) ครอบคลุมทุก repo ของ Brain ที่มีงานค้างในเครื่อง
2. สำรอง D1 แบบ logical backup (อ่านอย่างเดียว ไม่แก้ข้อมูลบน Cloudflare):
   `pwsh -File windows\05-Prepare-LocalBackups.ps1 -ExportBrainD1` (ต้อง `wrangler login` ก่อน)
3. Vectorize: ไม่มีคำสั่ง export ทั้งก้อน ต้องสร้างใหม่จาก D1 ผ่านขั้นตอน embedding ของ Brain API — **ต้องเช็กให้แน่ใจว่าขั้นตอนนี้มีอยู่จริง** ก่อนจะให้ PASS
4. Secret (`BRAIN_API_KEY`, `MCP_AUTH_TOKEN`, Cloudflare API token): อยู่ใน Worker secrets บน Cloudflare และในไฟล์ `.dev.vars` ในเครื่อง → เข้า encrypted archive (สคริปต์ 08)
5. ถ้าสแกนเจอข้อมูล Brain/RAG ที่เก็บในเครื่อง → เพิ่มลง `migration-sources.json` แล้วตั้ง `include: true`

## ทดสอบ Restore (ไม่ทำลายข้อมูล และไม่แตะ production)

```bash
# รันบน friclawd หรือ Mac ใน repo flyday-brain-api ที่ restore แล้ว (หรือ wrangler project ใดก็ได้ที่ bind ชื่อ D1 นี้)
npx wrangler d1 execute friclawd-db --local --file <backup>/02_AI_BRAIN/d1-export/friclawd-db-<date>.sql
npx wrangler d1 execute friclawd-db --local --command "SELECT name FROM sqlite_master WHERE type='table';"
npx wrangler d1 execute friclawd-db --local --command "SELECT COUNT(*) FROM <ตารางหลัก>;"
```

`--local` คือรัน SQL กับสำเนา SQLite ในเครื่อง (อยู่ใน `.wrangler/`) จึงไม่แตะฐานข้อมูล D1 ตัวจริง

เช็กว่า Brain ตัวจริงยังใช้งานได้จากเครื่องใหม่: ใน Claude Code รัน `claude mcp list` → flyday-brain ต้องขึ้น connected แล้วลองเรียก `brain_summary`

## หลักฐานสำหรับ BRAIN_RESTORE_VERIFIED

บันทึกผลของคำสั่งข้างบนลงไฟล์ เช่น `brain-restore-test.txt` แล้วใส่ไว้ใน `attestations.json` (ดู README)
