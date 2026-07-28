# StratEx UI — Code Audit

**Subject:** `stratexfrontend.zip` — React 19 + Vite 6 SPA (`stratex-ui` v0.1.0)
**Date:** 28 July 2026
**Scope:** 37 files / ~14 JSX components, build scripts, packaging.

Findings marked **[verified]** were reproduced by building the app and driving it in
headless Chromium, not inferred from reading. Everything else is a code-level
observation.

---

## Summary

The UI design work is strong and the code is dense but broadly coherent. Two things
dominate the risk picture:

1. **A custom i18n layer rewrites the DOM behind React's back.** This is not a
   style concern — it silently freezes dynamic text app-wide, in English as well as
   French. Pagination and filter counters display stale values while the underlying
   data changes. This is the single highest-impact defect and is architectural, not
   a one-line fix.
2. **Authentication is a client-side mock that ships to production.** Working
   passwords are compiled into the JS bundle, and the admin/viewer distinction is a
   `sessionStorage` string the user can edit.

The app builds cleanly and the visual layer works well. There are no tests, no
linter config, and no CI.

| Sev | Count | Theme |
|---|---|---|
| High | 4 | i18n DOM corruption, credentials in bundle, path traversal, client-side authz |
| Medium | 10 | Non-functional controls, build config gaps, bundle size, no error boundary |
| Low | 9 | Accessibility, dead code, cross-browser gaps |

---

## High

### H1 — i18n layer freezes dynamic text across the app **[verified]**

`src/i18n/LanguageContext.jsx:262-289, 311-316`

`localizeDom()` walks every text node in `document.body`, caches the first value it
sees on the node itself (`node._i18nSource`), and writes translations back by
assigning `node.nodeValue`. A `MutationObserver` re-runs the whole pass on every
`childList` mutation anywhere in the document.

React reuses text nodes across renders and updates them in place. When React changes
a counter from `727` to `18`, the i18n pass still holds `727` in `_i18nSource` and
writes it back — **reverting React's update**. In English mode `translateString`
returns the cached source verbatim, so this happens with no translation involved at
all.

Reproduced on the Initiatives page. Searching for `cloud` correctly filters the table
(first row changes `#0001` → `#0028`), but the footer never updates:

```
                        rows  first row  footer
BASELINE                 15    #0001      "Showing 1–15 of 727 initiatives"
AFTER search "cloud"     15    #0028      "Showing 1–15 of 727 initiatives"   <- wrong
```

A/B against an otherwise identical build with only the observer disabled:

```
AFTER search "cloud"     15    #0028      "Showing 1–15 of 18 initiatives"    <- correct
```

Pagination is affected the same way — rows advance while the label stays put:

```
view 1: firstRow=#0001  footer="Showing 1–15 of 727 initiatives"
view 2: firstRow=#0016  footer="Showing 1–15 of 727 initiatives"
view 3: firstRow=#0031  footer="Showing 1–15 of 727 initiatives"
page indicator: "Page 1 of 49"   (frozen)
```

A user on page 3 of a filtered set sees page-3 data labelled as page 1 of an
unfiltered 727. In a portfolio-governance tool, numbers that silently lie are the
worst possible failure mode.

**Fix:** delete `localizeDom` and the observer. Translate at the source — pass
strings through the existing `t()` at render time, and use parameterised messages
(`t("showing", {from, to, total})`) rather than reassembling sentences from JSX
fragments. This also fixes H1b and M3 below.

### H1b — Interpolated strings translate incoherently **[verified]**

Same root cause. Because JSX splits `Showing {a}–{b} of {c} initiatives` into seven
separate text nodes, each is looked up independently. `"Showing"` is in the
dictionary; `" of "` is not. Actual rendered output in French mode:

```
"Affichage de 1–15 of 727 initiatives"
```

Half-translated sentences will appear anywhere text is interpolated.

### H2 — Working credentials compiled into the production bundle **[verified]**

`src/services/auth.js:1-21`

```js
const accounts = {
  "admin@stratex.com":  { password: "Admin@123",  role: "Admin"  },
  "viewer@stratex.com": { password: "Viewer@123", role: "Viewer" },
};
```

