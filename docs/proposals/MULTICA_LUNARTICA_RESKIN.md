# Reskin Multica → Lunartica (Lunarpunk)

**Status:** Plan, awaiting approval to implement.
**Scope decision (locked):** *Visual reskin + display-name only.* Web + Desktop. No code-identifier or wire-protocol rename.
**Repos:** UI work happens in the Lunartica fork (`Lunartica/`). The LunarWing bridge (`lunarwing/ic/`) is **not modified** — see "Interop guarantee".

---

## Goal

Give the Lunartica fork a *lunarpunk* identity — moon references, a violet / black / cool-accent palette — with the **smallest possible diff**, while keeping the Multica daemon protocol byte-compatible so the existing LunarWing bridge keeps working untouched.

Two workstreams:

1. **Palette** — retheme the shared design tokens from the current blue (oklch hue 255) to a violet/black lunarpunk system (hue ~300 + cool aurora accents). One file drives both web and desktop.
2. **Identity** — swap the logo mark to a moon, and change the *visible* product name "Multica" → "Lunartica" in app chrome.

---

## Why this is a small change

- The whole color system is centralized in **`Lunartica/packages/ui/styles/tokens.css`** as oklch CSS variables (`:root` for light, `.dark` for dark).
- **Both apps import that same file:**
  - `apps/web/app/globals.css` → `@import "../../../packages/ui/styles/tokens.css";`
  - `apps/desktop/src/renderer/src/globals.css` → `@import "@multica/ui/styles/tokens.css";`
- The repo enforces "semantic tokens, no hardcoded colors" (`Lunartica/CLAUDE.md`), so retoning tokens cascades through every component.
- The in-app logo (`packages/ui/components/common/multica-icon.tsx`) is a single `currentColor` glyph — swap the shape once.

---

## Part 1 — Lunarpunk palette

Design intent:

- **Hue 300 (violet/purple)** is the new brand/primary. Neutrals get a faint violet tint (shifted from ~285.8 → 300) so grays read "cool moonlight" rather than plain.
- **Dark mode is the hero**: deep violet-black backgrounds, luminous violet primary, moonlight-silver foreground.
- **Cool aurora accents**: chart series spread violet → indigo → blue → cyan → teal; `--info` shifts toward cyan.
- **Status colors preserved**: `--destructive` / `--success` / `--warning` stay on their semantic hues for legibility — only nudged where needed.

### File: `Lunartica/packages/ui/styles/tokens.css`

Replace the `:root` block (currently lines ~53–99) and `.dark` block (~101–145). Proposed values:

