# Owlet Marketing Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a 6-section Owlet marketing landing page in a standalone `landing/` Next.js app, using the installed `taste-skill` to drive structural UI quality, and produce a written verdict on whether the skill helped.

**Architecture:** A self-contained Next.js App Router app under `landing/`, isolated from the Swift/Rust build and from `./init.sh`. Owlet's locked design system (paper-cream + sage/coral, Fraunces + Be Vietnam Pro, the real logo PNG) is encoded as Tailwind v4 theme tokens. Each of the 6 sections is one focused component with a distinct layout family. The `taste-skill` is installed via `npx skills add` and its rules are applied (and consciously overridden where the brand wins, per the spec's §6 matrix).

**Tech Stack:** Next.js (App Router, RSC), TypeScript, Tailwind v4, `motion/react`, `next/font/google`, Playwright (structural verification).

**Spec:** `docs/superpowers/specs/2026-05-29-marketing-landing-page-design.md`

---

## File Structure

```
landing/
├── app/
│   ├── layout.tsx          # fonts (next/font), metadata, <html lang>
│   ├── page.tsx            # composes the 6 sections + Nav
│   └── globals.css         # Tailwind v4 import + @theme tokens
├── components/
│   ├── Nav.tsx             # top bar: logo + links + Download
│   ├── PopupReplica.tsx    # the ImprovePromptFloater mirror (hero visual)
│   ├── Hero.tsx            # §1 Split
│   ├── HowItWorks.tsx      # §2 3-step row
│   ├── PrivacyBand.tsx     # §3 inverted sage band
│   ├── AppGrid.tsx         # §4 app logo grid
│   ├── ModeShowcase.tsx    # §5 mode chips + before/after
│   ├── DownloadFooter.tsx  # §6 centered CTA + footer
│   └── Reveal.tsx          # shared motion wrapper (whileInView, reduced-motion safe)
├── tests/
│   └── structure.spec.ts   # Playwright: structural / anti-slop assertions
├── playwright.config.ts
├── public/
│   └── owlet-logo.png      # the real provided logo asset
├── package.json
└── (node_modules/, .next/ — gitignored)
```

Brand constants reused across tasks (copy/paste exact values):

```
Palette: paper-0 #FAF8F2 · paper-1 #F2EFE7 · paper-2 #E5E1D5 · paper-3 #D2CDC0
         ink-0 #1F2A2A · ink-1 #3E4848 · ink-2 #6E7474
         sage-500 #5E9590 · sage-600 #437975 · sage-50 #EBF2EF · sage-800 #2E5754
         coral-500 #ED7B68 · diff-added #1A8A3B · diff-removed #C44A37
Fonts:   display = Fraunces Italic · ui = Be Vietnam Pro
Radius:  4 / 6 / 10 / 14 / 20 / 9999
Repo URL (placeholder CTA target): https://github.com/AKaLee-IK27/owlet
```

---

## Task 1: Install the taste-skill (the thing under test)

**Files:**
- Create/observe: `skills-lock.json`, and whatever `skills add` writes (`.claude/skills/…`, possibly `node_modules/`)

- [ ] **Step 1: Install the core skill project-level**

Run:
```bash
cd /Users/rowlet/Repos/owlet
npx --yes skills@latest add https://github.com/Leonxlnx/taste-skill --skill taste-skill --yes
```
Expected: clones the repo, reports the `taste-skill` installed for the detected `claude-code` agent.

- [ ] **Step 2: Observe exactly what was written**

Run:
```bash
git status --porcelain | grep -viE 'Owlet/|tools/|feature_list|progress\.md|README|\.omo|\.superpowers|docs/'
ls -la .claude/skills/ 2>/dev/null || true
```
Record the new paths. Read the installed SKILL.md so the rules are in context:
```bash
find .claude -iname 'SKILL.md' -path '*taste*' -exec sed -n '1,40p' {} \;
```

- [ ] **Step 3: Gitignore the noise, keep the lock**

