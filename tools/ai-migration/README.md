# AI Workstation Migration Toolkit

ชุดสคริปต์สำหรับย้ายสภาพแวดล้อมพัฒนา AI ออกจากโน้ตบุ๊ก **Bank-Hollenat** ไปยัง **friclawd** (Windows) และ **macbook-pro--bank** (Mac) ก่อนล้างเครื่อง

เป้าหมายไม่ใช่แค่ "copy ไฟล์เสร็จ" แต่คือ **ถ้าโน้ตบุ๊กหายไปทั้งเครื่อง ก็ยังสร้างสภาพแวดล้อมกลับมาได้จาก backup ที่ตรวจยืนยันแล้ว**

> ⚠️ **สถานะการทดสอบ:** สคริปต์ทุกตัวผ่านการตรวจ syntax, PSScriptAnalyzer, shellcheck และทดสอบการทำงานจริงบน Linux (pwsh 7 / bash) แล้ว
> แต่**ยังไม่เคยรันบน Windows หรือ macOS จริง** ให้เริ่มด้วย `-DryRun` / `-WhatIf` / `--dry-run` ก่อนเสมอ

## ข้อรับประกันความปลอดภัย (บังคับไว้ในโค้ด)

| กฎ | บังคับอย่างไร |
|---|---|
| ไม่ลบ / ไม่ย้าย / ไม่เขียนทับไฟล์ต้นทาง | ไม่มีคำสั่งลบไฟล์ต้นทางในสคริปต์ใดเลย |
| robocopy เป็นแบบ COPY เท่านั้น | `Assert-SafeRobocopyArgs` หยุดทำงานทันทีถ้ามี `/MIR` `/PURGE` `/MOV` `/MOVE` |
| rsync ไม่ลบไฟล์ปลายทาง | ไม่ใช้ `--delete` และใช้ `--ignore-existing` |
| ไม่เขียนทับข้อมูลปลายทาง | ถ้าโฟลเดอร์ปลายทางมีไฟล์อยู่แล้ว จะข้ามไป เว้นแต่สั่ง `-Resume` |
| Git อ่านอย่างเดียว | `--no-optional-locks` ไม่ fetch ไม่ checkout ไม่ reset |
| ไม่แสดงค่า secret | รายงานมีแค่**ชื่อ**ตัวแปรกับที่อยู่ไฟล์ ค่าที่ดูเหมือน token จะถูก mask |
| secret ไม่ปนกับ backup ปกติ | `.env` / key / credentials ถูกตัดออกจากการ copy แล้วแยกไปเก็บใน 7-Zip AES-256 |
| ไม่มีการ reset เครื่อง | ในชุดนี้ไม่มีสคริปต์ reset หรือ uninstall |

## โครงสร้าง

```
tools/ai-migration/
├── README.md
├── BRAIN-RESTORE.md               แม่แบบคู่มือ restore Flyday Brain
├── windows/
│   ├── MigrationCommon.psm1       helper กลาง + กฎความปลอดภัย
│   ├── 00-Start-MigrationSession.ps1   Phase 0
│   ├── 01-Discover-Machine.ps1         Phase 1, 21  (BitLocker, software manifest)
│   ├── 02-Discover-Projects.ps1        Phase 2-4, 7-9, 18  (projects, git, AI map, DB)
│   ├── 03-Discover-Config.ps1          Phase 5, 6, 10, 12-15  (Claude, MCP, secrets, SSH, editor, n8n)
│   ├── 04-Discover-Services.ps1        Phase 16, 17, 19  (Docker, WSL, Ollama)
│   ├── 05-Prepare-LocalBackups.ps1     git bundle, SQLite .backup, portable config, D1 export
│   ├── 06-Copy-ToDestination.ps1       Phase 22-25  (เช็กพื้นที่ + robocopy COPY)
│   ├── 07-New-HashManifest.ps1         Phase 26-27  (SHA256SUMS + BACKUP-MANIFEST)
│   ├── Test-Sha256Sums.ps1             ตรวจ hash ปลายทาง (ใช้ได้ทั้ง Windows และ macOS)
│   ├── 08-Backup-Secrets-Encrypted.ps1 Phase 11-12  (Mosses ต้องรันเอง)
│   ├── 09-Test-WindowsRestore.ps1      Phase 28  (รันบน friclawd)
│   ├── 10-New-FinalReport.ps1          Phase 41-43, 46  (Hard Gate)
│   ├── Run-All.ps1                     รัน 00→10 ในคำสั่งเดียว
│   ├── bootstrap-windows.ps1 / restore-projects-windows.ps1 / restore-config-windows.ps1 / verify-environment-windows.ps1
└── macos/
    ├── pull-backup-from-smb.sh         Phase 31  (backup ชุดที่ 2 + shasum -c)
    ├── scan-windows-dependencies.sh    Phase 32  → WINDOWS-TO-MAC-COMPATIBILITY.md
    ├── bootstrap-macos.sh / restore-projects-macos.sh / restore-config-macos.sh
    └── verify-environment-macos.sh     Phase 35  → MACOS-RESTORE-REPORT
```

