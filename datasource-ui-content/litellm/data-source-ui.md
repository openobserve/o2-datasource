# LiteLLM — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → LiteLLM** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | LiteLLM |
| Category | AI / Frameworks |
| Icon | `litellm.svg` |
| Tagline | Trace LLM calls across 100+ providers via a unified interface |
| Supported runtime | Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=litellm \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`openinference-instrumentation-litellm`, `litellm`, `python-dotenv` via pip.
Uses the **OpenInference** instrumentor.

## Section 2 — Paste this into your app

```python
from openinference.instrumentation.litellm import LiteLLMInstrumentor
from openobserve import openobserve_init

LiteLLMInstrumentor().instrument()
openobserve_init()
```

> Four lines at the top, **before** importing `litellm`.

Works for `litellm.completion(...)`, async (`acompletion`), and streaming.
Switching between providers (`gpt-4o-mini`, `claude-sonnet-4`, etc.) produces
separate spans with different `llm_model_name` values.

## Section 3 — Verify

> Call `litellm.completion(...)`.

Open Traces, filter `operation_name = completion`. Spans include
`llm_model_name`, `llm_provider`, `llm_token_count_prompt`,
`llm_token_count_completion`, `llm_invocation_parameters` (full request JSON),
`llm_usage_cost_input/output`.

E2E example produced 1 span for a single completion call.

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| `botocore` warnings for Bedrock / SageMaker | Cosmetic — LiteLLM tries to load all backend SDKs at import; ignored if you're not using AWS |
| No spans appear | Move the four lines above `import litellm` |
| Provider key errors | Set the right `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / etc. in env |

---

## Panel implementation notes

- Same template + copy-button as other framework cards.
- For multi-provider apps, the panel could surface a "Compare models by cost"
  dashboard link.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/frameworks/litellm.md](../../openobserve-docs/docs/integration/ai/frameworks/litellm.md)
