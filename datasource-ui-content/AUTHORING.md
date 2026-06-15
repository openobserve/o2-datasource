# Authoring AI Data Source Cards

> One document, start to finish: what the AI integration cards are, how the
> system is wired, why it's built this way, and exactly how to write or edit a
> card's `data-source-ui.md`.

This repo (`datasource-ui-content`) is the **single source of truth** for the
rich, stepped setup cards that OpenObserve renders on the **Data Sources → AI
Integrations** page. Each integration is one folder with one
`data-source-ui.md`. The YAML frontmatter at the top of that file **is** the
card — the OpenObserve frontend is a thin renderer that reads the frontmatter
and draws the UI. No frontend code change is needed to add or edit a card.

---

## 1. The big picture

```
  datasource-ui-content (THIS repo)            openobserve/web (frontend)
  ┌───────────────────────────┐   build/dev    ┌──────────────────────────────┐
  │ anthropic/data-source-ui.md│ ─────fetch───▶ │ generated/anthropic/…md       │
  │ openai/data-source-ui.md   │   (git clone)  │ generated/openai/…md          │
  │ …14 folders                │                │ …                             │
  │ manifest.json              │                │ generated/manifest.json       │
  └───────────────────────────┘                └──────────────┬───────────────┘
                                                               │ import.meta.glob
                                                               ▼
                                          parseFrontmatter → buildFromMarkdown
                                                               │
                                                               ▼
                                            <AIRichSetupCard>  (renders the card)
```

Two repos, one direction of flow:

- **`datasource-ui-content`** (this repo) — content authors live here. Edit
  markdown, open a PR. Nothing else.
- **`openobserve` / `web`** — the renderer. At build time (and dev startup) it
  shallow-clones this repo and copies every `data-source-ui.md` +
  `manifest.json` into `web/src/assets/ai-datasource-content/generated/`. Vite
  bundles that folder via `import.meta.glob`. The card UI is built entirely from
  the frontmatter — see §6.

### Why it's built this way

- **Content/code separation.** Marketing/DevRel can ship a new provider card or
  fix a command by editing markdown and opening a PR here — no frontend release,
  no TypeScript.
- **Frontmatter IS the card (no prose parsing).** We deliberately do **not**
  parse markdown prose to reconstruct the card. The whole card is declared as
  structured YAML and maps 1:1 to the rendered component. This avoids a fragile
  "parse English back into fields" step. The markdown body below the frontmatter
  is just human-readable notes / docs — the renderer ignores it for rich cards.
- **The content owns the contract.** The install command and the live-detection
  config (`detect.stream` / `detect.filter`) are authored **in the same file**,
  so the thing the installer writes to and the thing the card listens for can
  never drift apart in code — they drift together in one md, reviewed together.

---

## 2. How content reaches the UI (the fetch pipeline)

The fetcher is `web/scripts/fetch-datasource-content.mjs`, wired into
`web/vite.config.ts`.

- It shallow-clones `DS_CONTENT_REPO` @ `DS_CONTENT_REF` (default
  `openobserve/o2-datasource` @ `main`, subdir `datasource-ui-content`) and
  copies each `<slug>/data-source-ui.md` + `manifest.json` into `generated/`.
- `generated/` is **gitignored** in the web repo — it's build output, not source.
- It **skips** the fetch if `generated/` already exists, unless
  `DS_CONTENT_FORCE=1`.
- Builds/CI set `DS_CONTENT_STRICT=1` → a failed fetch fails the build loudly.
  The dev server is lenient → keeps cached `generated/`, else the UI falls back
  to the plain card.

> ⚠️ **The gotcha that bites most often.** Because the default ref is `main`, a
> fresh fetch pulls whatever is **merged** on `main`. If your card changes are
> only on a branch / open PR in this repo, a re-fetch will **overwrite**
> `generated/` with the older `main` version and the rich layout silently
> disappears (the card has no `detect:` frontmatter → falls back to the plain
> markdown card). Until your content PR is merged, work against a local copy:
>
> ```bash
> # from the openobserve web repo — refresh generated/ from your local content checkout
> SRC=/path/to/datasource-ui-content
> DST=web/src/assets/ai-datasource-content/generated
> for d in "$SRC"/*/; do
>   slug=$(basename "$d")
>   [ -f "$d/data-source-ui.md" ] && cp "$d/data-source-ui.md" "$DST/$slug/data-source-ui.md"
> done
> ```
>
> Or point the fetcher at your branch: `DS_CONTENT_REF=<branch> DS_CONTENT_FORCE=1 node scripts/fetch-datasource-content.mjs`.