```css
/* Lunartica design tokens — lunarpunk (violet/black) — shared across Web + Desktop */

:root {
    --background: oklch(0.995 0.003 300);
    --foreground: oklch(0.17 0.02 300);
    --card: oklch(0.995 0.003 300);
    --card-foreground: oklch(0.17 0.02 300);
    --popover: oklch(0.995 0.003 300);
    --popover-foreground: oklch(0.17 0.02 300);
    --primary: oklch(0.45 0.18 300);
    --primary-foreground: oklch(0.985 0.004 300);
    --secondary: oklch(0.965 0.008 300);
    --secondary-foreground: oklch(0.30 0.05 300);
    --muted: oklch(0.965 0.008 300);
    --muted-foreground: oklch(0.52 0.03 300);
    --accent: oklch(0.95 0.02 300);
    --accent-foreground: oklch(0.35 0.10 300);
    --destructive: oklch(0.577 0.245 27.325);
    --border: oklch(0.90 0.012 300);
    --input: oklch(0.90 0.012 300);
    --ring: oklch(0.55 0.16 300);
    /* Aurora chart spread: violet → indigo → blue → cyan → teal */
    --chart-1: oklch(0.55 0.20 300);
    --chart-2: oklch(0.58 0.16 280);
    --chart-3: oklch(0.62 0.13 255);
    --chart-4: oklch(0.68 0.11 220);
    --chart-5: oklch(0.74 0.10 195);
    --radius: 0.625rem;
    --sidebar: oklch(0.98 0.01 300);
    --sidebar-foreground: oklch(0.17 0.02 300);
    --sidebar-primary: oklch(0.45 0.18 300);
    --sidebar-primary-foreground: oklch(0.985 0.004 300);
    --sidebar-accent: oklch(0.95 0.02 300);
    --sidebar-accent-foreground: oklch(0.35 0.10 300);
    --sidebar-border: oklch(0.90 0.012 300);
    --sidebar-ring: oklch(0.55 0.16 300);
    --brand: oklch(0.50 0.20 300);
    --brand-foreground: oklch(0.985 0.004 300);
    --success: oklch(0.55 0.16 145);
    --warning: oklch(0.75 0.16 85);
    --info: oklch(0.58 0.16 210);
    --scrollbar-thumb: oklch(0.50 0.10 300 / 12%);
    --scrollbar-thumb-hover: oklch(0.50 0.12 300 / 20%);
    --scrollbar-track: transparent;
}

.dark {
    --background: oklch(0.15 0.014 300);
    --foreground: oklch(0.96 0.008 300);
    --card: oklch(0.19 0.016 300);
    --card-foreground: oklch(0.96 0.008 300);
    --popover: oklch(0.19 0.016 300);
    --popover-foreground: oklch(0.96 0.008 300);
    --primary: oklch(0.58 0.21 300);
    --primary-foreground: oklch(0.99 0.005 300);
    --secondary: oklch(0.26 0.02 300);
    --secondary-foreground: oklch(0.96 0.008 300);
    --muted: oklch(0.26 0.02 300);
    --muted-foreground: oklch(0.70 0.03 300);
    --accent: oklch(0.30 0.04 300);
    --accent-foreground: oklch(0.97 0.01 300);
    --destructive: oklch(0.704 0.191 22.216);
    --border: oklch(0.75 0.08 300 / 14%);
    --input: oklch(0.75 0.08 300 / 16%);
    --ring: oklch(0.65 0.18 300);
    --chart-1: oklch(0.72 0.20 300);
    --chart-2: oklch(0.68 0.16 280);
    --chart-3: oklch(0.64 0.14 255);
    --chart-4: oklch(0.70 0.12 220);
    --chart-5: oklch(0.76 0.11 195);
    --sidebar: oklch(0.17 0.016 300);
    --sidebar-foreground: oklch(0.96 0.008 300);
    --sidebar-primary: oklch(0.62 0.22 300);
    --sidebar-primary-foreground: oklch(0.99 0.005 300);
    --sidebar-accent: oklch(0.30 0.04 300);
    --sidebar-accent-foreground: oklch(0.97 0.01 300);
    --sidebar-border: oklch(0.75 0.08 300 / 14%);
    --sidebar-ring: oklch(0.65 0.18 300);
    --brand: oklch(0.70 0.20 300);
    --brand-foreground: oklch(0.99 0.005 300);
    --success: oklch(0.65 0.15 145);
    --warning: oklch(0.70 0.16 85);
    --info: oklch(0.70 0.16 210);
    --scrollbar-thumb: oklch(0.85 0.06 300 / 10%);
    --scrollbar-thumb-hover: oklch(0.85 0.08 300 / 20%);
    --scrollbar-track: transparent;
}
```

### File: `Lunartica/apps/web/app/custom.css`

The `.landing-light` block re-declares tokens to hardcoded light values for the always-light landing pages and pins `--brand: oklch(0.55 0.16 255)` (old blue). Update the brand line (and the light token tints, optionally) so nested token-driven components on landing match:

```css
--brand: oklch(0.50 0.20 300);
```

(Landing-page *layout/marketing visuals* are otherwise out of scope here — see Part 3 / out-of-scope.)

---

## Part 2 — Lunar identity (logo + name)

### 2a. In-app logo mark — `Lunartica/packages/ui/components/common/multica-icon.tsx`

