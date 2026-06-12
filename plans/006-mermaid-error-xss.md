# Plan 006: Stop interpolating Mermaid render errors into innerHTML (XSS)

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- www/src/components/chat/Mermaid.tsx` — mismatch vs the excerpt below = STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`Mermaid.tsx` renders a diagram by calling `mermaid.render()` and injecting the resulting SVG via `dangerouslySetInnerHTML`. That's fine for the *success* path (mermaid runs with `securityLevel: "strict"`). But the **error** path interpolates the raw error string into the same innerHTML: `setSvg(\`<pre…>${String(err)}</pre>\`)`. Mermaid's parse/render errors can echo fragments of the diagram source, so a crafted mermaid block can place attacker-influenced text into an HTML sink. In this app, wiki pages render through `WikiMarkdown` → `Mermaid`, and wiki content can come from **imported corpora** (e.g. the agentwiki/devrel-almanac markdown imports), not just the operator's own typing — so a malicious ```mermaid block in imported content is a realistic injection vector. The fix is tiny: render the error as React text (auto-escaped), never as HTML.

## Current state

`www/src/components/chat/Mermaid.tsx` (verified, 882865b) — relevant lines:

```ts
const [svg, setSvg] = React.useState<string>("");
…
React.useEffect(() => {
  let cancelled = false;
  (async () => {
    try {
      const mod = await import("mermaid");
      const mermaid = mod.default ?? mod;
      …
      const result = await mermaid.render(id, content);
      if (!cancelled) setSvg(result.svg);
    } catch (err) {
      if (!cancelled) setSvg(`<pre class="font-mono text-xs">${String(err)}</pre>`);  // <-- line 38: raw err into HTML
    }
  })();
  return () => { cancelled = true; };
}, [content]);
…
<div dangerouslySetInnerHTML={{ __html: svg }} />   // <-- line 91: sink
<pre className="sr-only whitespace-pre-wrap">{content}</pre>
```

The success SVG from `mermaid.render` (with `securityLevel: "strict"`) is trusted output and may keep using `dangerouslySetInnerHTML`. Only the error branch is the problem.

This component is shared (chat + wiki). It is **outside** `components/wiki/` but reachable from wiki content via `WikiMarkdown.tsx` (which renders ```mermaid fences through it).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Typecheck | `cd www && npm run typecheck` | exit 0 |
| Tests | `cd www && npm test` | all pass |
| Build | `cd www && npm run build` | `✓ built` |
| New test | `cd www && npx vitest run src/components/chat/Mermaid.test.tsx` | pass |

## Scope

**In scope**:
- `www/src/components/chat/Mermaid.tsx` (the error-rendering fix)
- `www/src/components/chat/Mermaid.test.tsx` (create)

**Out of scope** (do NOT touch):
- The success path / `mermaid.initialize` options (already `securityLevel: "strict"`).
- Any other use of `dangerouslySetInnerHTML` in the repo.
- `WikiMarkdown.tsx` and the markdown pipeline.

## Git workflow

- Branch: `advisor/006-mermaid-error-xss`
- Commit style: `fix(security): render mermaid errors as text, not HTML`
- No push/PR unless instructed.

## Steps

### Step 1: Separate error state from SVG state

Introduce a distinct error string state and render it as a React text node (which React escapes) instead of folding it into the `svg` HTML string. Target shape:

```ts
const [svg, setSvg] = React.useState<string>("");
const [error, setError] = React.useState<string | null>(null);
…
try {
  const result = await mermaid.render(id, content);
  if (!cancelled) { setSvg(result.svg); setError(null); }
} catch (err) {
  if (!cancelled) { setSvg(""); setError(String(err)); }
}
```

And in render:

```tsx
{error !== null ? (
  <pre className="font-mono text-xs whitespace-pre-wrap">{error}</pre>   // React escapes {error}
) : (
  <div dangerouslySetInnerHTML={{ __html: svg }} />
)}
```

Keep the `<pre className="sr-only …">{content}</pre>` accessibility line as-is.

**Verify**: `cd www && npm run typecheck` → exit 0; `cd www && npm run build` → `✓ built`.

### Step 2: Add a regression test

Create `www/src/components/chat/Mermaid.test.tsx`. Use `@testing-library/react` + jsdom. Mock the `mermaid` dynamic import so `render` throws an error whose message contains an HTML payload, e.g. `throw new Error('<img src=x onerror="alert(1)">')`. Render `<Mermaid content="bad" />`, wait for the effect, and assert:
- The error text is present as **text** (e.g. `screen.getByText(/img src=x/)` finds it), and
- there is **no** actual `<img>` element in the container (`container.querySelector("img")` is null) — proving the payload was escaped, not parsed.

Also add a success case: mock `render` to return `{ svg: "<svg><g/></svg>" }` and assert an `<svg>` is present (success path still uses innerHTML).

To mock the dynamic `import("mermaid")`, use `vi.mock("mermaid", () => ({ default: { initialize: vi.fn(), render: vi.fn()… } }))` — read `www/src/test/setup.ts` first to match the existing mocking conventions.

**Verify**: `cd www && npx vitest run src/components/chat/Mermaid.test.tsx` → pass (both cases).

### Step 3: Full suite

**Verify**: `cd www && npm test` → all pass.

## Test plan

- New `Mermaid.test.tsx`: error-payload-is-escaped (no `<img>` in DOM) + success-svg-renders.
- If a component test for Mermaid is hard to set up (dynamic import of mermaid), an acceptable alternative is to extract the error-rendering into a tiny pure helper and test that the error path produces a text node — but prefer the component test; only fall back if STOP-worthy.

## Done criteria

ALL must hold:
- [ ] `cd www && npm run typecheck` exits 0
- [ ] `cd www && npm test` exits 0; new Mermaid test passes
- [ ] `grep -n "dangerouslySetInnerHTML" www/src/components/chat/Mermaid.tsx` shows it used ONLY for the success `svg`, never for the error string
- [ ] The error branch sets a text state, not an HTML string (`grep -n "setError" www/src/components/chat/Mermaid.tsx` present; no `<pre…>${` template literal feeding `setSvg`)
- [ ] `cd www && npm run build` succeeds
- [ ] `plans/README.md` row updated

## STOP conditions

- Drift in the excerpt.
- Mocking the dynamic `import("mermaid")` proves intractable after a real attempt → extract the error-to-text decision into a pure helper, unit-test that, and report the component-test gap.
- You discover other `dangerouslySetInnerHTML` sinks fed by untrusted strings while here → do NOT fix them in this plan; report them as new findings.

## Maintenance notes

- Rule for this component: only trusted `mermaid.render` SVG output goes through `dangerouslySetInnerHTML`; everything else is React children (escaped).
- A reviewer should confirm the success SVG still renders and the error case shows readable (escaped) text.
- Broader follow-up (not this plan): audit the rest of the app for `dangerouslySetInnerHTML` / `innerHTML` fed by dynamic strings.