Confirmed present in the built artifact:

```
$ grep -o 'Admin@123\|Viewer@123\|demo-jwt-replace-with-keycloak-token' dist/assets/*.js | sort | uniq -c
   2 Admin@123
   2 Viewer@123
   1 demo-jwt-replace-with-keycloak-token
```

The README documents these as demo accounts and `auth.js` is explicitly flagged as an
MVP adapter, so the intent is understood. The risk is that `.openai/hosting.json` and
`scripts/prepare-sites.mjs` show this is wired for real static deployment, and nothing
prevents the demo adapter from going out. The placeholder token
`demo-jwt-replace-with-keycloak-token` is also sent as a real `Authorization: Bearer`
header by `src/services/api.js:9`.

**Fix:** move the demo adapter behind an explicit build flag that is off by default,
and fail the build if `import.meta.env.PROD` and the mock adapter are both active.

### H3 — Path traversal in the preview server **[verified]**

`scripts/preview.mjs:9-11`

```js
const pathname = req.url.split("?")[0] === "/" ? "index.html" : req.url.split("?")[0].slice(1);
const file = join(root.pathname, normalize(pathname));
```

`path.normalize()` does not strip leading `../` segments — it only collapses interior
ones. Demonstrated:

```
"/index.html"             -> /srv/app/dist/index.html
"/../../../etc/passwd"    -> /etc/passwd          <-- escapes the root
"/./../../etc/shadow"     -> /srv/etc/shadow      <-- escapes the root
```

Any HTTP client that does not pre-normalise the path (curl `--path-as-is`, or a raw
socket) reads arbitrary files as the server user. Mitigating: this script is not
referenced by any npm script — `package.json` maps `preview` to `vite preview` — so
it is dead code today. That also makes it easy to remove.

**Fix:** delete the file, or resolve the joined path and verify it starts with the
root directory before reading.

### H4 — Authorization decided entirely on the client

`src/pages/Dashboard.jsx:38`, `src/services/auth.js:23`

```js
const actionKeys = user.role === "Admin" ? [...six admin actions] : ["email","report"];
```

`user` comes from `JSON.parse(sessionStorage.getItem("stratex_user"))`. Editing one
`sessionStorage` value in devtools grants the full admin action set. This is
acceptable for a UI mock but must not survive contact with the real API — every one
of these actions needs server-side enforcement, and the client gating should be
treated as cosmetic only.

---

## Medium

### M1 — "Output format" on the Reports page is ignored **[verified]**

`src/pages/Reports.jsx:22-36, 46`

The user picks PDF / PowerPoint / Excel; `generate()` unconditionally builds a CSV,
names it `.csv`, and logs the history entry as `CSV`. Verified end-to-end:

```
selected Output format = PDF
downloaded file        = StratEx-Executive-strategy-summary-2026-07-28.csv
history entry          = "Executive strategy summary" / "Just now · CSV"
```

Either wire the formats up or disable the unimplemented options — silently
substituting the format is worse than not offering it.

### M2 — KPI card "•••" button navigates the card **[verified]**

`src/components/UI.jsx:8-13`

The card is `<article onClick={...} role="button">` with a nested `<button>` that has
no handler and no `stopPropagation`. Clicking the menu button navigates away:

```
click ••• inside first KPI card -> page heading becomes "Book of Work"
```

Nested interactive elements are also an accessibility violation (`role="button"`
containing a button). During testing the inner button was frequently unclickable
anyway — the `.kpi-icon` overlay intercepts pointer events.

### M3 — Per-mutation cost of the i18n observer **[verified]**

Every `childList` mutation triggers a full-document TreeWalker plus, in French, a
scan of all 247 dictionary entries sorted by length against each text node.

Measured on the Initiatives page (only 198 text nodes, 484 elements):
**~5.5 ms of main-thread work per DOM mutation.** This scales with
`textNodes × dictionarySize`, so it degrades as pages get richer. Resolved by the H1
fix.

### M4 — No `vite.config.js`; the React plugin never runs **[verified]**