Append to root `.gitignore` (only the entries that actually appeared):
```
# taste-skill install
/node_modules/
/.claude/skills/
```
Keep `skills-lock.json` tracked (it records the verification's exact skill version). If `skills add` symlinked rather than copied, that's fine — the symlink targets are gitignored.

- [ ] **Step 4: Commit the install footprint**

```bash
git add skills-lock.json .gitignore
git commit -m "chore: install taste-skill for landing-page verification"
```
(Stage nothing else — the tree has unrelated Swift WIP.)

---

## Task 2: Scaffold the Next.js app

**Files:**
- Create: `landing/` (entire Next.js scaffold)

- [ ] **Step 1: Generate the app non-interactively**

Run:
```bash
cd /Users/rowlet/Repos/owlet
npx --yes create-next-app@latest landing \
  --ts --app --tailwind --eslint --no-src-dir \
  --import-alias "@/*" --use-npm --turbopack --yes
```
Expected: `landing/` created with Tailwind v4, an `app/` dir, `package.json`.

- [ ] **Step 2: Add runtime deps**

Run:
```bash
cd /Users/rowlet/Repos/owlet/landing
npm install motion
npm install -D @playwright/test
```
Expected: both install cleanly.

- [ ] **Step 3: Verify the scaffold builds**

Run:
```bash
cd /Users/rowlet/Repos/owlet/landing && npm run build
```
Expected: build succeeds (default Next.js starter).

- [ ] **Step 4: Ensure ignores**

Confirm `landing/.gitignore` (created by create-next-app) ignores `/node_modules`, `/.next`. If missing, add them.

- [ ] **Step 5: Commit the scaffold**

```bash
cd /Users/rowlet/Repos/owlet
git add landing
git commit -m "chore: scaffold landing/ Next.js app"
```

---

## Task 3: Design tokens + fonts

**Files:**
- Replace: `landing/app/globals.css`
- Replace: `landing/app/layout.tsx`

- [ ] **Step 1: Write the theme tokens**

Replace `landing/app/globals.css` with:
```css
@import "tailwindcss";

@theme {
  --color-paper-0: #FAF8F2;
  --color-paper-1: #F2EFE7;
  --color-paper-2: #E5E1D5;
  --color-paper-3: #D2CDC0;
  --color-ink-0: #1F2A2A;
  --color-ink-1: #3E4848;
  --color-ink-2: #6E7474;
  --color-sage-50: #EBF2EF;
  --color-sage-500: #5E9590;
  --color-sage-600: #437975;
  --color-sage-800: #2E5754;
  --color-coral-500: #ED7B68;
  --color-diff-added: #1A8A3B;
  --color-diff-removed: #C44A37;

  --font-display: var(--font-fraunces);
  --font-sans: var(--font-be-vietnam);

  --radius-card: 14px;
}

html { background: var(--color-paper-0); color: var(--color-ink-0); }
body { font-family: var(--font-sans), system-ui, sans-serif; -webkit-font-smoothing: antialiased; }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.001ms !important; transition-duration: 0.001ms !important; }
}
```

- [ ] **Step 2: Wire fonts + metadata in layout**

Replace `landing/app/layout.tsx` with:
```tsx
import type { Metadata } from "next";
import { Fraunces, Be_Vietnam_Pro } from "next/font/google";
import "./globals.css";

const fraunces = Fraunces({
  subsets: ["latin"],
  style: ["italic", "normal"],
  weight: ["400", "500", "600"],
  variable: "--font-fraunces",
});

const beVietnam = Be_Vietnam_Pro({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-be-vietnam",
});

export const metadata: Metadata = {
  title: "Owlet — rewrite anything, right where you are",
  description:
    "A friendly local-LLM rewriter for macOS. Select text, press a hotkey, get clearer writing. No cloud, no API keys.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${fraunces.variable} ${beVietnam.variable}`}>
      <body>{children}</body>
    </html>
  );
}
```

- [ ] **Step 3: Verify build still passes**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build`
Expected: PASS (fonts fetched at build).

- [ ] **Step 4: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/app/globals.css landing/app/layout.tsx
git commit -m "feat(landing): design tokens + brand fonts"
```

---

## Task 4: Logo asset + Nav

**Files:**
- Create: `landing/public/owlet-logo.png`
- Create: `landing/components/Nav.tsx`

- [ ] **Step 1: Place the real logo**

Copy the user-provided logo into the app. The brainstorm cached it; the canonical copy lives at the image the user supplied. Use the in-repo app-icon as the durable source:
```bash
cp /Users/rowlet/Repos/owlet/Owlet/Owlet/Assets.xcassets/AppIcon.appiconset/icon_256x256.png \
   /Users/rowlet/Repos/owlet/landing/public/owlet-logo.png
