# Owlet marketing landing page — design

**Date:** 2026-05-29
**Status:** Draft for review
**Topic:** A small marketing landing page for Owlet, built as a hands-on verification of the `taste-skill` agent skill (https://github.com/Leonxlnx/taste-skill).

## 1. Goal

Two goals, in priority order:

1. **Verify `taste-skill`.** Install the skill through its intended flow, build a real page with it, and judge whether it improves AI-generated UI. The deliverable includes a written verdict, not just a page.
2. **Ship a usable Owlet marketing landing page** as the artifact that proves it.

### What "verifying the skill" concretely means here

The user has **locked Owlet's existing design system** (palette, fonts, logo, component look — see §4). That decision *overrides most of what `taste-skill` would otherwise decide*: the `DESIGN_VARIANCE` palette rotation, the anti-default color discipline, and the font selection (the skill bans Fraunces as a default; we keep it).

So what is actually under test is the skill's **structural surface**, not its taste-on-a-blank-canvas:

- Layout-family variety (no family reused; ≥4 distinct across the page)
- Motion motivation + reduced-motion gating
- Hero-fits-viewport and copy-length constraints
- Em-dash ban and the §9 "AI tells" bans
- Section anti-repetition (zigzag cap, eyebrow restraint)
- Real images / real logos vs. fake div-screenshots

The implementation log (§9) must record **which skill rule drove which decision**, and the final verdict (§10) judges the skill on that structural surface. This keeps "done" meaning "the skill was verified," not merely "Claude built a nice page."

## 2. Scope

**In scope** — six sections, each a distinct layout family (validated visually during brainstorming):

| # | Section | Layout family | Content |
|---|---------|---------------|---------|
| 1 | Hero | Split | Headline + subtext + Download CTA (left); live rewriter-popup replica with diff on a sage stage (right) |
| 2 | How it works | 3-step row | Select text → Press ⌥Space → Replace or Copy |
| 3 | Private by default | Color band (inverted sage) | "No cloud. No API keys. The model runs on your Mac." |
| 4 | Works in every app | Logo grid | TextEdit, Slack, Notion, Chrome, VS Code, Mail; note the AX + clipboard fallback |
| 5 | Rewrite the way you mean | Showcase | Mode chips (Clarify, Add context, Structured, Compact) + before/after preview |
| 6 | Download + footer | Centered CTA | Requirements (macOS 14+, Ollama) + footer: GitHub, "Why Owlet?", privacy note |

**Out of scope:** real download artifact/hosting, analytics, forms/backend, i18n, blog, dark mode toggle (page ships in the light paper-cream theme only, matching the app's v0.4 light-only scheme). "Download" CTAs and the footer GitHub link point at the repo (`https://github.com/AKaLee-IK27/owlet`) as a placeholder destination until a real release artifact exists.

## 3. Tech stack & placement

- **Framework:** Next.js (App Router, RSC by default) — the skill's default stack, and itself part of what we're testing.
- **Styling:** Tailwind v4, with Owlet's tokens encoded as theme variables (§4).
- **Animation:** `motion/react` (Motion). Used sparingly per the skill's motivation rule.
- **Fonts:** `next/font/google` for Be Vietnam Pro and Fraunces. This satisfies the skill's "no Google Fonts `<link>` tags" rule while still using the brand fonts (we override the skill's Fraunces *ban*, not its font-*loading* mechanism).
- **Icons:** an icon library (Phosphor or Tabler), never hand-rolled SVG — per the skill.

**Placement & isolation (hard requirement):**

- Lives in a new top-level `landing/` directory — a **standalone sub-project**, independent of the Swift app and Rust CLI.
- **Not** wired into `./init.sh`. The existing verification suite (Rust `cargo test`, Swift `xcodebuild`) stays untouched, so CLAUDE.md's "`./init.sh` passes from a clean checkout" Definition-of-Done is unaffected.
- `landing/node_modules`, `landing/.next` added to `.gitignore`.
- This page is a marketing/verification artifact and is intentionally **not** tracked in `feature_list.json` (which scopes the macOS app's features).

**Working-tree hygiene:** the tree currently carries unrelated in-progress Swift work (`HotkeyEventTap.swift`, `ScreenshotCapturer.swift`, deleted `RegionSelectorOverlayView.swift`, new test files, `feature_list.json`, `progress.md`). Any commit from this work stages **only** the spec and `landing/` files — never the Swift WIP.

## 4. Design system (locked)

Source of truth: `Owlet/Owlet/OwletDesignSystem.swift`, `Theme.swift`, `ImprovePromptFloater.swift`. Encoded as Tailwind theme tokens.

**Palette**

| Token | Hex | Use |
|-------|-----|-----|
| paper-0 | `#FAF8F2` | canvas |
| paper-1 | `#F2EFE7` | card |
| paper-2 | `#E5E1D5` | sunken/hover |
| paper-3 | `#D2CDC0` | hairline |
| ink-0 | `#1F2A2A` | primary text |
| ink-1 | `#3E4848` | secondary text |
| ink-2 | `#6E7474` | tertiary text |
| sage-500 | `#5E9590` | **brand / primary accent** |
| sage-600 | `#437975` | press |
| sage-50 | `#EBF2EF` | brand soft |
| sage-800 | `#2E5754` | dark stage bg |
| coral-500 | `#ED7B68` | secondary accent (sparingly) |
| diff-added | `#1A8A3B` | diff additions |
| diff-removed | `#C44A37` | diff removals / danger |

Single accent discipline (skill rule): **sage** is the one accent. Coral is reserved for the logo, the diff "added" path's sibling, and tiny in-popup affordances — not a competing CTA color.

**Type:** Fraunces Italic = display + the rewrite output (kept, overriding the skill's ban). Be Vietnam Pro = all UI/body. SF Mono = the `⌥ Space` hint only.

**Radius:** 4 / 6 / 10 / 14 / 20 / pill — matching `OwletDesign.Radius`.

**Logo:** the user-provided PNG, used as a real image asset (`landing/public/owlet-logo.png`). **Never reconstructed as SVG** (a hand-traced SVG was rejected during brainstorming). App-icon PNGs from the asset catalog may seed the favicon.

**Popup replica:** the hero's product visual mirrors `ImprovePromptFloater` — 420px-ish card, 14px radius, hairline border, paper fill, header (logo + "Improve prompt" + `⌥ Space`), Fraunces-italic rewrite with green/coral diff, mode chips, Replace/Try again/Copy.

## 5. taste-skill install (verified mechanism)

`npx skills` CLI confirmed present. Verified behavior:

- `skills add <repo>` installs **project-level by default**, symlinking the chosen skill(s) into the detected agent dir (Claude Code → `.claude/skills/`) and writing `skills-lock.json`.
- Flags: `-g` global, `--copy` to copy instead of symlink, `-s <skill>` to pick specific skills, `-l/--list` to list without installing (used during brainstorming — wrote nothing to the repo).
- The repo exposes 13 skills; we install the core **`taste-skill`** ("Anti-Slop Frontend Skill"). Image-gen variants are out of scope.

Install step (run during implementation, not now):
```bash
cd /Users/rowlet/Repos/owlet
npx --yes skills@latest add https://github.com/Leonxlnx/taste-skill --skill taste-skill --yes
```
Then read the installed `SKILL.md`, gitignore any `node_modules`/symlink noise it introduces, and confirm `skills-lock.json` is the only intended tracked addition. The plan must **observe** the actual files written and adjust gitignore accordingly.

## 6. Follow vs. override matrix

| Skill rule | Decision |
|------------|----------|
| Em-dash ban (complete) | **Follow** — zero em-dashes anywhere |
| Single accent, saturation < 80% | **Follow** — sage only |
| No layout family twice (≥4 families) | **Follow** — 6 distinct families |
| Hero fits viewport; subtext ≤ 20 words, ≤ 4 lines | **Follow** |
| Eyebrow restraint (≤ ceil(sections/3)) | **Follow** — ≤ 2 eyebrows |
| Motion must be motivated; reduced-motion gating | **Follow** |
| Real images / real logos, no fake div-screenshots | **Follow** — real app/brand logos; the popup replica is the legitimate product UI, not a fake screenshot |
| `next/font` over Google `<link>` | **Follow** |
| Ban Fraunces as default display | **OVERRIDE** — brand uses Fraunces (user instruction wins) |
| Palette rotation / anti-default color discipline | **OVERRIDE** — locked brand palette wins |
| `DESIGN_VARIANCE` baseline 8 | **OVERRIDE down** — brand is calm/warm; effective variance ~5–6 |

## 7. Motion plan

`MOTION_INTENSITY` ~3–4 (calm brand). Every animation justified:

- Hero popup: subtle entrance (fade + 8px rise) echoing the app's `Theme.Motion.entry` (0.18s easeOut).
- Section reveals: IntersectionObserver / Motion `whileInView` fade-up, once.
- Diff "added" text: a one-time gentle highlight sweep to communicate "this is the rewrite."
- **No** scroll hijacking, **no** `window.addEventListener('scroll')`, at most one marquee (likely zero).
- Everything above `MOTION_INTENSITY > 3` gated behind `prefers-reduced-motion`.

## 8. File structure (proposed)

```
landing/
├── app/
│   ├── layout.tsx          # fonts (next/font), <html lang>, metadata
│   ├── page.tsx            # composes the 6 sections
│   └── globals.css         # Tailwind v4 + theme tokens (§4)
├── components/
│   ├── Nav.tsx
│   ├── Hero.tsx
│   ├── PopupReplica.tsx    # the ImprovePromptFloater mirror
│   ├── HowItWorks.tsx
│   ├── PrivacyBand.tsx
│   ├── AppGrid.tsx
│   ├── ModeShowcase.tsx
│   └── DownloadFooter.tsx
├── public/
│   ├── owlet-logo.png      # the real provided logo
│   └── favicon / app-icon assets
├── package.json
└── (node_modules/, .next/ — gitignored)
```
Each component is one section with a single responsibility, independently understandable.

## 9. Implementation log (filled during build)

A running list of "skill rule X → decision Y" entries, plus any rule that was hard to satisfy or that conflicted with the brand. This is the evidence the skill was actually exercised.

## 10. Verification

**Build/run:**
```bash
cd landing && npm install && npm run build && npm run dev
```
Then view at the dev URL.

**Checks:**
- `npm run build` succeeds (no type/lint errors).
- The skill's §14 Pre-Flight checklist walked item by item, recorded pass/fail.
- Lighthouse/Core Web Vitals sane (LCP < 2.5s, CLS < 0.1) on the built page.
- Visual parity with the locked design system (palette, fonts, logo, popup).

**Skill verdict (§1 goal 1):** a short written assessment — did `taste-skill` measurably improve the structural quality (layout variety, motion discipline, anti-slop bans) versus a naive build? Where did its rules help, where did they conflict with a locked brand, and would the user keep it installed?

## 11. Open questions / risks

- `skills add` may write more than `skills-lock.json` (node_modules, symlinks). Mitigation: observe and gitignore during the install step.
- Tailwind v4 is relatively new; if its setup fights Next.js, fall back to Tailwind v3 (note the deviation — it's a stack detail, not a design change).
- Icon library choice (Phosphor vs Tabler) deferred to implementation; either satisfies the skill.