## ก่อนเริ่ม (บนโน้ตบุ๊ก)

1. Clone repo นี้ลงโน้ตบุ๊ก แล้ว `git checkout` branch ที่มีชุดสคริปต์นี้
2. แนะนำให้ใช้ **PowerShell 7** (`winget install Microsoft.PowerShell`) เพราะรองรับ path ยาวเกิน 260 ตัวอักษร ส่วน PowerShell 5.1 ก็ใช้ได้เช่นกัน
3. รันแบบ **user ปกติ** ไม่ต้อง Run as Administrator
4. ถ้า Windows บล็อกไม่ให้รันสคริปต์: `Set-ExecutionPolicy -Scope Process Bypass` (มีผลเฉพาะหน้าต่าง PowerShell นั้น)
5. บน friclawd: เตรียม SMB share ไว้เป็นปลายทาง เช่น `\\100.127.194.73\Backup` แล้วเช็กพื้นที่ว่าง
6. เช็กว่าโปรเจกต์ไม่ได้อยู่ใน OneDrive แบบ Files On-Demand (ไฟล์ที่ยังไม่ได้ดาวน์โหลดลงเครื่องจะไม่ถูก copy)

## ทางลัด: รันครบในคำสั่งเดียว (`Run-All.ps1`)

รันเองในหน้าต่าง PowerShell ปกติบนโน้ตบุ๊ก (**ไม่ต้อง**เปิดแบบ Admin):

```powershell
cd <repo>\tools\ai-migration\windows
pwsh -File .\Run-All.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration' -DryRun   # ลองก่อน ยังไม่ copy อะไร
pwsh -File .\Run-All.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration'           # รันจริง
```

สคริปต์จะรัน 00 → 05 → 06 → 07 → 08 → 10 ต่อกันจนจบ และหยุดถามแค่ 2 จุด:

1. **ยืนยันรายการโฟลเดอร์ที่จะ copy** — ตอบ `y` เพื่อไปต่อ หรือ `n` เพื่อหยุด (ถ้าอยากแก้รายการ ให้แก้ `migration-sources.json` ก่อนตอบ)
2. **ตั้ง passphrase ให้ secret archive** — ต้องพิมพ์เอง แล้วจดใส่ password manager ทันที

ถ้าขั้นตอนสำคัญขั้นไหนล้มเหลว สคริปต์จะหยุดตรงนั้นทันที ขั้นที่เหลือไม่ถูกรัน ตอนจบจะแสดงตารางสรุป และบันทึก log ไว้ที่ `02_LOGS\run-all-*.log`

ตัวเลือกเพิ่มเติม: `-ExportBrainD1` (สำรอง D1 ของ Brain), `-Resume` (copy ต่อจากรอบที่แล้ว), `-SkipSecrets`, `-AutoApproveSources`

ส่วนที่ต้องทำบนเครื่องอื่น (friclawd, Mac) ยังต้องรันแยกตามตารางด้านล่าง

## ลำดับการรัน (ทีละขั้น)

