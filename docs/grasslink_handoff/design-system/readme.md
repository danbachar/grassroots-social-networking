# grasslink Design System

> **grasslink** is a grassroots communication platform that lives from the collective engagement of its peers. Peers help each other relay messages and connect to the internet — a people-powered mesh, with no towers and no gatekeepers.

This design system encodes grasslink's warm, earthy, humane brand into tokens, components, and full-screen UI kits that design agents and engineers can build against.

## Sources
This system was authored **from a written brand brief** — no codebase, Figma file, or asset library was supplied. Company description and art-direction notes provided by the user:

> "We are the grasslink: a grassroots communication platform that lives from its collective engagement of peers; peers help each other relay messages and connect to the Internet. We use a warm, earthy color palette with rounded corners. Natural humane themes are great."

Because there were no source assets, **all visual decisions below (fonts, exact colors, the logo, component inventory) are original proposals** for the user to react to and refine — see CAVEATS at the end.

---

## Content fundamentals

**Voice.** Warm, plain-spoken, and collective. grasslink talks like a helpful neighbour, never like network infrastructure. Human outcomes over mechanics.

- **Person.** We say **"you"** (the person) and **"we / your neighbours / peers"** (the collective). The network is *"the mesh,"* never *"the system."*
- **Casing.** The brand name **grasslink** is always lowercase, even at the start of a sentence. UI headings use sentence case, not Title Case. Short all-caps micro-labels (e.g. `RELAYING FOR`, `SEND TO`) are used sparingly for eyebrow labels.
- **Tone.** Encouraging and grounded. Verbs are physical and human: *carry, relay, lend, pass along, hop, reach.* Avoid telecom jargon (packet, throughput, transmission, node — except in genuinely technical/mono contexts like `node · willow-7f3a`).
- **Emoji.** Used *rarely* and only organically inside peer messages (a single 🌿 sprig is the signature). Never in UI chrome, headings, or buttons.
- **Length.** Headlines are short and evocative ("The internet, passed hand to hand.", "A message never travels alone."). Body copy is one or two calm sentences.

**Examples**

| We say | Not |
| --- | --- |
| "Your message is on its way — three neighbours are carrying it now." | "Packet successfully enqueued for multi-hop transmission." |
| "Lend your link. Someone nearby is offline." | "Enable relay mode to maximise network throughput." |
| "No towers. Just neighbours." | "Infrastructure-free connectivity solution." |

---

## Visual foundations

**Palette.** Warm and earthy, built on three families plus semantics (`tokens/colors.css`):
- **Moss** (primary, `#6B7B37`) — grass, growth, connection. The dominant brand color; used full-bleed on hero/onboarding surfaces.
- **Terracotta** (accent, `#BE5A2C`) — human warmth and signal; secondary buttons, the "signal dot" in the wordmark, CTA panels.
- **Clay** (warm neutrals, `#FBF6EE` → `#241C15`) — the earth everything sits on. Page background is warm cream (`--clay-50`), never pure white; text is warm dark clay, never pure black.
- **Semantics** — success (moss), warning (amber `#D08E1E`), danger (warm rust `#B8402D`), info (muted teal `#3F7C74`). Each has a soft companion tint.
- **Rule of thumb:** at most 1–2 saturated background colors per screen; let moss and clay do the heavy lifting, terracotta as a spark.

**Typography** (`tokens/typography.css`):
- **Display — Bricolage Grotesque** (700–800, tight tracking −0.02/−0.03em): headlines, wordmark, big numbers. Characterful and contemporary, with a warm, slightly quirky humanist feel that suits grassroots.
- **Text — Hanken Grotesk** (400/500/600): all UI and reading text. Friendly humanist grotesque, highly legible at small sizes.
- **Mono — JetBrains Mono**: relay keys, hop counts, node IDs, code.

**Shape & corners.** Generously **rounded, organic corners** everywhere (`tokens/radius.css`): inputs/buttons 10–20px, cards 20px, sheets/modals 28–36px, pills fully round, phone frame 44px. Nothing is sharp-cornered.

**Backgrounds.** Flat warm color fields — cream `--clay-50` for pages, `--clay-100` for sunken bands, solid moss/terracotta for feature panels. **No gradients, no photographic hero washes, no noise/texture.** The recurring decorative motif is the **terracotta "signal dot"** (a filled circle with a soft concentric halo) — grasslink's minimal brand mark.

**Elevation.** Soft, **warm-tinted shadows** (`rgba(58,46,36,…)`, never pure black) in five steps (`tokens/shadows.css`). Cards use `sm`; interactive/raised surfaces `md`; modals `xl`. Combined with 1px `--border-subtle` hairlines.

**Cards.** White (`--surface-card`) on cream page, `--radius-lg` (20px), 1px subtle border + soft `sm` shadow. Interactive cards lift `translateY(-2px)` and deepen to `md` shadow on hover.

**Borders.** Hairline `--border-subtle`/`--border-default` (warm clay tints). Inputs use a 1.5px border that turns moss on focus with a terracotta focus ring (`--shadow-focus`).

