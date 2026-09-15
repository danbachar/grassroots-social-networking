# grasslink Design System — adaptation brief for Claude Code

You are adapting an **existing codebase** to the **grasslink Design System**. The full
source of that system is bundled here under `design-system/`. Your job is **not** to copy
these files verbatim — it is to re-express grasslink's visual language inside this project's
own framework, conventions, and component patterns.

## How to use this bundle

1. **Read first, in this order:**
   - `design-system/readme.md` — the complete brand + system guide (voice, palette, type,
     shape, motion, component inventory). This is the source of truth.
   - `design-system/SKILL.md` — the system's own agent entry point.
   - `design-system/tokens/*.css` — the exact token values (colors, typography, spacing,
     radius, shadows, motion). These are the numbers you port.
   - `design-system/components/**/*.prompt.md` — a one-paragraph spec + usage example per
     component. `.d.ts` files next to them give the exact prop APIs. `.jsx` files are the
     reference React implementations.
   - `design-system/ui_kits/` — full-screen reference compositions (a mobile app and a
     marketing site) showing how the pieces fit together.

2. **Port the tokens into this project's system.** Map `design-system/tokens/*.css` onto
   whatever this codebase already uses — Tailwind config, CSS variables, a theme object,
   SCSS vars, design-token JSON, etc. Preserve the *values and names* (moss / terracotta /
   clay families, the spacing/radius/shadow scales). Do not hardcode hex values in
   components; reference the tokens.

3. **Adapt components to existing patterns.** For each grasslink component, find or create
   the equivalent in this codebase and give it the same variants, sizes, states, and
   behavior described in its `.prompt.md` / `.d.ts`. Match this project's existing component
   conventions (file layout, styling approach, prop naming) rather than importing the
   reference `.jsx` as-is.

4. **Respect the non-negotiable brand rules** (all detailed in `readme.md`):
   - Page background is warm cream (`--clay-50`), never pure white. Text is warm dark clay,
     never pure black.
   - Generously rounded, organic corners everywhere. Nothing sharp.
   - Flat warm color fields — **no gradients, no photo washes, no noise/texture.**
   - Warm-tinted shadows (`rgba(58,46,36,…)`), never pure black.
   - At most 1–2 saturated background colors per screen; moss + clay carry it, terracotta is
     the spark. The terracotta "signal dot" is the recurring motif.
   - Fonts: Bricolage Grotesque (display), Hanken Grotesk (text), JetBrains Mono (mono).
   - Voice: warm, plain-spoken, collective. "grasslink" is always lowercase. Physical/human
     verbs (carry, relay, lend, hop). No telecom jargon in UI copy.
   - Motion: gentle `ease-out` 120–200ms; spring only on tactile toggles; buttons
     press-shrink (scale 0.97) rather than flashing color.

## Recommended workflow

1. Do a quick audit: what framework, styling system, and component library does this project
   already use? Write down where tokens and shared components live.
2. Land the tokens first (colors, type, spacing, radius, shadows, motion) and load the three
   font families. Verify a single page picks up the cream background + clay text.
3. Adapt shared primitives next (Button, Input, Card, etc.) using the specs in
   `design-system/components/`.
4. Then reskin screens one at a time, checking each against the brand rules above and the
   `ui_kits/` references.
5. Flag anything the brand guide leaves open (see CAVEATS at the end of `readme.md` — logo,
   final fonts, icon set) and ask the user rather than inventing.

## What NOT to do

- Don't ship the bundled `.jsx`/`.css` files directly if this project has its own stack —
  translate into it.
- Don't invent colors, type, spacing, or components not grounded in `readme.md`/`tokens/`.
- Don't introduce gradients, pure black/white, sharp corners, or telecom jargon.
