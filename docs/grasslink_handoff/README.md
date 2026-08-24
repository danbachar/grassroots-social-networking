# grasslink Design System — handoff bundle

This folder is a self-contained package for handing the **grasslink Design System** to
Claude Code (or any coding agent) so it can adapt an existing project to the system.

## Contents

- **`AGENTS.md`** — the brief for the coding agent. Start here. Tells the agent how to read
  the system and port it into your codebase's own framework and conventions.
- **`design-system/`** — the complete design-system source:
  - `readme.md` — full brand + system guide (source of truth)
  - `SKILL.md` — the system's agent entry point
  - `styles.css` — root stylesheet that imports every token file
  - `tokens/` — colors, typography, spacing, radius, shadows, motion (the exact values)
  - `components/` — per-component `.prompt.md` (spec), `.d.ts` (prop API), `.jsx` (reference impl)
  - `guidelines/` — visual specimen cards (colors, type, spacing, brand)
  - `ui_kits/` — full-screen reference compositions (mobile app + marketing site)

## How to use with Claude Code

1. Copy this whole `grasslink_handoff/` folder into your project's repo (e.g. at the root,
   or under `docs/`).
2. Open the repo in Claude Code and point it at `grasslink_handoff/AGENTS.md`, e.g.:

   > Read `grasslink_handoff/AGENTS.md` and adapt this project to the grasslink design
   > system. Start by auditing our current styling setup, then port the tokens, then reskin
   > components and screens one at a time.

3. Rename `AGENTS.md` to your agent's convention if needed (e.g. `CLAUDE.md`) — the content
   is the same brief either way. You can also drop the token values into your existing
   `CLAUDE.md`/`AGENTS.md` so every session picks them up automatically.

The bundled HTML/JSX/CSS are **design references**, not code to ship as-is. The task is to
re-express grasslink's visual language inside your project's existing environment.
