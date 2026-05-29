# Owlet Design System

> Reference for the SwiftUI view layer of the Owlet macOS menu-bar app.
> Audience: developers building or modifying Owlet's UI.

## Source of truth

The authoritative values live in code, not here:

- **`Owlet/Owlet/OwletDesignSystem.swift`** — the `OwletDesign` enum. The branded
  token set. **If a value below disagrees with that file, the file wins.** Treat
  the tables in this doc as a readable mirror that can drift.
- Provenance only: the tokens were lifted from a design handoff bundle
  (`colors_and_type.css`, React `*.jsx` sources). Don't anchor on the handoff —
  anchor on the Swift enum.

## The three tiers (read this first)

Owlet is **not one design system applied app-wide**. It has three distinct UI
tiers, and conflating them is the single most common mistake. Know which tier a
surface belongs to *before* you style it.

| Tier | What | Tokens | Surfaces |
|------|------|--------|----------|
| **1 — Branded** | The Owlet look: sage/coral/paper, serif display | `OwletDesign` | `ImprovePromptFloater`, `OwletMark` |
| **2 — Native** | Deliberately plain macOS system styling | none (system fonts / `NSColor` / `Form`) | `SettingsView`, `PermissionModal`, `HotkeyRecorderField`, `FloatingButtonView`, status-bar menu, region-selector overlay |
| **3 — Legacy** | Deprecated v0.1–v0.3 popup, superseded | `Theme` | `PopupView`, `ResultView`, `ErrorView`, `LoadingView`, `NoChangesView`, `DiffView` |

**Rules of thumb:**

- Building or touching the **rewriter popup** or the **owl mark**? → Tier 1, use `OwletDesign`.
- Building **Settings, permissions, the menu, or system-chrome surfaces**? → Tier 2, use native AppKit. Do **not** apply brand tokens here; matching macOS is the intent.
- Touching anything in Tier 3? → it's legacy. Prefer porting it onto Tier 1 or deleting it. Don't extend `Theme`.

---

## Design philosophy

From the `ImprovePromptFloater` design notes — the governing principle for Tier 1:

> **Quiet-by-default: the rewrite is the hero. Everything else is chrome, and
> chrome whispers.** Borderless mode chips, inline summary, no "Original"
> preview, no model name in the footer.

Concretely, this means:

- The **rewritten text** is the largest, highest-contrast element (17pt Fraunces italic on near-black ink).
- Chrome — header label, hotkey hint, mode chips, secondary actions — sits in muted/subtle ink and only one element ever competes for attention (the primary action).
- Surfaces are **paper-cream and translucent**, sitting softly over whatever is behind them rather than asserting a hard panel.

---

# Tier 1 — `OwletDesign` (the branded system)

All tokens are static members of the `OwletDesign` enum. Access them directly:
`OwletDesign.brand`, `OwletDesign.Radius.lg`, `OwletDesign.ui(size: 13)`.

> **Light scheme only.** `OwletDesign` has no dark-mode variants. Every token is
> a fixed light value. Don't reach for `@Environment(\.colorScheme)` here — the
> branded surfaces render the same in both system appearances by design.

## Color

### Raw palettes

Paper — light surfaces:

| Token | Hex | Role |
|-------|-----|------|
| `Paper.p0` | `#FAF8F2` | Canvas |
| `Paper.p1` | `#F2EFE7` | Card |
| `Paper.p2` | `#E5E1D5` | Sunken / hover |
| `Paper.p3` | `#D2CDC0` | Hairline |

Ink — foreground:

| Token | Hex | Role |
|-------|-----|------|
| `Ink.i0` | `#1F2A2A` | Primary text |
| `Ink.i1` | `#3E4848` | Secondary |
| `Ink.i2` | `#6E7474` | Tertiary |
| `Ink.i3` | `#9DA0A0` | Disabled |

Sage — primary brand (`s500` is **PRIMARY**):