| # | สคริปต์ | ใครรัน | รันที่เครื่อง |
|---|---|---|---|
| 1 | `00` → `01` → `02` → `03` → `04` | Claude Code หรือ Mosses | โน้ตบุ๊ก |
| 2 | **ตรวจ** `01_MANIFESTS\migration-sources.json` (แก้ `include`) และทุก path ที่ขึ้นว่า `NOT INSIDE A DETECTED PROJECT` | Claude เสนอ แล้ว **Mosses ยืนยัน** | โน้ตบุ๊ก |
| 3 | `05-Prepare-LocalBackups.ps1` (เพิ่ม `-ExportBrainD1` ได้ถ้า login wrangler แล้ว) | Claude / Mosses | โน้ตบุ๊ก |
| 4 | `06-Copy-ToDestination.ps1 -DestinationRoot ... -DryRun` แล้วค่อยรันจริงโดยไม่ใส่ `-DryRun` | Claude / Mosses | โน้ตบุ๊ก |
| 5 | `07-New-HashManifest.ps1 -VerifyDestination` | Claude / Mosses | โน้ตบุ๊ก |
| 6 | `08-Backup-Secrets-Encrypted.ps1 -DestinationRoot ...` | **Mosses เท่านั้น** (ต้องพิมพ์ passphrase เอง) | โน้ตบุ๊ก |
| 7 | `bootstrap-windows.ps1` → `09-Test-WindowsRestore.ps1 -BackupRoot ...` → `restore-*` → `verify-environment-windows.ps1` | Claude บน friclawd / Mosses | friclawd |
| 8 | เปิด Remote Login (ใช้ผ่าน Tailscale) หรือ mount SMB → `pull-backup-from-smb.sh` → `bootstrap-macos.sh` → `restore-*` → `verify-environment-macos.sh` | Mosses / Claude บน Mac | Mac |
| 9 | ทดสอบ Brain ตาม `BRAIN-RESTORE.md` | Claude / Mosses | friclawd หรือ Mac |
| 10 | เขียน `00_REPORTS\attestations.json` แล้วรัน `10-New-FinalReport.ps1 -FirstBackupRoot ...` | Claude / Mosses | โน้ตบุ๊ก |

ตัวอย่าง:

```powershell
cd <repo>\tools\ai-migration\windows
pwsh -File .\00-Start-MigrationSession.ps1
pwsh -File .\01-Discover-Machine.ps1
pwsh -File .\02-Discover-Projects.ps1
pwsh -File .\03-Discover-Config.ps1
pwsh -File .\04-Discover-Services.ps1
# ... ตรวจ migration-sources.json ...
pwsh -File .\05-Prepare-LocalBackups.ps1
pwsh -File .\06-Copy-ToDestination.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration' -DryRun
pwsh -File .\06-Copy-ToDestination.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration'
pwsh -File .\07-New-HashManifest.ps1 -VerifyDestination
pwsh -File .\08-Backup-Secrets-Encrypted.ps1 -DestinationRoot '\\100.127.194.73\Backup\Mosses-AI-Migration'   # Mosses รันเอง
```