Currently a clip-path 8-pointed star rendered via `<span class="bg-current" style={{clipPath}}>`. Keep the component name, props (`animate`/`noSpin`/`bordered`/`size`), wrapper classes, and the spin animations. Replace **only** the inner glyph with a crescent-moon inline SVG that fills `currentColor` (so it still inherits the violet brand token everywhere it's used):

```tsx
// inner glyph (replaces the clip-path span)
<svg viewBox="0 0 24 24" fill="currentColor" className="block size-full" aria-hidden="true">
  {/* crescent moon */}
  <path d="M15.6 2.2a9 9 0 1 0 6.2 13.2A7.2 7.2 0 0 1 15.6 2.2Z" />
  {/* optional 4-point sparkle nod to the original star */}
  <path d="M6.2 4.0l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8L3.7 6.5l1.8-.7Z" opacity="0.9" />
</svg>
```

The file name and export stay `multica-icon.tsx` / `MulticaIcon` (code identifiers are out of rename scope).

### 2b. Static brand assets (image files)

| File | Type | Action |
|------|------|--------|
| `Lunartica/apps/web/public/favicon.svg` | SVG | Replace with crescent mark (hand-editable text SVG). |
| `Lunartica/docs/assets/logo-dark.svg` / `logo-light.svg` | SVG | Replace with crescent mark (README/docs). |
| `Lunartica/docs/assets/banner.jpg` | JPG | Needs image editing — **flagged**, requires raster tooling. Lower priority (README only). |
| `Lunartica/apps/desktop/build/icon.{icns,ico,png}` | raster | App/installer icons — must be regenerated from the new mark via an icon toolchain (`png` → `icns`/`ico`). **Flagged.** |
| `Lunartica/apps/desktop/resources/icon.png` | PNG | Runtime tray/window icon — regenerate from the new mark. **Flagged.** |

SVGs are editable directly here. The raster/`.icns`/`.ico` files need an image pipeline; I'll produce a master SVG/PNG and the conversion commands, and call out anything that needs a tool not present in this environment rather than silently skipping it.

### 2c. Display name — app chrome (Phase A, minimal)

| File | What | Change |
|------|------|--------|
| `Lunartica/apps/web/app/layout.tsx` | `metadata.title.default` (~L65), `title.template` (~L66), `openGraph.siteName` (~L76) | "Multica" → "Lunartica". Optional: `description` (L68), dark `themeColor` `#05070b` → violet-black (L58). |
| `Lunartica/apps/desktop/package.json` | `productName` (L3) | "Multica" → "Lunartica". |
| `Lunartica/apps/desktop/src/renderer/index.html` | `<title>` (L6) | "Multica" → "Lunartica". |
| `Lunartica/apps/web/app/auth/callback/page.tsx` | UI copy (L151/153/164) | "Multica" → "Lunartica". |
| `Lunartica/apps/web/app/not-found.tsx` | "Back to Multica" (L15) | "Multica" → "Lunartica". |

### 2d. Display name — marketing/landing (Phase B, optional, larger)

`apps/web/app/(landing)/*` (homepage/about/download/changelog/contact-sales + structured-data names), `features/landing/i18n/en.ts`, `features/landing/components/*`. Social handles / domains (`x.com/MulticaAI`, `@multica_hq`, `multica.ai`, `metadataBase`) only change if Lunartica equivalents exist — otherwise left as-is. **Recommend deferring** unless you want the marketing site rebranded now too.

---

## Interop guarantee — what is NOT touched

To keep the LunarWing bridge working with **zero changes**, the reskin does not alter any wire- or code-level identifier:

- `@multica/*` package scopes and all imports
- Go module path and every `server/` API route (`/api/daemon/*`, `/api/issues`, `/api/skills`, …)
- Daemon protocol, WebSocket event names, token prefixes (`mul_`, `mdt_`)
- DB schema, sqlc, migrations
- Component/file identifiers (`MulticaIcon`, `MulticaLanding`, filenames)

Therefore these LunarWing bridge artifacts need **no edits**:
`lunarwing/ic/tools-src/multica-bridge/`, `lunarwing/ic/channels-src/multica/`, `lunarwing/ic/skills/multica-poll/SKILL.md`, and the registry entries. The bridge talks to `/api/daemon/*` with a `Bearer` token against `${MULTICA_HOST}` — none of which the reskin changes.

---

## Out of scope (this pass)

- **Mobile** (`apps/mobile/global.css`) and **Docs site** (`apps/docs/app/global.css`) theming — separate CSS, separate pass.
- Full code-identifier rename (`@multica/*` → `@lunartica/*`) and any wire-protocol rename.
- Marketing/landing deep copy (Phase 2d) unless requested.

---

## Verification

Run from `Lunartica/`:

```bash
pnpm typecheck
pnpm --filter @multica/web build      # web compiles with new tokens
pnpm dev:web                          # eyeball dashboard, light + dark
pnpm dev:desktop                      # eyeball desktop (shares tokens)
pnpm test                             # TS/Vitest (incl. font-fallback-order test that reads globals.css)
```

Visual checks: dashboard board view, sidebar, primary buttons, focus rings, charts/runtime activity, loading spinner (the moon mark), favicon, light↔dark toggle. Confirm landing pages still render (token override updated).

Interop smoke (no change expected): with a LunarWing instance pointed at this Lunartica server, `multica(action: "register")` then `claim_task` still round-trips.

---

## Implementation order

1. Palette → `tokens.css` (`:root` + `.dark`) and the `.landing-light` `--brand` line in `custom.css`.
2. Logo mark → `multica-icon.tsx` glyph swap; `favicon.svg`; docs SVGs.
3. Display name (Phase A app chrome).
4. Raster icons (desktop `.icns/.ico/.png`, banner) — flag any needing tooling not available here.
5. `pnpm typecheck` + build + visual pass.
6. (Optional) Phase B marketing copy; mobile/docs theming.
