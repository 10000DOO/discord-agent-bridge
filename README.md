# discord-agent-bridge

Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, and more — per channel. Role-based access, multi-server, extensible.

현재 지원: Claude Code, Codex / 확장: 모드 플러그인 추가로 다른 에이전트(예: opencode) 연결 가능

- **Per-channel mode**: a channel is bound to exactly one backend (Claude or Codex) at a time.
- **Role-tiered auth**: admin / execute / read-only tiers, resolved global → server → project.
- **Multi-server**: one bot token drives many guilds; per-server and per-project overrides.
- **Capability-driven UX**: Discord renderers show only what the active mode supports.

## Status

**Scaffolding / Phase 1 pending.** This repository currently contains the project skeleton and stub files only — no feature logic is implemented yet.

## Design

See [`docs/DESIGN.md`](docs/DESIGN.md) for the full design document (architecture, contracts, auth model, config/state model, lifecycle, and extensibility).