**Motion** (`tokens/motion.css`). Gentle and organic. Default `--ease-out` for most transitions (120–200ms); a subtle **spring** (`--ease-spring`, slight overshoot) for tactile toggles (Switch knob, Radio dot) and modal entrances. Buttons **press-shrink** (scale 0.97; icon buttons 0.92) rather than changing color dramatically. Hover states = a step up in surface tint (e.g. transparent → `--clay-100`) or the next-darker brand step. No bounces on scroll, no flashy entrances.

**Transparency & blur.** Reserved: sticky nav uses `backdrop-filter: blur` over a translucent cream; the modal scrim is translucent warm clay (`rgba(36,28,21,.45)`) with a light 3px blur.

**Imagery.** None supplied. The brand leans on typography, flat color, and the signal-dot motif rather than photography. When photos are needed, prefer warm, natural, documentary imagery of people/community (not stock-slick).

---

## Iconography

- **System: [Lucide](https://lucide.dev)** — loaded from CDN (`https://unpkg.com/lucide@0.544.0`). Its rounded caps/joins and even humanist stroke match grasslink's warmth. **This is a substitution** — no icon set was supplied — flagged for the user in CAVEATS.
- **Usage.** Line icons at 2px stroke, `currentColor`, sized 14–26px. Common glyphs: `route`, `radio-tower`, `git-branch`/`git-fork` (hops), `sprout`, `users-round`, `at-sign`, `hash`, `send`, `arrow-up`.
- **Signature meter, not an icon.** Peer-link quality is shown with the custom **SignalMeter** component (growing bars, colored red→amber→moss), not a glyph — it's the brand's defining metaphor.
- **Emoji.** Only the organic 🌿 sprig inside peer message content; never as UI icons.
- **No unicode-as-icons** except the select chevron (▾).

---

## Components

Reusable React primitives under `components/<group>/`. Each is `<Name>.jsx` + `<Name>.d.ts` + `<Name>.prompt.md`, with one `@dsCard` demo per group. Consume via `const { Name } = window.GrasslinkDesignSystem_<hash>` after loading `_ds_bundle.js`.

- **forms/** — `Button`, `IconButton`, `Input`, `Textarea`, `Select`, `Checkbox`, `Radio`, `Switch`
- **display/** — `Card`, `Avatar`, `Badge`, `Tag`
- **feedback/** — `ProgressBar`, `Toast`, `SignalMeter`
- **navigation/** — `Tabs`
- **overlay/** — `Dialog`, `Tooltip`

**Intentional additions** (not from a source inventory — this was a from-scratch brief):
- **SignalMeter** — grasslink's core connectivity metaphor (peer mesh strength). Justified as the brand's signature primitive; every product surface uses it.
- **Avatar** with a `relaying` presence state (alongside online/offline) — specific to a relay network.

---

## UI kits

Full-screen, interactive recreations under `ui_kits/`, composed from the components above:
- **grasslink-app/** — mobile mesh-messaging app. Screens: Login, Threads, Conversation, Mesh status, Compose. `index.html` is an interactive click-through inside a phone frame.
- **grasslink-site/** — marketing landing page. Sections: Nav, Hero (with live mesh-card), How it works, Stats, CTA, Footer.

---

## File index

- `styles.css` — root entry; `@import`s every token + font file. **Consumers link this one file.**
- `tokens/` — `fonts.css`, `colors.css`, `typography.css`, `spacing.css`, `radius.css`, `shadows.css`, `motion.css`
- `components/` — `forms/`, `display/`, `feedback/`, `navigation/`, `overlay/` (each with `.jsx` + `.d.ts` + `.prompt.md` + a `@dsCard` demo)
- `guidelines/` — foundation specimen cards (Colors, Type, Spacing, Brand)
- `ui_kits/` — `grasslink-app/`, `grasslink-site/`
- `thumbnail.html` — project homepage tile
- `SKILL.md` — Agent-Skills-compatible entry point
- *Generated (do not edit):* `_ds_bundle.js`, `_ds_manifest.json`, `_adherence.oxlintrc.json`

---

## CAVEATS — please help me get this right

Everything here is an **original proposal from a one-paragraph brief.** Before relying on it, please confirm or correct:

1. **Logo / brand mark.** No logo was supplied, so I did **not** invent one — the wordmark is simply "grasslink" set in Bricolage Grotesque (lowercase) beside a terracotta "signal dot." **If you have a real logo, share it** and I'll wire it into the wordmark, thumbnail, nav, and onboarding.
2. **Fonts are proposals, loaded from Google Fonts** (Bricolage Grotesque, Hanken Grotesk, JetBrains Mono) — not supplied brand fonts, and not self-hosted (so the compiler currently indexes 0 local font files; they still render via Google's CSS). If you have brand fonts, send the files and I'll self-host them in `assets/fonts/` with local `@font-face`.
3. **Icons are Lucide (substitution).** Swap for your real icon set if you have one.
4. **Colors are a proposed palette** hitting "warm, earthy, rounded, humane." Happy to shift hues (e.g. more olive vs. grass, clay vs. sand neutrals).
5. **Component inventory is a sensible from-scratch set** plus SignalMeter. Tell me which real product surfaces exist and I'll align the kit.