ผลลัพธ์ทั้งหมดอยู่ที่ `%USERPROFILE%\AI-MIGRATION-WORK\` (โฟลเดอร์ `00_REPORTS`, `01_MANIFESTS`, `02_LOGS`, `04_RESTORE`, `05_CHECKSUMS`)

## หลักฐานจากเครื่องอื่น — `attestations.json`

สคริปต์บนโน้ตบุ๊กมองไม่เห็นผลที่เกิดบน Mac จึงต้องบันทึกหลักฐานไว้ในไฟล์นี้
**ทุกรายการต้องชี้ไปที่ไฟล์หลักฐานที่มีอยู่จริง** ถ้าไฟล์ไม่มี สคริปต์ 10 จะนับเป็น `UNVERIFIED`

`%USERPROFILE%\AI-MIGRATION-WORK\00_REPORTS\attestations.json`:

```json
[
  { "milestone": "SECOND_BACKUP_VERIFIED", "status": "PASS", "evidence": "C:\\Users\\Admin\\AI-MIGRATION-WORK\\evidence\\VERIFY-macbook-pro--bank-20260928.json", "note": "copied from Mac ~/Mosses-AI-Migration/18_REPORTS" },
  { "milestone": "MACOS_RESTORE_VERIFIED", "status": "PASS", "evidence": "C:\\Users\\Admin\\AI-MIGRATION-WORK\\evidence\\MACOS-RESTORE-REPORT-20260928.json", "note": "" },
  { "milestone": "BRAIN_RESTORE_VERIFIED", "status": "PASS", "evidence": "C:\\Users\\Admin\\AI-MIGRATION-WORK\\evidence\\brain-restore-test.txt", "note": "local D1 import + table counts" },
  { "milestone": "BITLOCKER_RECOVERY_CONFIRMED", "status": "PASS", "evidence": "C:\\Users\\Admin\\AI-MIGRATION-WORK\\evidence\\bitlocker-status.txt", "note": "manage-bde -status output; recovery key confirmed in Microsoft account (key NOT stored here)" },
  { "milestone": "CRITICAL_UNKNOWNS_RESOLVED", "status": "PASS", "evidence": "C:\\Users\\Admin\\AI-MIGRATION-WORK\\00_REPORTS\\AI-BRAIN-MAP.md", "note": "all UNKNOWN roles reviewed" }
]
```

ใส่ status เป็น `NOT_APPLICABLE` ได้เฉพาะกรณีที่เป็นแบบนั้นจริง เช่น ไม่ได้ใช้ BitLocker (ต้องมีผล `manage-bde -status` เป็นหลักฐาน)

## Hard Gate

`10-New-FinalReport.ps1` จะให้ผล `SAFE_TO_WIPE` ก็ต่อเมื่อ milestone **ทุกข้อ** เป็น PASS (หรือ NOT_APPLICABLE) และมีหลักฐานครบ จากนั้นจะแสดงข้อความ

```
Waiting for:
AUTHORIZE_FINAL_CLEANUP_AND_RESET
```

ชุดสคริปต์นี้**ไม่มีคำสั่ง reset เครื่อง** การ Reset this PC → Remove everything → Cloud download ต้องทำผ่านหน้า Settings → System → Recovery และ Mosses ต้องกดยืนยันเองหลังพิมพ์คำอนุญาตแล้วเท่านั้น

## Prompt สำหรับ Claude Code บนโน้ตบุ๊ก

```
You are F.R.I.D.A.Y. Use the toolkit in tools/ai-migration (read README.md first).
Run windows/00..04 in order, then summarize the findings in Thai and propose include/exclude changes to
01_MANIFESTS/migration-sources.json — wait for my confirmation before editing it.
Then run 05, 06 (-DryRun first), 07 -VerifyDestination. Do NOT run 08 — ask me to run it.
Never print secret values. Never delete, move, reset or uninstall anything.
Stop and report at the Hard Gate.
```

## ข้อจำกัดที่ควรรู้

- **ไม่ได้ backup ให้อัตโนมัติ:** ค่า secret ใน Windows Environment Variables, รหัสผ่านที่เซฟในเบราว์เซอร์, license ของโปรแกรม — ต้องเก็บเข้า password manager เอง
- **n8n:** ถ้า restore `database.sqlite` โดยไม่มี `encryptionKey` เดิม credential ทุกตัวใน n8n จะใช้ไม่ได้
- **Docker volume / WSL:** ไม่ได้ backup ถ้าไม่สั่ง `-BackupDockerVolumes` / `-ExportWslDistros` เอง ฐานข้อมูลที่รันอยู่ใน container ควรทำ logical dump แยก
- **SQLite:** ถ้าไม่มี `sqlite3` สคริปต์จะ copy ไฟล์ตรงๆ ซึ่งอาจได้ข้อมูลไม่ครบถ้าโปรแกรมกำลังเขียนไฟล์อยู่ ควรปิดโปรแกรมก่อน หรือติดตั้ง `winget install SQLite.SQLite`
- **Vectorize:** export ไม่ได้ ต้องสร้างใหม่จาก D1 (ดู `BRAIN-RESTORE.md`)
