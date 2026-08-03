# Multi-Agent Live Bus

This is a local supervised relay for more than two agents. It keeps a shared transcript, calls each registered agent in order, and writes one live log per agent.

Built-in agents:

- `codex` - local Codex CLI via `codex exec`
- `claude` - local Claude Code CLI via `claude -p`
- `claude-sessions` - read-only `claude agents --json --all`
- `friday-mesh-health` - public `/health` probe for FRIDAY Agent Mesh
- `friday-mesh-orchestrator` - authenticated `/agents/orchestrator/default` adapter, requires `MESH_API_KEY`
- `friday-mcp` - Claude-side FRIDAY MCP adapter with read-only/status guardrails

Start a bounded bus:

```powershell
.\.agents\multi-agent-live\Start-AgentBus.ps1 -AgentList "codex,claude,claude-sessions,friday-mesh-health" -MaxRounds 2
```

Start without opening separate PowerShell viewer windows:

```powershell
.\.agents\multi-agent-live\Start-AgentBus.ps1 -AgentList "codex,claude,claude-sessions,friday-mesh-health" -MaxRounds 2 -NoWindows
```

Cursor / VS Code:

Use `Terminal > Run Task...` and choose one of:

- `Agent Bus: Start Cursor Inbox`
- `Agent Bus: Start Headless`
- `Agent Bus: Start Headless Continuous`
- `Agent Bus: Tail Transcript`
- `Agent Bus: Tail Bus Log`
- `Agent Bus: Stop`

These tasks use Cursor's integrated terminal and do not open separate PowerShell viewer windows.

Cursor inbox mode:

```powershell
.\.agents\multi-agent-live\Start-CursorAgentBus.ps1 -OpenCursor
```

This opens `inbox.md` and `logs/cursor-transcript.md` in Cursor. Type a task under `## Message` in `inbox.md` and save; the watcher calls the selected agents once per changed message, so it stays connected without burning tokens in an idle loop.

Start with FRIDAY MCP included:

```powershell
.\.agents\multi-agent-live\Start-AgentBus.ps1 -AgentList "codex,claude,friday-mcp,claude-sessions,friday-mesh-health" -MaxRounds 2
```

Start the authenticated FRIDAY Mesh orchestrator after setting `MESH_API_KEY`:

```powershell
$env:MESH_API_KEY = "<token>"
.\.agents\multi-agent-live\Start-AgentBus.ps1 -AgentList "codex,claude,friday-mesh-orchestrator" -MaxRounds 1
```

Continuous mode is intentionally explicit because it keeps spending model calls until stopped:

```powershell
.\.agents\multi-agent-live\Start-AgentBus.ps1 -AgentList "codex,claude,friday-mcp" -Continuous
```

Stop:

```powershell
.\.agents\multi-agent-live\Stop-AgentBus.ps1
```

Force-kill the hidden runner if a model call is stuck:

```powershell
.\.agents\multi-agent-live\Stop-AgentBus.ps1 -Kill
```

Optional custom agents can be put in `agents.json` using the shape shown in `agents.sample.json`.

Logs:

- `logs/transcript.md`
- `logs/bus.log`
- `logs/agents/<agent>.log`
