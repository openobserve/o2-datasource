# OpenRouter — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → OpenRouter** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | OpenRouter |
| Category | AI / Gateways |
| Icon | `openrouter.svg` |
| Tagline | Trace LLM calls routed through 200+ provider models via a single endpoint |
| Supported runtime | Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=openrouter \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`openinference-instrumentation-openai`, `openai`, `python-dotenv` via pip.

**Note** — this card uses **OpenInference**'s OpenAI instrumentor, NOT
OpenLLMetry's. If you also install the `openai` provider card, those two
instrumentors **conflict** (both register `OpenAIInstrumentor`). Pick one
per project.

## Section 2 — Paste this into your app

```python
from openinference.instrumentation.openai import OpenAIInstrumentor
from openobserve import openobserve_init

OpenAIInstrumentor().instrument()
openobserve_init()
```

Then create the OpenAI client pointed at OpenRouter:

```python
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["OPENROUTER_API_KEY"],
    base_url="https://openrouter.ai/api/v1",
    default_headers={
        "HTTP-Referer": "https://your-app.example.com",
        "X-Title": "Your App",
    },
)
```

The two `default_headers` are optional but populate your OpenRouter usage
dashboard.

## Section 3 — Verify

> Make any OpenRouter request: `client.chat.completions.create(model="...", ...)`.

Open Traces, filter `llm_model_name` containing a `/` — OpenRouter model
names always have provider prefixes like `openai/gpt-4o-mini`,
`anthropic/claude-3.5-sonnet`, `meta-llama/llama-3.1-70b-instruct`.

Spans include `llm_model_name`, `gen_ai_response_model`,
`llm_token_count_prompt/completion/total`, `llm_system` (= `openai`, the
client library), `openinference_span_kind` (= `LLM`).

E2E example produced 1 span using `openai/gpt-oss-20b:free` (free tier).

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| Rate limit on free models | Free-tier models throttle aggressively — use a paid model or add retries |
| `OPENAI_API_KEY not set` | OpenRouter uses its own key — pass via `api_key=` arg, not env |
| Spans tagged `gen_ai_system=openai` | Expected — the client library IS the OpenAI SDK; the actual provider is in `llm_model_name` |
| Conflict with OpenAI provider card | Don't install both in the same project |

---

## Panel implementation notes

- Surface the warning about conflicting with the OpenAI provider card if both
  are detected as "configured" in the same project.
- Pre-fill `HTTP-Referer` with the user's OpenObserve org URL as a sensible
  default; let them edit it before copying.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/gateways/openrouter.md](../../openobserve-docs/docs/integration/ai/gateways/openrouter.md)
