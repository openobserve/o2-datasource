# OpenAI — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → OpenAI** panel should render.

The panel is responsible for substituting the user's `{url}`, `{org}`, and
`{token}` (Base64-encoded) into the templates below. Everything else is
static markup.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | OpenAI |
| Category | AI / Providers |
| Icon | `openai.svg` (existing in docs assets) |
| Tagline | Trace every OpenAI Python SDK call |
| Supported runtime | Python 3.9+ |

## Section 1 — Install

> Install the OpenObserve telemetry SDK and the OpenAI instrumentor with one command.

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=openai \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**Substitutions**
- `{url}` — the user's OpenObserve base URL (e.g. `https://api.openobserve.ai`)
- `{org}` — the user's organization ID
- `{token}` — Base64-encoded `email:password` (the panel already computes
  this — same value used for ingest tokens elsewhere)

**What this does** (collapsible "Details" section in the panel):

1. Installs `openobserve-telemetry-sdk`, `opentelemetry-instrumentation-openai`,
   `openai`, `python-dotenv` via `pip install --user --upgrade`.
2. Verifies the imports work.
3. Writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, `OPENOBSERVE_AUTH_TOKEN` to
   `./.env` (preserves existing keys, backs up first).
4. Prints the 4-line Python snippet (shown below) to paste into the app.

Idempotent — re-running with new values updates env vars in place, no
duplicates.

## Section 2 — Paste this into your app

> Add these four lines at the top of your app entrypoint, **before** importing
> the OpenAI client.

```python
from opentelemetry.instrumentation.openai import OpenAIInstrumentor
from openobserve import openobserve_init

OpenAIInstrumentor().instrument()
openobserve_init()
```

That's it. Every OpenAI call (`client.chat.completions.create(...)`,
`client.embeddings.create(...)`, async variants, streaming, etc.) now
produces an OpenTelemetry span shipped to your OpenObserve instance.

## Section 3 — Verify

> Run any OpenAI call from your app, then check Traces.

**In the UI**, link/button: "Open Traces filtered by `gen_ai_system=openai`".
Target URL pattern:

```
/web/traces?org_identifier={org}&stream={stream}&query=gen_ai_system%3D%27openai%27
```

(Use whatever the current OpenObserve UI route convention is.)

**What the user should see:** spans named `openai.chat` (or
`openai.embeddings`, etc.) with attributes including `gen_ai.request.model`,
`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
`llm.usage.cost_total`, and the request/response text.

## Section 4 — Uninstall

Not yet wired (no `uninstall.sh` for frameworks). To remove: delete the four
lines from the app and remove the `OPENOBSERVE_*` lines from `.env`. The
panel can show this as a small "How do I remove this?" link expanding to
those instructions.

## Section 5 — Troubleshooting (collapsible at the bottom)

| Symptom | Cause | Fix |
|---|---|---|
| Installer exits with "Python 3.9+ not found" | No `python3` on PATH | Install Python 3.9+ |
| `pip install` complains "externally-managed-environment" | PEP 668 (Homebrew Python / Debian) | Installer auto-retries with `--break-system-packages --user` — re-run if you cancelled |
| App runs but no traces appear | Instrumentor called *after* importing OpenAI | Move the four lines to the very top, before `from openai import ...` |
| Auth errors in app logs | Wrong token format | Token must be `Basic <base64>` or `Bearer <token>` |

---

## Panel implementation notes

- **Required user context:** the panel must already have `user.openobserve_url`,
  `user.org_id`, `user.token_base64` available. These are the same fields the
  existing ingest-token UI already uses.
- **Copy-to-clipboard:** the install command block and the paste-this snippet
  should each have their own copy button. Copying the install command should
  copy the substituted, runnable command — not the literal `{url}` template.
- **Per-OS code-block rendering:** the install command is single-line bash;
  works on macOS, Linux, and WSL/Git Bash on Windows without modification.
  Optionally show a Windows PowerShell tab with the equivalent
  `iwr -useb ... | iex` form (not built yet — flag as future work).
- **State indicator:** if the panel can detect that the user has already run
  the installer (e.g. by checking whether traces with `gen_ai_system=openai`
  have arrived in the last 24h), show a green "Configured" badge instead of
  the install command.

## Reference link

Full integration docs (existing in `openobserve-docs`):
[openobserve-docs/docs/integration/ai/providers/openai.md](../../openobserve-docs/docs/integration/ai/providers/openai.md)