---

## 3. What a card looks like (the rendered UI)

A rich card renders, top to bottom:

1. **Hero** — logo (or a lettered monogram fallback) + provider name, a tagline,
   and small chips for `runtime` / `setup_time`.
2. **Numbered steps** — each step has a title, a short description (inline
   `**bold**` / `` `code` `` supported), an optional context **chip**
   (Terminal / editor filename / Run / Traces), an optional **code block** with
   copy + reveal-token + `.env`-download chrome, an optional muted **note**, and
   optional monospace **pills**.
   - Copying a step's code flips its badge to a green check and auto-scrolls to
     the next step.
   - One step is the **detection anchor** — it hosts the live status bar.
3. **Live status bar** (on the anchor step) — `Start` begins listening; the card
   polls OpenObserve for the provider's first span and flips to **Connected**
   (with a "View Traces" CTA) or **Stalled** (with a "most likely fix" box +
   Recheck). Detection only ever starts on the **Start** click.
4. **Accordions** — "What the installer does" (package + env-var pills),
   troubleshooting Q&A.
5. **Footer** — docs link + "Ask on Slack".

What gates the rich card vs. the plain card: an integration gets the rich card
**iff** its frontmatter has BOTH a `card:` block AND a `detect:` block
(`registry.ts` → `hasRichCard`). Otherwise the page renders the plain markdown
card from the body.

---

## 4. Quick start — add a new card in 5 steps

1. **Create the folder + file**: `mkdir <slug> && touch <slug>/data-source-ui.md`
   (`<slug>` is lowercase-kebab, e.g. `langchain`, `claude-code`).
2. **Add the frontmatter** — copy the skeleton in §5, fill in `card:`,
   `detect:`, `steps:`, and `extras:`.
3. **Register it in `manifest.json`** — add an entry (slug, name, category,
   order, docURL, keywords; optional `logo`). This controls the sidebar menu and
   ordering. A card with no manifest entry won't appear in the menu.
4. **Preview locally** — copy your file into the web repo's `generated/<slug>/`
   (see the gotcha box in §2), run `cd web && npm run dev`, open Data Sources →
   AI Integrations → your provider.
5. **Open a PR** in this repo. Once merged to `main`, the next web build picks it
   up automatically.

---

## 5. Frontmatter skeleton (copy this)

```yaml
---
# <slug>/data-source-ui.md
card:
  name: My Provider                 # hero title
  tagline: One line on what gets traced.
  runtime: Python 3.9+              # optional chip
  setup_time: ~2 min               # optional chip
  tone: "#d97757"                  # optional brand accent (reserved)
  # logo: https://…/logo.svg       # optional; see §7

detect:
  stream_type: traces              # traces | logs
  stream: default                  # fallback stream; overridden by stream_input
  filter: "LOWER(gen_ai_system) = 'myprovider'"   # SQL WHERE fragment, see §8
  model_label: my-model-name       # optional; shown in the "Connected" line
  # poll_ms: 3000                  # optional, default 3000
  # timeout_ms: 60000              # optional, default 60000 → "stalled"

# Optional. When present, the card renders a stream-name text field; its value
# flows BOTH into the install command's {stream} placeholder AND the live
# detection, so the stream the installer writes to and the stream the card
# listens on always match. Omit this block to hide the input. See §8.
stream_input:
  label: Traces Stream Name
  default: default                 # used when the field is left blank
  placeholder: default
  help: Leave as "default" or set a dedicated stream for these traces.

doc_url: https://openobserve.ai/docs/…
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command installs the SDK and writes your `.env`. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      download_env: true           # show a ".env" download button
      text: |
        curl -fsSL https://…/setup.sh | bash -s -- \
          --integration=myprovider \
          --url={url} \
          --org={org} \
          --traces-stream={stream} \   # {stream} ← the stream_input value (§8)
          --token="Basic {token}"

  - title: Add These Lines To Your App
    description: "Required — spans only flow once your app is instrumented."
    chip: { kind: editor, label: main.py }
    required: true                 # renders a "Required" marker
    complete_on: copy
    note: "load_dotenv() is required — init reads env vars, not .env directly."
    code:
      lang: python
      filename: main.py            # shown in the editor-chrome tab
      text: |
        from dotenv import load_dotenv
        load_dotenv()
        # … instrument BEFORE importing the client …

  - title: Run Your App
    description: "Make any call:"
    chip: { kind: run, label: Run }
    complete_on: detect            # completes when a span is detected
    detection_anchor: true         # ← the live status bar lives on this step
    code:
      lang: python
      text: |
        client.messages.create(model="my-model", messages=[…])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `gen_ai_system = MyProvider`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:                         # monospace attribute chips
      - gen_ai.request.model
      - gen_ai.usage.input_tokens

extras:
  installs:                        # package pills in "What the installer does"
    - openobserve-telemetry-sdk
    - my-instrumentor
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_snippet: |                     # shown in the "most likely fix" box when stalled
  # instrument FIRST — before the client is imported
  MyInstrumentor().instrument()
  openobserve_init()

troubleshooting:
  - q: App runs but no spans appear
    a: "Move the init lines above any client import."
---

# My Provider

Human-readable notes go here. The renderer ignores this body for rich cards;
it's for people reading the file on GitHub.
```

