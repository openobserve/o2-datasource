# Anthropic — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Anthropic** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | Anthropic |
| Category | AI / Providers |
| Icon | `anthropic.svg` |
| Tagline | Trace every Claude API call from your Python app |
| Supported runtime | Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=anthropic \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**Substitutions:** `{url}`, `{org}`, `{token}` (Base64-encoded `email:password`)
— same fields as every other framework card.

**What this does:** installs `openobserve-telemetry-sdk`,
`opentelemetry-instrumentation-anthropic`, `anthropic`, `python-dotenv` via
pip; verifies imports; writes the `OPENOBSERVE_*` keys to `.env`. Idempotent.

## Section 2 — Paste this into your app

```python
from opentelemetry.instrumentation.anthropic import AnthropicInstrumentor
from openobserve import openobserve_init

AnthropicInstrumentor().instrument()
openobserve_init()
```

> Four lines at the top of your app entrypoint, **before** importing the
> Anthropic client.

Sync, async, streaming, system prompts — all instrumented automatically.

## Section 3 — Verify

> Make any Claude API call (e.g. `client.messages.create(...)`).

Open Traces, filter `gen_ai_system = Anthropic`. Each call appears as a span
with `gen_ai.request.model`, `gen_ai.usage.input_tokens`,
`gen_ai.usage.output_tokens`, `gen_ai.usage.cache_creation_input_tokens`,
`gen_ai.usage.cache_read_input_tokens`, `llm.usage.cost_total`.

Link/button: "Open Traces filtered by `gen_ai_system=Anthropic`".

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| App runs but no Claude spans | Move the four lines above any `from anthropic import ...` |
| `pip` complains about externally-managed environment | Installer auto-retries with `--break-system-packages --user` |
| Auth errors in OpenObserve logs | Token must be `Basic <base64>` or `Bearer <token>` |
| Streaming responses missing | The span closes when the stream is fully consumed — make sure your loop reads to completion |

---

## Panel implementation notes

- Same template engine and copy-button behavior as the OpenAI card. The only
  field-level differences vs OpenAI are the display name, icon, tagline, and
  the integration slug (`anthropic` instead of `openai`).
- One copy button per code block; copy-the-substituted-form, not the
  `{url}/{org}/{token}` literals.
- The OpenAI provider card and Anthropic provider card can co-exist in the
  same project — they install different instrumentor packages and don't
  collide.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/providers/anthropic.md](../../openobserve-docs/docs/integration/ai/providers/anthropic.md)