```
If the user's supplied PNG (winking-owl, transparent bg) differs from the app icon and is preferred, drop that file in at the same path instead. Either way: **use the PNG as an image asset; do not reconstruct it as SVG.**

- [ ] **Step 2: Write the Nav**

Create `landing/components/Nav.tsx`:
```tsx
import Image from "next/image";

export default function Nav() {
  return (
    <nav className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
      <a href="#hero" className="flex items-center gap-2.5 font-semibold tracking-tight text-ink-0">
        <Image src="/owlet-logo.png" alt="Owlet logo" width={30} height={33} className="h-[30px] w-auto" priority />
        Owlet
      </a>
      <div className="flex items-center gap-7 text-sm text-ink-1">
        <a href="#how-it-works" className="hover:text-ink-0">How it works</a>
        <a href="#privacy" className="hover:text-ink-0">Privacy</a>
        <a
          href="https://github.com/AKaLee-IK27/owlet"
          className="rounded-lg bg-sage-500 px-4 py-2 font-medium text-[#F4F2EA] hover:bg-sage-600"
        >
          Download
        </a>
      </div>
    </nav>
  );
}
```

- [ ] **Step 3: Verify build**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/Nav.tsx landing/public/owlet-logo.png
git commit -m "feat(landing): logo asset + nav"
```

---

## Task 5: PopupReplica (the product visual)

