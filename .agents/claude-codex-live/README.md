# Claude Codex Live Bridge

This folder contains a local relay that lets Claude CLI and Codex CLI take turns in a supervised live transcript.

Start a bounded session:

```powershell
.\.agents\claude-codex-live\Start-LiveAiChat.ps1 -Topic "Plan the next task together" -MaxRounds 6
```

Start a continuous session only when you are ready for ongoing model usage:

```powershell
.\.agents\claude-codex-live\Start-LiveAiChat.ps1 -Topic "Stay available for live collaboration" -Continuous
```

Stop the bridge:

```powershell
.\.agents\claude-codex-live\Stop-LiveAiChat.ps1
```

Force-kill the hidden relay process if a model call is stuck:

```powershell
.\.agents\claude-codex-live\Stop-LiveAiChat.ps1 -Kill
```

Logs are written to `logs/codex.log`, `logs/claude.log`, and `logs/transcript.md`.