`@vitejs/plugin-react` is declared as a dependency but there is no config file to
register it. The build still succeeds because Vite's default esbuild transform
handles `.jsx` with the classic runtime (every file imports React), but the plugin's
actual value — **React Fast Refresh** — is absent. Confirmed: the bundle contains no
refresh runtime.

```
$ grep -c 'RefreshRuntime\|@react-refresh\|jsxDEV' dist/assets/*.js
0
```

Every edit during development does a full page reload and loses component state.

### M5 — `npm run lint` is broken **[verified]**

The script is `eslint .`, but ESLint is not installed and there is no config file.

```
$ npm run lint; echo $?
... "From ESLint v9.0.0, the default configuration file is now eslint.config.js"
2
```

A lint script that has never run is worse than none — it implies a quality gate that
does not exist.

### M6 — Dependency classification is wrong

`package.json:12-20`. `vite`, `@vitejs/plugin-react`, and `typescript` are in
`dependencies` with `devDependencies` empty. `typescript` is listed despite zero `.ts`
/`.tsx` files in the project. Move build tooling to `devDependencies` and drop
TypeScript until it is actually used.

### M7 — No code splitting; oversized assets **[verified]**

```
dist/assets/index-lwX7eNiH.js   426.95 kB │ gzip: 104.99 kB   (single chunk)
dist/assets/strategy-network.png   1.67 MB                    (login background)
dist/assets/index-0ZBWilhH.css   79.78 kB │ gzip:  15.88 kB
```

`src/data/bowMasterData.js` is 142 KB of JSON inlined into the main chunk and eagerly
imported by three pages, so it loads before the login screen renders. The 1.67 MB PNG
is an unoptimised background on the login page — the heaviest asset in the app is on
the first screen an unauthenticated user sees. `React.lazy` per route, a fetched
dataset, and a WebP/AVIF conversion would cut first paint substantially.

### M8 — No error boundary; unguarded parse at boot

`src/main.jsx:11`, `src/services/auth.js:23`

`currentUser()` calls `JSON.parse` on `sessionStorage` with no try/catch, from a
`useState` initializer at the app root. Corrupt storage throws during the first
render with no boundary above it — the user gets a permanently blank page and no way
to recover short of clearing site data. Add a top-level error boundary and guard the
parse.

### M9 — The documented backend contract is unwired

`src/services/api.js` and `src/config/env.js` are imported by nothing (`api.js`
imports `env.js`; no other file imports either). Every page renders static mock data.
The README describes nine Spring Boot endpoints and a Keycloak integration that no
code path reaches. Either wire them or mark them clearly as a forward-looking
contract — right now the README overstates what the app does.

### M10 — Non-functional controls throughout

Help centre, Settings, Schedule report, Attach, Add cluster, New pillar, New
template, the Gantt navigation arrows, and every `•••` menu are rendered as live
buttons that do nothing. The Email centre's "Queue email" shows a success toast
without sending anything (`src/pages/Email.jsx:7`). For a stakeholder demo this is
reasonable; before any real user testing these should be visibly disabled, or they
will generate false bug reports and false confidence.

---

## Low

### L1 — Drag-and-drop will not work in Firefox, or on touch

`src/pages/Board.jsx:19`. `onDragStart` never calls
`event.dataTransfer.setData(...)`. Firefox requires drag data to be set for a drag to
initiate. There is also no touch fallback, so the execution board is unusable on
mobile — notable given the app is otherwise carefully responsive.

### L2 — Object URLs revoked before the download starts

`src/components/UI.jsx:29`, `src/pages/Reports.jsx:32`. `URL.revokeObjectURL(url)` is
called synchronously on the line after `a.click()`. This is a known-flaky pattern;
defer with `setTimeout(..., 0)` or `requestAnimationFrame`.

### L3 — Accessibility gaps

- `src/pages/Login.jsx:63,66` — `<label>` elements are not associated with their
  inputs (no `htmlFor`/`id`), so screen readers announce the fields unlabelled.
- `src/components/UI.jsx:39-52` and `src/ui/UIContext.jsx:40-50` — modals have no
  focus trap, no initial focus, and no focus restore on close.