See `anthropic/data-source-ui.md` for the canonical, fully-filled example.

---

## 6. Field reference

Every field below is parsed in `web/.../richCard/buildFromMarkdown.ts` and typed
in `richCard/types.ts`. **`card:` and `detect:` are both required** to get the
rich card; everything else is optional.

### `card:` — hero
| Key | Type | Notes |
|---|---|---|
| `name` | string | Hero title. Defaults to the slug. |
| `tagline` | string | One-line subtitle. |
| `runtime` | string | Optional chip (e.g. `Python 3.9+`, `CLI agent`). |
| `setup_time` | string | Optional chip (e.g. `~2 min`). |
| `tone` | string (hex) | Brand accent; reserved for future theming (the live UI uses the app theme color, not this). |
| `logo` | string (URL) | Optional logo. See §7. |

### `detect:` — live "listening for the first span"
| Key | Type | Notes |
|---|---|---|
| `stream_type` | `traces` \| `logs` | Stream type to query. |
| `stream` | string | Fallback stream. When `stream_input` is present, the card's input value overrides this at runtime. Defaults to `default`. |
| `filter` | string (SQL) | `WHERE` fragment that identifies this provider's spans. See §8. |
| `model_label` | string | Optional; shown in the "Connected" status line. |
| `poll_ms` | number | Poll cadence; default `3000`. |
| `timeout_ms` | number | Give up → "stalled"; default `60000`. |

### `stream_input:` — optional user-set stream name
Present → the card renders a text field; the value drives the install command's
`{stream}` placeholder **and** the detection stream together (§8). Omit → no input.
| Key | Type | Notes |
|---|---|---|
| `label` | string | Field label, e.g. `Traces Stream Name`. |
| `default` | string | Used when the field is left blank (typically `default`). |
| `placeholder` | string | Optional; falls back to `default`. |
| `help` | string | Optional helper text under the field. |

### `steps:` — ordered list
| Key | Type | Notes |
|---|---|---|
| `title` | string | Step heading. |
| `description` | string | Inline markdown — only `**bold**` and `` `code` `` are rendered. |
| `chip` | `{ kind, label }` | `kind`: `terminal` \| `editor` \| `run` \| `traces`. Drives the chip + code-block chrome. |
| `complete_on` | `copy` \| `detect` | `copy` → done when copied; `detect` → done when a span lands. |
| `required` | bool | Renders a "Required" marker (use for the instrumentation step). |
| `detection_anchor` | bool | Put the live status bar on this step. **Exactly one** step should set this. |
| `code` | object | See below. Omit for text-only steps. |
| `note` | string | Muted caveat under the code. |
| `pills` | string[] | Monospace attribute chips after the description. |
| `id` | string | Optional stable id (scroll target). Auto-generated as `<slug>-<n>` if omitted. |

### `code:` (inside a step)
| Key | Type | Notes |
|---|---|---|
| `lang` | string | Highlight language (`bash`, `python`, …). |
| `text` | string (block) | The code. Use `text: \|` for multi-line. Carries placeholders (§9). |
| `filename` | string | Shown in the editor-chrome tab. |
| `download_env` | bool | Adds a ".env" download button to the toolbar. |

### top-level extras
| Key | Type | Notes |
|---|---|---|
| `extras.installs` | string[] | Package pills. |
| `extras.env_vars` | string[] | Env-var pills. |
| `fix_snippet` | string (block) | Shown in the "most likely fix" box when detection stalls. |
| `troubleshooting` | `{ q, a }[]` | Accordion Q&A. |
| `doc_url` | string | Footer docs link. |
| `slack_url` | string | Footer Slack link. |

