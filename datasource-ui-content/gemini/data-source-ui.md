# Google Gemini — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Google Gemini** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | Google Gemini |
| Category | AI / Providers |
| Icon | `gemini.svg` |
| Tagline | Trace every Gemini API call from your Python app |
| Supported runtime | Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=gemini \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`opentelemetry-instrumentation-google-generativeai`, `google-genai`,
`python-dotenv` via pip; verifies imports; writes `OPENOBSERVE_*` keys to
`.env`.

**Note on package naming:** the instrumentor package is named after the older
`google-generativeai` SDK, but it also supports the newer `google-genai`
client (`from google import genai`). The installer pulls in the newer SDK
since that's what current docs / examples use.

## Section 2 — Paste this into your app

```python
from opentelemetry.instrumentation.google_generativeai import GoogleGenerativeAiInstrumentor
from openobserve import openobserve_init

GoogleGenerativeAiInstrumentor().instrument()
openobserve_init()
```

> Four lines at the top of your app entrypoint, **before** importing the
> Gemini SDK.

Works for single-turn `generate_content`, multi-turn chat (`chats.create()`
→ `send_message`), and streaming (`generate_content_stream`).

## Section 3 — Verify

> Make any Gemini call (e.g. `client.models.generate_content(...)`).

Open Traces, filter `gen_ai_system = Google`. Each call produces a span with
`gen_ai.request.model`, `gen_ai.usage.input_tokens`,
`gen_ai.usage.output_tokens`. For Gemini 2.5 reasoning models, total tokens
include thinking tokens — visible in `llm_usage_tokens_total`.

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: google.generativeai` | Older docs/example. The installer uses `google-genai` — import via `from google import genai` |
| App runs but no Gemini spans | Move the four lines above `from google import genai` |
| Streaming chunks not captured | Span closes only when stream is fully consumed |

---

## Panel implementation notes

- Same template + copy-button pattern as the other provider cards.
- Token format and substitution identical.
- Gemini provider card can co-exist with the `google-adk` framework card —
  they install different instrumentor packages. They will both be active if a
  user installs both.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/providers/google-gemini.md](../../openobserve-docs/docs/integration/ai/providers/google-gemini.md)