- `src/components/UI.jsx:8` and `src/pages/Initiatives.jsx:55` — `Space` activates
  the handler without `preventDefault()`, so the page scrolls at the same time.
- `src/pages/Initiatives.jsx:55` — `<tr tabIndex="0" onClick>` with no `role`.
- `src/pages/Login.jsx:67` — the validation error is not `role="alert"` and is not
  linked to the inputs via `aria-describedby`.

### L4 — Dead code

- `src/i18n/LanguageContext.jsx:264-268` — queries `[data-i18n-source]`, which nothing
  ever sets (the code writes `i18nManaged`), then assigns to `nodeValue` on Elements,
  where it is always `null`. The block is inert.
- `src/i18n/LanguageContext.jsx:274` — `node.dataset` on a Text node is always
  `undefined`, so the guard always passes and every parent element is tagged on every
  pass.
- `src/pages/Initiatives.jsx:7` — `clean()` repairs mojibake (`â€“` → `–`); the
  dataset contains zero such sequences (verified), so it runs on every cell for
  nothing.
- `src/pages/PortfolioHealth.jsx:16` — `rows` is computed, then line 35 re-derives the
  same conditional chain inline and only falls through to it.
- `scripts/preview.mjs` — unreferenced (see H3).

### L5 — Session/page persistence mismatch

`src/App.jsx:21` stores the current page in `localStorage` while the user lives in
`sessionStorage`. After a browser restart the user is logged out but the app restores
their last page behind the login screen. Use one storage tier for both.

### L6 — Hardcoded values that will drift

`src/App.jsx:97` hardcodes the sidebar badge `727` rather than reading
`MASTER.length`. `src/pages/Directory.jsx:9` uses positional parallel arrays
(`[6,5,4,7][i]`, `[18,14,11,16][i]`) keyed to pillar order — reordering `pillars`
silently corrupts the display. `src/pages/Dashboard.jsx:47-50` hardcodes KPI values
(24, 72%, 68%, $18.6m) that contradict the 727-record dataset shown elsewhere.

### L7 — Modal/dialog promise can be dropped

`src/ui/UIContext.jsx:26-29`. If `confirm()` is called while a dialog is open, the
first promise's `resolve` is overwritten and never settles, leaving its `await`
pending forever. Not currently reachable — the backdrop blocks interaction — but it
is a latent trap for anyone adding a programmatic confirm.

### L8 — Export-to-PDF escaping is incomplete

`src/components/UI.jsx:31-35`. Row values are escaped for `&` and `<`, which is
adequate for text content, but `filename` and column titles are interpolated
unescaped into `<title>`, `<h1>`, and `<th>`. Both are developer-supplied today, so
this is hardening rather than a live vulnerability. The `window.open` +
`document.write` approach is also popup-blocker sensitive with no fallback.

### L9 — No tests, no CI

There is no test file, test runner, or CI workflow in the repository. Given that H1
is a silent data-correctness bug that a single assertion on the pagination footer
would have caught, this is the gap most worth closing.

---

## Suggested order of work

1. **H1** — remove the DOM-rewriting i18n layer; translate at render via `t()`.
   Fixes H1b and M3 at the same time. Largest correctness win.
2. **H2 / H4** — gate the mock auth adapter out of production builds; treat role
   checks as cosmetic pending server enforcement.
3. **H3** — delete `scripts/preview.mjs`.
4. **M4 / M5 / M6** — add `vite.config.js` with the React plugin, add an
   `eslint.config.js`, fix dependency classification. Cheap, unblocks everything else.
5. **M1 / M2 / M10** — make controls honest: implement, or disable visibly.
6. **M8 / L9** — error boundary, then a smoke test over the counters that H1 broke.
7. **M7** — route-level `React.lazy`, fetch the dataset, compress the login image.

---

## Verification notes

Reproduced against a clean `npm install` + `npm run build` (Vite 6.4.3, 1589 modules,
built in 4.3 s), served from `dist/` and driven with Playwright on Chromium 1194.
The A/B for H1 differed from the original only in that
`src/i18n/LanguageContext.jsx:311-316` was replaced with
`document.documentElement.lang = language;`. All other behaviour was left intact, and
the original file was restored afterwards.