| Token | Hex | | Token | Hex |
|-------|-----|---|-------|-----|
| `Sage.s50`  | `#EBF2EF` | | `Sage.s600` | `#437975` (press) |
| `Sage.s100` | `#D4E4DF` | | `Sage.s700` | `#305955` |
| `Sage.s200` | `#A8C8C0` | | `Sage.s800` | `#2E5754` |
| `Sage.s300` | `#82AFA6` | | `Sage.s900` | `#1E3E3C` |
| `Sage.s500` | `#5E9590` **(PRIMARY)** | | | |

Coral — secondary / accent (`c500` is **SECONDARY**):

| Token | Hex | | Token | Hex |
|-------|-----|---|-------|-----|
| `Coral.c50`  | `#FEEFEA` | | `Coral.c500` | `#ED7B68` **(SECONDARY)** |
| `Coral.c100` | `#FDE2DC` | | `Coral.c600` | `#DF5342` |
| `Coral.c200` | `#F9C0B4` | | `Coral.c700` | `#B84938` |
| `Coral.c300` | `#F49684` | | | |

### Semantic role tokens (use these, not raw palette, where one exists)

| Token | Resolves to | Use for |
|-------|-------------|---------|
| `bg` | `Paper.p0` | Window / canvas background |
| `bgElev` | `Paper.p1` | Elevated card |
| `bgSunken` | `Paper.p2` | Hover / pressed fills |
| `fg` | `Ink.i0` | Primary text |
| `fgMuted` | `Ink.i1` | Secondary text, chrome labels |
| `fgSubtle` | `Ink.i2` | Tertiary text, hints, icon defaults |
| `fgDisabled` | `Ink.i3` | Disabled text |
| `hairline` | `Paper.p3` | 1px borders |
| `brand` | `Sage.s500` | Primary action fill, active accents |
| `brandPress` | `Sage.s600` | Primary action pressed |
| `brandSoft` | `Sage.s50` | Active chip / success-state soft fill |
| `accent` | `Coral.c500` | Thinking dots, beak, attention accent |
| `accentSoft` | `Coral.c100` | Soft coral fill |
| `danger` | `#C44A37` | Error icon, error border/fill base |
| `diffAdded` | `#1A8A3B` | Inserted words in a diff |
| `diffRemoved` | `#C44A37` | Removed words (with strikethrough) |
| `floaterFill` | `Paper.p0` @ 94% | The popup surface fill over vibrancy |

## Typography

Two brand typefaces plus a mono. All accessed through helpers, never `Font.custom`
inline — the helpers encode the PostScript-name mapping.

| Helper | Family | Use for |
|--------|--------|---------|
| `OwletDesign.displayItalic(size:)` | **Fraunces Italic** | The rewrite output — the hero text (17pt) |
| `OwletDesign.ui(size:weight:)` | **Be Vietnam Pro** | All UI text: labels, buttons, chips |
| `OwletDesign.mono(size:weight:)` | **SF Mono** | The keyboard-chord hint only (~10pt) |

```swift
Text(rewritten).font(OwletDesign.displayItalic(size: 17))
Text("Improve prompt").font(OwletDesign.ui(size: 12, weight: .medium))
Text("⌥ Space").font(OwletDesign.mono(size: 10))
```

**Weight mapping (Be Vietnam Pro).** `ui(size:weight:)` maps SwiftUI's coarse
`Font.Weight` to a PostScript name. Only Light / Regular / Medium / SemiBold /
Bold / ExtraBold are shipped; `.medium` is the default. Observed sizes in use:
17 (hero), 13 (button/error title), 12 (labels/chips/error body), 11 (notes), 10 (mono hint).

**Line spacing:** the hero text uses `lineSpacing(size * 0.5)` — half the point
size. Match this when rendering rewrite-style prose.

### Font install contract ⚠️

Fraunces and Be Vietnam Pro are **not bundled**. They are installed system-wide by
`install.sh` via Homebrew casks `font-fraunces` and `font-be-vietnam-pro`, and
referenced by PostScript name through `Font.custom`.

- If a cask is **not installed**, `Font.custom` **silently falls back to the system
  font** (SF Pro). The app stays usable but renders off-brand. There is no runtime
  check — `install.sh` is the contract.