Mirrors `Owlet/Owlet/Views/ImprovePromptFloater.swift`. This is the legitimate product UI, not a fake screenshot (satisfies the skill's real-images rule).

**Files:**
- Create: `landing/components/PopupReplica.tsx`

- [ ] **Step 1: Write the component**

Create `landing/components/PopupReplica.tsx`:
```tsx
import Image from "next/image";

export default function PopupReplica() {
  return (
    <div className="w-[420px] max-w-full rounded-[14px] border border-paper-3 bg-paper-0/95 p-4 shadow-[0_24px_60px_rgba(20,40,38,0.35)]">
      <div className="mb-2.5 flex items-center gap-2">
        <Image src="/owlet-logo.png" alt="" width={18} height={20} className="h-5 w-auto" />
        <span className="text-xs font-medium text-ink-1">Improve prompt</span>
        <span className="ml-auto font-mono text-[10px] text-ink-2">⌥ Space</span>
        <span className="grid h-[22px] w-[22px] place-items-center text-[11px] text-ink-2">✕</span>
      </div>

      <p className="mb-3 font-display text-[17px] italic leading-[1.5] text-ink-0">
        <span className="text-diff-removed line-through">write me a blog post about ai</span>{" "}
        <span className="text-diff-added">
          Write a 600-word post for engineers on practical local-LLM workflows, with one concrete example per use case.
        </span>
      </p>

      <div className="mb-3 flex flex-wrap gap-1">
        <span className="rounded-full bg-sage-50 px-2.5 py-1 text-xs font-medium text-sage-500">Clarify</span>
        <span className="rounded-full px-2.5 py-1 text-xs font-medium text-ink-1">Add context</span>
        <span className="rounded-full px-2.5 py-1 text-xs font-medium text-ink-1">Structured</span>
        <span className="rounded-full px-2.5 py-1 text-xs font-medium text-ink-1">Compact</span>
      </div>

      <div className="flex items-center gap-1.5">
        <button className="rounded-lg bg-sage-500 px-4 py-1.5 text-[13px] font-medium text-[#F4F2EA]">Replace</button>
        <span className="rounded-lg px-3 py-1.5 text-[13px] font-medium text-ink-1">Try again</span>
        <span className="ml-auto flex items-center gap-1.5 text-[13px] text-ink-2">⧉ Copy</span>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/PopupReplica.tsx
git commit -m "feat(landing): rewriter popup replica"
```

---

## Task 6: Reveal motion wrapper

**Files:**
- Create: `landing/components/Reveal.tsx`

- [ ] **Step 1: Write the wrapper**

Create `landing/components/Reveal.tsx`:
```tsx
"use client";
import { motion, useReducedMotion } from "motion/react";

export default function Reveal({
  children,
  delay = 0,
  className,
}: {
  children: React.ReactNode;
  delay?: number;
  className?: string;
}) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      className={className}
      initial={reduce ? false : { opacity: 0, y: 12 }}
      whileInView={reduce ? undefined : { opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.4, ease: "easeOut", delay }}
    >
      {children}
    </motion.div>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/Reveal.tsx
git commit -m "feat(landing): reduced-motion-safe reveal wrapper"
```

---

## Task 7: Hero (§1 — Split)

**Files:**
- Create: `landing/components/Hero.tsx`

Constraints (skill): headline ≤ 2 lines, subtext ≤ 20 words and ≤ 4 lines, hero fits initial viewport, hero top padding ≤ 6rem, max 4 stacked text elements, one eyebrow. No em-dashes.

- [ ] **Step 1: Write the Hero**

Create `landing/components/Hero.tsx`:
```tsx
import PopupReplica from "./PopupReplica";

export default function Hero() {
  return (
    <section id="hero" className="mx-auto grid max-w-6xl items-center gap-10 px-6 pb-20 pt-10 md:grid-cols-2">
      <div>
        <p className="mb-4 text-xs font-semibold uppercase tracking-[0.08em] text-sage-600">
          Local. Private. macOS.
        </p>
        <h1 className="font-display text-[clamp(40px,6vw,56px)] font-medium italic leading-[1.04] tracking-tight text-ink-0">
          Rewrite anything,<br />right where you are.
        </h1>
        <p className="mt-4 max-w-[42ch] text-base leading-relaxed text-ink-1">
          Select text in any app, press your hotkey, and a model on your own Mac rewrites it clearly. No cloud.
        </p>
        <div className="mt-6 flex items-center gap-2.5">
          <a href="https://github.com/AKaLee-IK27/owlet" className="rounded-[10px] bg-sage-500 px-5 py-3 text-[15px] font-medium text-[#F4F2EA] hover:bg-sage-600">
            Download for macOS
          </a>
          <a href="#how-it-works" className="px-4 py-3 text-[15px] font-medium text-ink-1 hover:text-ink-0">
            See how it works
          </a>
        </div>
      </div>

      <div className="flex justify-center rounded-[20px] bg-[linear-gradient(155deg,#2E5754,#24433f)] p-8 md:p-10">
        <PopupReplica />
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/Hero.tsx
git commit -m "feat(landing): hero section"
```

---

## Task 8: HowItWorks (§2 — 3-step row)

**Files:**
- Create: `landing/components/HowItWorks.tsx`

- [ ] **Step 1: Write the section**

Create `landing/components/HowItWorks.tsx`:
```tsx
import Reveal from "./Reveal";

const STEPS = [
  { n: "1", t: "Select text", d: "Highlight a draft, a prompt, or a paragraph in any app." },
  { n: "2", t: "Press ⌥ Space", d: "Owlet reads the selection and asks your local model to rewrite it." },
  { n: "3", t: "Replace or Copy", d: "Review the inline diff, then drop it in place or copy it out." },
];

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="mx-auto max-w-6xl px-6 py-20">
      <h2 className="mb-10 font-display text-[32px] font-medium italic text-ink-0">How it works</h2>
      <div className="grid gap-5 md:grid-cols-3">
        {STEPS.map((s, i) => (
          <Reveal key={s.n} delay={i * 0.08} className="rounded-[14px] border border-paper-3 bg-paper-1 p-6">
            <div className="grid h-9 w-9 place-items-center rounded-lg bg-sage-50 text-[15px] font-semibold text-sage-600">
              {s.n}
            </div>
            <h3 className="mt-4 text-[17px] font-semibold text-ink-0">{s.t}</h3>
            <p className="mt-2 text-sm leading-relaxed text-ink-1">{s.d}</p>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/HowItWorks.tsx
git commit -m "feat(landing): how-it-works section"
```

---

## Task 9: PrivacyBand (§3 — inverted sage band)

**Files:**
- Create: `landing/components/PrivacyBand.tsx`

- [ ] **Step 1: Write the section**

Create `landing/components/PrivacyBand.tsx`:
```tsx
import Reveal from "./Reveal";

const POINTS = [
  { t: "No cloud", d: "Your text never leaves the machine. There is no server to send it to." },
  { t: "No API keys", d: "Nothing to sign up for, nothing to pay per token." },
  { t: "Your model, your Mac", d: "Runs on Ollama locally. Swap the model whenever you like." },
];

export default function PrivacyBand() {
  return (
    <section id="privacy" className="bg-sage-800 py-20 text-[#EAF2EF]">
      <div className="mx-auto max-w-6xl px-6">
        <h2 className="max-w-[18ch] font-display text-[34px] font-medium italic leading-tight">
          Private by default, because nothing leaves your Mac.
        </h2>
        <div className="mt-10 grid gap-8 md:grid-cols-3">
          {POINTS.map((p, i) => (
            <Reveal key={p.t} delay={i * 0.08}>
              <h3 className="text-lg font-semibold">{p.t}</h3>
              <p className="mt-2 text-sm leading-relaxed text-[#C7DAD5]">{p.d}</p>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Verify build + commit**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build` (Expected: PASS), then:
```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/PrivacyBand.tsx
git commit -m "feat(landing): privacy band section"
```

---

## Task 10: AppGrid (§4 — logo grid)

**Files:**
- Create: `landing/components/AppGrid.tsx`

Use a real icon set (no hand-rolled SVG). Use `@phosphor-icons/react`.

- [ ] **Step 1: Add the icon dep**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm install @phosphor-icons/react`
Expected: installs cleanly.

- [ ] **Step 2: Write the section**

Create `landing/components/AppGrid.tsx`:
```tsx
import Reveal from "./Reveal";
import {
  NotePencil, ChatCircleText, FileText, GoogleChromeLogo, Code, EnvelopeSimple,
} from "@phosphor-icons/react/dist/ssr";

const APPS = [
  { Icon: NotePencil, label: "TextEdit" },
  { Icon: ChatCircleText, label: "Slack" },
  { Icon: FileText, label: "Notion" },
  { Icon: GoogleChromeLogo, label: "Chrome" },
  { Icon: Code, label: "VS Code" },
  { Icon: EnvelopeSimple, label: "Mail" },
];

export default function AppGrid() {
  return (
    <section id="apps" className="mx-auto max-w-6xl px-6 py-20">
      <h2 className="font-display text-[32px] font-medium italic text-ink-0">Works in every app</h2>
      <p className="mt-3 max-w-[52ch] text-sm leading-relaxed text-ink-1">
        Owlet reads your selection directly where it can, and falls back to the clipboard everywhere else. So it works in native apps, browsers, and Electron alike.
      </p>
      <div className="mt-10 grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-6">
        {APPS.map((a, i) => (
          <Reveal key={a.label} delay={i * 0.05} className="flex flex-col items-center gap-2 rounded-[14px] border border-paper-3 bg-paper-1 py-6">
            <a.Icon size={28} weight="duotone" className="text-sage-600" />
            <span className="text-xs text-ink-1">{a.label}</span>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
```

- [ ] **Step 3: Verify build + commit**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build` (Expected: PASS), then:
```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/AppGrid.tsx landing/package.json landing/package-lock.json
git commit -m "feat(landing): app-compatibility grid"
```

---

## Task 11: ModeShowcase (§5 — showcase)

**Files:**
- Create: `landing/components/ModeShowcase.tsx`

- [ ] **Step 1: Write the section**

Create `landing/components/ModeShowcase.tsx` (image-left / text-right, the reverse split of the hero, so the family reads distinct):
```tsx
import Reveal from "./Reveal";

const MODES = [
  { t: "Clarify", d: "Make goals and constraints explicit." },
  { t: "Add context", d: "Fill in audience, scope, assumptions." },
  { t: "Structured", d: "Role, task, format, constraints." },
  { t: "Compact", d: "Specific, but short." },
];

export default function ModeShowcase() {
  return (
    <section id="modes" className="mx-auto grid max-w-6xl items-center gap-10 px-6 py-20 md:grid-cols-2">
      <Reveal className="rounded-[14px] border border-paper-3 bg-paper-1 p-6">
        <p className="text-xs text-ink-2">Before</p>
        <p className="mt-1 font-display text-[17px] italic text-ink-2">make this email less harsh</p>
        <div className="my-4 h-px bg-paper-3" />
        <p className="text-xs text-ink-2">After (Clarify)</p>
        <p className="mt-1 font-display text-[17px] italic leading-[1.5] text-ink-0">
          Rewrite this email to stay direct but warmer. Keep the ask in the first line and soften the closing.
        </p>
      </Reveal>

      <div>
        <h2 className="font-display text-[32px] font-medium italic text-ink-0">Rewrite the way you mean</h2>
        <p className="mt-3 max-w-[46ch] text-sm leading-relaxed text-ink-1">
          Pick how Owlet should reshape your text. Each mode steers the local model toward a different kind of clarity.
        </p>
        <ul className="mt-6 space-y-3">
          {MODES.map((m) => (
            <li key={m.t} className="flex gap-3">
              <span className="mt-0.5 rounded-full bg-sage-50 px-2.5 py-1 text-xs font-medium text-sage-500">{m.t}</span>
              <span className="text-sm text-ink-1">{m.d}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Verify build + commit**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build` (Expected: PASS), then:
```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/ModeShowcase.tsx
git commit -m "feat(landing): rewrite-modes showcase"
```

---

## Task 12: DownloadFooter (§6 — centered CTA)

**Files:**
- Create: `landing/components/DownloadFooter.tsx`

- [ ] **Step 1: Write the section**

Create `landing/components/DownloadFooter.tsx`:
```tsx
import Image from "next/image";

export default function DownloadFooter() {
  return (
    <>
      <section id="download" className="mx-auto max-w-3xl px-6 py-20 text-center">
        <h2 className="font-display text-[36px] font-medium italic text-ink-0">Bring Owlet home</h2>
        <p className="mx-auto mt-3 max-w-[44ch] text-sm leading-relaxed text-ink-1">
          Free and open source. Needs macOS 14 or later and Ollama installed locally.
        </p>
        <div className="mt-7 flex justify-center">
          <a href="https://github.com/AKaLee-IK27/owlet" className="rounded-[10px] bg-sage-500 px-6 py-3 text-[15px] font-medium text-[#F4F2EA] hover:bg-sage-600">
            Download for macOS
          </a>
        </div>
        <p className="mt-4 text-xs text-ink-2">Requires macOS 14+ · Ollama · Apple Silicon recommended</p>
      </section>

      <footer className="border-t border-paper-3">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-6 py-8 text-sm text-ink-2 sm:flex-row">
          <span className="flex items-center gap-2">
            <Image src="/owlet-logo.png" alt="Owlet logo" width={22} height={24} className="h-[22px] w-auto" />
            Owlet
          </span>
          <div className="flex items-center gap-6">
            <a href="https://github.com/AKaLee-IK27/owlet" className="hover:text-ink-0">GitHub</a>
            <a href="#privacy" className="hover:text-ink-0">Privacy</a>
            <span>A friendly small owl, after the Pokémon Rowlet.</span>
          </div>
        </div>
      </footer>
    </>
  );
}
```

- [ ] **Step 2: Verify build + commit**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run build` (Expected: PASS), then:
```bash
cd /Users/rowlet/Repos/owlet
git add landing/components/DownloadFooter.tsx
git commit -m "feat(landing): download + footer"
```

---

## Task 13: Compose the page

**Files:**
- Replace: `landing/app/page.tsx`

- [ ] **Step 1: Write the composition**

Replace `landing/app/page.tsx` with:
```tsx
import Nav from "@/components/Nav";
import Hero from "@/components/Hero";
import HowItWorks from "@/components/HowItWorks";
import PrivacyBand from "@/components/PrivacyBand";
import AppGrid from "@/components/AppGrid";
import ModeShowcase from "@/components/ModeShowcase";
import DownloadFooter from "@/components/DownloadFooter";

export default function Home() {
  return (
    <main className="min-h-[100dvh]">
      <Nav />
      <Hero />
      <HowItWorks />
      <PrivacyBand />
      <AppGrid />
      <ModeShowcase />
      <DownloadFooter />
    </main>
  );
}
```

- [ ] **Step 2: Visually verify in the browser**

Run: `cd /Users/rowlet/Repos/owlet/landing && npm run dev`
Open the printed URL. Confirm all 6 sections render, fonts load (Fraunces italic headings, Be Vietnam body), sage/coral colors correct, logo shows, popup reads like the app. Stop the dev server.

- [ ] **Step 3: Commit**

```bash
cd /Users/rowlet/Repos/owlet
git add landing/app/page.tsx
git commit -m "feat(landing): compose full landing page"
```

---

## Task 14: Structural verification test (anti-slop gate)

Real Playwright tests asserting the taste-skill's structural invariants. This is the automated portion of "verify the skill."

**Files:**
- Create: `landing/playwright.config.ts`
- Create: `landing/tests/structure.spec.ts`

- [ ] **Step 1: Write the Playwright config**

Create `landing/playwright.config.ts`:
```ts
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  use: { baseURL: "http://localhost:3100" },
  webServer: {
    command: "npm run build && npm run start -- -p 3100",
    url: "http://localhost:3100",
    timeout: 120_000,
    reuseExistingServer: false,
  },
});
```

- [ ] **Step 2: Write the failing test**

Create `landing/tests/structure.spec.ts`:
```ts
import { test, expect } from "@playwright/test";

const SECTIONS = ["hero", "how-it-works", "privacy", "apps", "modes", "download"];

test("has exactly one h1", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1")).toHaveCount(1);
});

test("all six sections render", async ({ page }) => {
  await page.goto("/");
  for (const id of SECTIONS) {
    await expect(page.locator(`#${id}`)).toBeVisible();
  }
});

test("no em-dashes anywhere in visible text (skill ban)", async ({ page }) => {
  await page.goto("/");
  const body = await page.locator("body").innerText();
  expect(body.includes("—")).toBe(false);
});

test("every image has non-empty alt or explicit empty decorative alt", async ({ page }) => {
  await page.goto("/");
  const imgs = page.locator("img");
  const count = await imgs.count();
  expect(count).toBeGreaterThan(0);
  for (let i = 0; i < count; i++) {
    const alt = await imgs.nth(i).getAttribute("alt");
    expect(alt).not.toBeNull();
  }
});
```

- [ ] **Step 3: Install browser + run (verify it passes against the built page)**

Run:
```bash
cd /Users/rowlet/Repos/owlet/landing
npx playwright install chromium
npx playwright test
```
Expected: all 4 tests PASS. If the em-dash test fails, find and remove the em-dash (replace with period/comma/colon) — that is the skill ban catching real slop.

- [ ] **Step 4: Add a test script + commit**

Add to `landing/package.json` `"scripts"`: `"test": "playwright test"`. Then:
```bash
cd /Users/rowlet/Repos/owlet
git add landing/playwright.config.ts landing/tests/structure.spec.ts landing/package.json
git commit -m "test(landing): structural anti-slop assertions"
```

---

## Task 15: Skill verdict + docs

**Files:**
- Modify: `docs/superpowers/specs/2026-05-29-marketing-landing-page-design.md` (fill §9 log and §10 verdict)
- Modify: `progress.md`

- [ ] **Step 1: Walk the skill's Pre-Flight checklist**

Open the installed `taste-skill` SKILL.md §14 Pre-Flight Check. Walk every item against the built page; record pass/fail in the spec's §9 implementation log, noting which rule drove which decision (em-dash ban, single accent, 6 distinct layout families, hero viewport fit, eyebrow count, motion motivation).

- [ ] **Step 2: Run Lighthouse (optional but recommended)**

With `npm run dev` running, run a Lighthouse pass (Chrome DevTools or `npx lighthouse http://localhost:3000 --only-categories=performance,accessibility --quiet`). Record LCP/CLS/accessibility in §9.

- [ ] **Step 3: Write the verdict**

Fill spec §10 with a short written assessment: did `taste-skill` improve structural quality? Which rules helped, which conflicted with the locked brand, would you keep it installed? This is the answer to the user's original question.

- [ ] **Step 4: Update progress.md and commit**

Add a `progress.md` entry (what shipped: landing/ page + skill verification; what's next; any blockers). Then:
```bash
cd /Users/rowlet/Repos/owlet
git add docs/superpowers/specs/2026-05-29-marketing-landing-page-design.md progress.md
git commit -m "docs: taste-skill verification verdict + landing progress"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** §1 verification goal → Tasks 1, 14, 15. §2 six sections → Tasks 7–12. §3 stack/placement/isolation → Tasks 2, 3 (gitignore). §4 design system → Tasks 3, 4, 5. §5 install → Task 1. §6 follow/override matrix → enforced in Tasks 3 (fonts via next/font, Fraunces kept), 7 (hero constraints), 14 (em-dash test). §7 motion → Tasks 6, 7. §10 verdict → Task 15. No gaps.
- **Placeholder scan:** every code step contains full code; copy text is final (no lorem); commands have expected output. Task 15 §9/§10 are intentionally produced *by the build*, not pre-written — they are the verification output, with explicit instructions on what to record.
- **Type consistency:** component names match across `page.tsx` imports and file paths; `Reveal` props (`children`, `delay`, `className`) consistent; token names (`sage-500`, `paper-3`, `ink-1`, `diff-added`) identical between `globals.css` and every component.
- **Isolation:** no task wires `landing/` into `./init.sh`; every commit stages only landing/spec/progress files, never the Swift WIP.