---

## 7. Logos

A logo can come from two places, resolved in this order at render time:

1. **`manifest.json` entry** — add `"logo": "https://…"` to the integration's
   entry. Used for BOTH the sidebar menu icon and the card hero.
2. **`card.logo`** in the frontmatter — used for the card hero.
3. **Fallback** — if neither is set (or the image fails to load), a lettered
   **monogram** tile in the app theme color is shown. This is the default for
   every card today; no bundled provider logos.

Prefer the manifest entry so the menu and card stay consistent. URLs should be
stable, CORS-friendly, and ideally an SVG/transparent PNG.

---

## 8. Writing the `detect.filter` (important)

The filter is a raw SQL `WHERE` fragment counted over `detect.stream`. The card
polls `SELECT COUNT(*) … WHERE (<filter>) AND _timestamp >= <listen-window>` and
flips to "Connected" on the first non-zero count.

Rules of thumb:

- **Match what's actually stored.** Span attributes are often lowercased on
  ingest. Anthropic spans store `gen_ai_system = 'anthropic'` (lowercase), so the
  filter uses `LOWER(gen_ai_system) = 'anthropic'` to be safe.
- **CLI agents / gateways** may not set `gen_ai_system`; use whatever they emit
  (e.g. `service_name = 'cursor'`). Mark best-effort filters with a
  `# best-effort; confirm on ingest` comment until verified against real data.
- **Confirm before trusting.** Send one real call, open Traces, and read the
  actual attribute name/value before finalizing. A wrong filter just means the
  card never flips to "Connected" — it won't error.
- **Let the user pick the stream (recommended).** The installers now accept
  `--traces-stream=NAME` / `--logs-stream=NAME`. To expose this, add a
  `stream_input` block (§5/§6) and put the matching flag in the install command
  with the `{stream}` placeholder:

  ```yaml
  stream_input:
    label: Traces Stream Name
    default: default
  steps:
    - code:
        text: |
          curl … | bash -s -- \
            --org={org} \
            --traces-stream={stream} \   # codex (logs) → --logs-stream={stream}
            --token="Basic {token}"
  ```

  The card renders a text field; whatever the user types (or `default` if blank)
  is substituted into `{stream}` in the command **and** used as the stream the
  card listens on — so `detect.stream` becomes just a fallback. This is how all
  14 current cards work.

---

## 9. Token / org / URL placeholders

Code blocks use three placeholders, substituted per-org by the frontend at
render time (`richCard/subs.ts`):

| Placeholder | Replaced with | When |
|---|---|---|
| `{url}` | the org's OpenObserve ingestion URL | at render (static) |
| `{org}` | the org identifier | at render (static) |
| `{token}` | the org's ingestion auth token (base64) | at render (static) |
| `{stream}` | the `stream_input` field value (or its `default`) | live, as the user types (§8) |

If a code block contains `{token}`, the card automatically renders a **masked**
variant (token shown as dots) by default with a reveal toggle; **copy always
copies the real token**. Author the literal `{token}` — don't paste a real one.

`{stream}` only resolves if the card has a `stream_input` block; otherwise it
stays literal, so only use it together with `stream_input` (§8).

---

## 10. Common pitfalls

- **Rich layout not showing / reverted to a plain card.** Almost always the
  fetch gotcha in §2 — `generated/` was overwritten from `main` and your changes
  aren't merged yet. Re-copy from your local checkout, or merge the content PR.
- **Frontmatter not parsing.** The opening delimiter must be exactly `---` on
  line 1 (a stray character like `de---` silently disables the whole card — the
  parser treats it as a plain card with no frontmatter). YAML is
  whitespace-sensitive: 2-space indent, quote strings containing `:` or `#`.
- **Card shows but the status bar never connects.** Wrong `detect.filter` or
  `detect.stream` — see §8.
- **Multiple status bars / none.** Set `detection_anchor: true` on exactly one
  step (typically the "Run Your App" step).
- **YAML colons in values.** Wrap taglines/descriptions containing `:` in
  quotes: `tagline: "Trace calls: tools, prompts."`.

---

## 11. The 14 current cards

`anthropic` · `openai` · `gemini` · `claude-code` · `codex` · `cursor` ·
`opencode` · `langchain` · `crewai` · `google-adk` · `openai-agents` ·
`claude-agent-sdk` · `litellm` · `openrouter`

Categories and ordering live in `manifest.json`. `anthropic` is the canonical
reference — read it alongside this doc when authoring a new card.
