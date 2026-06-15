# OpenObserve Data Sources UI — AI integration cards

What the OpenObserve **Data Sources** panel renders for each AI integration.
One folder per integration; each contains a single `data-source-ui.md` whose
**YAML frontmatter IS the card** — provider hero, ordered setup steps (each with
its own code block + copy/reveal/`.env` chrome), live span detection, and the
supplementary accordions. The frontend is a thin renderer; adding or editing a
card is markdown-only, no frontend change.

> 📖 **Authoring a card? Read [AUTHORING.md](AUTHORING.md).** It covers the full
> architecture (why it's built this way), the content→UI fetch pipeline, the
> complete frontmatter field reference, and step-by-step instructions with a
> copy-paste skeleton. This README is just the index + `manifest.json` reference.

The actual installer scripts that these cards point to are handed off
separately (see the corresponding PR to `openobserve/o2-datasource`).

## Cards in this drop

### Frameworks / SDKs (paste-this Python snippet)

| Folder | Display name | Category |
|---|---|---|
| [openai/](openai/data-source-ui.md) | OpenAI | AI / Providers |
| [anthropic/](anthropic/data-source-ui.md) | Anthropic | AI / Providers |
| [gemini/](gemini/data-source-ui.md) | Google Gemini | AI / Providers |
| [langchain/](langchain/data-source-ui.md) | LangChain / LangGraph | AI / Frameworks |
| [crewai/](crewai/data-source-ui.md) | CrewAI | AI / Frameworks |
| [google-adk/](google-adk/data-source-ui.md) | Google ADK | AI / Frameworks |
| [openai-agents/](openai-agents/data-source-ui.md) | OpenAI Agents SDK | AI / Frameworks |
| [openrouter/](openrouter/data-source-ui.md) | OpenRouter | AI / Gateways |
| [litellm/](litellm/data-source-ui.md) | LiteLLM | AI / Gateways |
| [claude-agent-sdk/](claude-agent-sdk/data-source-ui.md) | Claude Agent SDK | AI / SDKs |

### CLI agents (paste-this install command)

| Folder | Display name | Category |
|---|---|---|
| [claude-code/](claude-code/data-source-ui.md) | Claude Code | AI / Agents |
| [codex/](codex/data-source-ui.md) | OpenAI Codex CLI | AI / Agents |
| [opencode/](opencode/data-source-ui.md) | OpenCode | AI / Agents |
| [cursor/](cursor/data-source-ui.md) | Cursor | AI / Agents |

## Card shape

Every card is a `data-source-ui.md` whose YAML frontmatter declares the whole
card. An integration gets the rich, stepped card iff its frontmatter has BOTH a
`card:` block and a `detect:` block; otherwise the panel falls back to a plain
markdown card. The frontmatter maps 1:1 to the rendered UI (no prose parsing) —
the markdown body below it is just human-readable notes.

The blocks, in short: `card:` (hero) · `detect:` (live span detection) ·
`stream_input:` (optional stream-name field → install command `{stream}` +
detection) · `steps:` (ordered setup steps, each with a chip, code block, note,
pills) · `extras:` (installer package/env pills) · `fix_snippet` +
`troubleshooting` · `doc_url` / `slack_url`.

**See [AUTHORING.md](AUTHORING.md) for the full field reference and a copy-paste
skeleton.** `anthropic/data-source-ui.md` is the canonical example.

## Placeholders the panel must substitute

| Token | What | Example |
|---|---|---|
| `{url}` | OpenObserve base URL (no trailing slash) | `https://api.openobserve.ai` |
| `{org}` | OpenObserve org identifier | `default` |
| `{token}` | The full `Authorization` header value, **without** the leading `Basic ` (the snippet already adds it) | `bWVAZXhhbXBsZS5jb206bXktcGFzcw==` (placeholder) |

Token is the base64 of `email:password`. The placeholder above decodes to
`me@example.com:my-pass` — substitute your own creds at render time. The card
snippets all use `--token="Basic {token}"`, so passing the raw base64 value
is correct.

## Cards that need a "watch out" visual

Each of these warrants a small ⚠️ or callout in the panel chrome — they
have non-obvious behavior the snippet alone won't communicate:

- **crewai** — snippet order is `init → instrumentor` (reverse of every
  other framework card). Detail in [crewai/data-source-ui.md §2](crewai/data-source-ui.md).
- **codex** — emits logs + metrics, not traces. The card's verify section
  tells users to check the Logs view, not Traces, which the panel should
  reflect (different default tab after install).
- **cursor** — verification requires Mac + Cursor IDE open. The card calls
  this out; the panel might want a "macOS only" badge.

## `manifest.json` — integration index

`manifest.json` is the machine-readable index the panel reads to render the
sidebar tabs and integration cards. Each entry points at one of the folders
documented above.

### Category slugs

The `category` field on each entry controls which sidebar tab the integration
appears under:

| `category` slug   | Sidebar tab            | What belongs here                                                  |
|-------------------|------------------------|--------------------------------------------------------------------|
| `model-providers` | Model Providers        | Foundation model APIs (OpenAI, Anthropic, Google Gemini, …)        |
| `frameworks`      | AI Frameworks & Agents | Agent/LLM frameworks and SDKs (LangChain, CrewAI, OpenAI Agents, …)|
| `gateways`        | AI Gateways & Proxies  | Routing layers and LLM proxies (OpenRouter, LiteLLM, …)            |
| `no-code`         | No-Code Platforms      | Visual / no-code AI workflow builders                              |
| `analytics`       | Analytics & Evaluation | Evaluation, tracing, and observability tooling for LLMs            |
| `tools`           | Tools & Integrations   | General tools and miscellaneous integrations                       |
| `popular`         | Popular (only if used) | Curated highlight tab — only rendered when at least one entry uses it |

### Adding a new integration

1. Add the card folder + `data-source-ui.md` (see sections above).
2. Append a new object to the `integrations` array in `manifest.json`:

   ```json
   {
     "slug": "my-integration",
     "name": "My Integration",
     "category": "frameworks",
     "order": 15,
     "docURL": "https://openobserve.ai/docs/integration/ai/frameworks/my-integration/",
     "keywords": ["my", "integration", "framework"]
   }
   ```

3. Field reference:

   | Field      | Required | Notes                                                                |
   |------------|----------|----------------------------------------------------------------------|
   | `slug`     | yes      | URL-safe, lowercase, hyphenated. Must match the card folder name and be unique. |
   | `name`     | yes      | Display name shown in the UI card and tab.                           |
   | `category` | yes      | One of the slugs from the table above.                               |
   | `order`    | yes      | Sort order within the category (lower numbers appear first).         |
   | `docURL`   | yes      | Link to the published integration docs. Leave as `""` if not yet live. |
   | `keywords` | yes      | Search keywords; include common aliases and synonyms.                |

4. Keep `order` values unique within a category to avoid ambiguous sorting.
5. Validate that the JSON parses (e.g. `python -m json.tool manifest.json`) before committing.

## Feedback loop

Each card's "Reference link" section also lists doc deltas the panel team
should pipe back to `openobserve-docs`. Most cards have 0–1 deltas;
langchain and crewai have several.