- **Fraunces variable-axis limitation:** SwiftUI's `Font.custom` can't set
  `font-variation-settings`, so the `SOFT`/`opsz` axes sit at factory defaults
  (SOFT=0, not the design's 50). Type still reads as Fraunces, just slightly less rounded. Accept this; don't try to work around it in views.
- **Mono is SF Mono, not JetBrains Mono.** The design references JetBrains Mono, but
  it's only used at ~10pt for one hint where the difference is negligible. Don't add
  the extra font install.

## Radius

| Token | Value | Typical use |
|-------|-------|-------------|
| `Radius.xs` | 4 | Skeleton lines |
| `Radius.sm` | 6 | Icon-button / chip hover fills, close button |
| `Radius.md` | 10 | — |
| `Radius.lg` | 14 | The floater surface |
| `Radius.xl` | 20 | — |
| `Radius.pill` | 999 | Capsule chips |

Always pair with `style: .continuous` (Apple's squircle) — every live surface does.

## Layout — Floater

| Token | Value |
|-------|-------|
| `Floater.width` | 420pt (fixed) |
| `Floater.paddingComfortable` | 14 / 16 / 14 / 16 (T/L/B/R) — default |
| `Floater.paddingCompact` | 12 / 14 / 12 / 14 |

Internal vertical rhythm in the floater (from `ImprovePromptFloater.body`):
header → 10pt → output → 12pt → mode chips → 12pt → actions.

Output regions cap at `maxHeight: 220` inside a non-indicator `ScrollView`.

## Motion

> The branded system has **no motion token scale.** `Theme.Motion` is legacy
> (Tier 3) — do not import it into Tier 1. The values below are the **de-facto**
> inline timings observed in the live components. Reuse them for consistency;
> don't invent a new curve.

| Effect | Timing | Where |
|--------|--------|-------|
| Copy-confirm swap | `easeInOut 0.15` | `CopyButton` (✓ "Copied", reverts after 2.0s) |
| Thinking dots | `easeInOut`, 0.4s/step, 3 dots | `ThinkingDots` |
| Skeleton shimmer | `linear 1.4s` repeat | `SkeletonLine` |
| Hero shimmer | `linear 1.8s` repeat | `ShimmerText` |
| Button press | `scaleEffect 0.98` while pressed | `PrimaryButton` |

---

## Components (Tier 1)

### `ImprovePromptFloater` — the rewriter popup

The 420pt branded popup hosting the rewrite. **Stateless** — driven entirely by a
`PopupState` value plus four callbacks (`onReplace`, `onCopy`, `onCancel`,
`onRetry`). It is wired live by `RewriterFlow`.

Anatomy: **header** (owl mark · "Improve prompt" label · status indicator · close)
→ **output** (state-dependent) → **mode chips** (result only) → **actions**.

Surface: `floaterFill` over `Radius.lg` continuous rect, with a 1px `hairline`
stroke overlay.

States (the `PopupState` cases) and what each shows:

| State | Output | Status indicator | Actions |
|-------|--------|------------------|---------|
| `.loading` | `ShimmerText` over source text | `ThinkingDots` | Cancel |
| `.loadingScreenshot` | "Analyzing screenshot…" shimmer | `ThinkingDots` | Cancel |
| `.result` (plain) | 17pt Fraunces italic, selectable | `⌥ Space` hint | Replace* · Try again · Copy |
| `.result` (diff) | `FlowText` colored segments | `⌥ Space` hint | Replace* · Try again · Copy |
| `.empty` | source text + "No changes needed." | `⌥ Space` hint | Dismiss · Copy |
| `.error` | `errorBox` (icon + title + detail) | `⌥ Space` hint | Try again · Dismiss |

\* **Replace** only appears when `captureMethod == .ax` (Accessibility can write
back). On clipboard-fallback captures the user can only Copy.

> Mode chips (Clarify / Add context / Structured / Examples / Compact) are
> currently **visual-only** — tapping changes the active chip but doesn't
> re-trigger Ollama (the backend has no `--mode` flag yet). Don't document them
> as functional behavior to users.

### Button & control primitives

These live **file-private inside `ImprovePromptFloater.swift`** — they are a
**pattern catalog, not a shared component library.** If you need one elsewhere,
either promote it to its own file deliberately or replicate the pattern; don't
assume it's importable.

| Primitive | Shape | Idle → Hover → Press/Active |
|-----------|-------|------------------------------|
| `PrimaryButton` | `Radius` 8 rect, paper-white text (`#F4F2EA`) | `brand` → `Sage.s600` → `brandPress`; scale 0.98 on press; 50% opacity when disabled |
| `GhostButton` | text-only, `Radius` 8 | `fgMuted` text, transparent → `bgSunken` fill on hover |
| `CopyButton` | icon, `Radius` 6 | `fgSubtle` → `bgSunken` hover; on copy: ✓ + "Copied" in `brand`/`brandSoft`, reverts after 2.0s |
| `CloseButton` | 22×22 "xmark", `Radius` 6 | `fgSubtle`, transparent → `bgSunken` hover; a11y label "Dismiss" |
| `ModeChip` | `Capsule` (pill) | inactive `fgMuted` / transparent; hover `bgSunken`; active `brand` text on `brandSoft`; tooltip = mode hint |

Common pattern for all of them: `Button { } .buttonStyle(.plain)` with `@State`
hover tracking via `.onHover`, and a rounded-rect/capsule background that swaps
fill on state. Press tracking uses the file-local `pressAction` gesture helper.

### Feedback / animation views

| View | What |
|------|------|
| `ThinkingDots` | 3 coral (`accent`) dots, 4pt, bouncing in sequence — the "processing" indicator |
| `ShimmerText` | source text in Fraunces with a moving brightness gradient — shown while loading so the user can still read their input |
| `SkeletonLine` | shimmering placeholder bar (fractional width + stagger delay) |
| `FlowText` | renders `[DiffSegment]` as wrapping prose: `diffAdded` / `diffRemoved` (struck-through) / `fg`, in Fraunces |

### `errorBox` (inside the floater)

Icon (`exclamationmark.circle` in `danger`) + bold title + muted detail, on a
`danger @ 6%` fill with a `danger @ 18%` 1px border, `Radius` 8. Every `ErrorKind`
maps to a plain-language title + actionable detail (see `errorTitle`/`errorDetail`).

### `OwletMark` — the owl logo

Vector owl drawn in a SwiftUI `Canvas` (no asset dependency). Native path space is
160×180; it scales uniformly into a `size × size` box, centered.

- **Two render modes:**
  - **Brand (default):** paper body with sage (`Sage.s500`) outline, white eye
    discs, sage rings/pupils, **coral (`Coral.c500`) beak**.
  - **Mono (`mono: true`):** whole mark in `monoColor` (defaults to `Sage.s500`),
    white sclera so eyes still read.
- `accessibilityHidden(true)` — it's decorative; the surrounding label carries meaning.
- Used at 15pt in the floater header; scales cleanly to any size.

```swift
OwletMark(size: 15)                                   // header
OwletMark(size: 64, mono: true, monoColor: .white)    // on a dark surface
```

---

# Tier 2 — Native AppKit surfaces (the boundary)

These surfaces **deliberately use macOS system styling** — system fonts, `NSColor`,
native `Form`/`Picker`/`Toggle`/`Button`. They carry **zero `OwletDesign` tokens,
and that is intentional**: they should look and feel like first-class macOS system
UI, not like the branded popup.

> **If you're implementing here, match the platform — do not apply brand tokens.**
> Adding sage/coral/Fraunces to Settings would make it feel off, not on-brand.

| Surface | Notes |
|---------|-------|
| `SettingsView` | `Form(.grouped)`, fixed **440pt** width (so layout doesn't reflow when the async model list arrives). Rows: hotkey recorder + Record/Reset, model `Picker`, launch-at-login `Toggle`. System fonts; `.caption`/`.secondary` for inline errors. |
| `PermissionModal` | 480pt. System fonts (17 semibold title, 13/12 body). `.borderedProminent` Quit as default action. Per-permission rows deep-link into System Settings. |
| `HotkeyRecorderField` | `NSViewRepresentable` custom-drawn field. 6pt rounded border: `separatorColor` idle / `controlAccentColor` (2px) recording. 13pt medium system label. Requires ≥1 modifier; Esc cancels. |
| `FloatingButtonView` | 32×32 circular glyph button. Uses the **`OwletGlyph` image asset** (template-rendered, adapts to appearance), `controlBackgroundColor` @ 90% fill, soft drop shadow. Note: this is the asset glyph, *not* `OwletMark`. |
| Status-bar menu (`StatusBarController`) | Pure `NSMenu` / `NSStatusItem`. No styling tokens at all. |
| Region-selector overlay (`RegionSelectorController`) | Screen-capture overlay drawn with raw `NSColor` (40% black dim, 12% white selection fill, white stroke, 14pt white system label, 60% black label chip). Now **one borderless overlay window per `NSScreen`** (multi-monitor correct); only the cursor's screen dims. The old SwiftUI `RegionSelectorOverlayView.swift` was removed. Specifics are settled, but the feature is preview / manual-verify-pending on a second display. |

**Brand assets** (used by Tier 2 / docs, distinct from the `Canvas`-drawn `OwletMark`):
`Owlet/Owlet/Assets.xcassets/OwletGlyph.imageset`, `Assets.xcassets/AppIcon.appiconset`,
and `docs/assets/owlet-logo.svg` / `owlet-glyph.svg`.

---

# Tier 3 — Legacy (`Theme.swift`, deprecated)

`Theme` and the popup views built on it are the **v0.1–v0.3 system-native popup**,
**superseded by `ImprovePromptFloater`**. `RewriterFlow` no longer instantiates
`PopupView`.

**Do not use `Theme` for new work, and do not present its tokens as co-equal with
`OwletDesign`.** Listed here only so you recognize legacy code:

- `Theme.Card` (480 width, 14 radius), `Theme.Motion`, `Theme.Fonts` (system),
  `Theme.Colors` (system-derived, light/dark adaptive, system green/red diffs).
- Views: `PopupView`, `ResultView`, `ErrorView`, `LoadingView`, `NoChangesView`, `DiffView`.

Direction of travel: port any still-needed behavior onto Tier 1 or delete. Don't extend Tier 3.

---

# Implementation guidelines (checklist)

When you build or change a UI surface:

1. **Identify the tier first.** Branded popup/mark → Tier 1. System chrome → Tier 2 (native). Legacy → don't extend it.
2. **Tier 1: use semantic role tokens** (`fgMuted`, `bgSunken`, `brand`…) over raw palette entries where a semantic token exists. Reach into `Sage.sNNN` etc. only for states the roles don't cover (e.g. `Sage.s600` hover).
3. **Tier 1 typography goes through the helpers** (`ui`/`displayItalic`/`mono`) — never `Font.custom` inline, never `.system` for branded text.
4. **Remember light-only.** No dark-mode branches in Tier 1.
5. **Continuous corners.** `RoundedRectangle(cornerRadius: OwletDesign.Radius.x, style: .continuous)`.
6. **Interaction pattern:** `.buttonStyle(.plain)` + `@State` hover + background-fill swap. Mirror the existing primitives rather than using default button chrome inside the floater.
7. **Tier 2: match macOS.** System fonts, native controls, `NSColor`. No brand tokens.
8. **Keep brand surfaces quiet.** One primary action max; everything else muted. The content is the hero.
9. **Verify the font contract** if you change install behavior — missing casks degrade silently to SF Pro.

## Verification

After UI changes, build and walk the manual smoke test (see `CLAUDE.md` /
`README.md`). SwiftUI build only:

```bash
(cd Owlet && xcodegen generate && \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet \
    -configuration Debug -destination 'platform=macOS' build)
```

`OwletMark` and `ImprovePromptFloater` ship `#Preview`s (the floater has one per
state) — use the Xcode canvas to eyeball token changes without the full app.
