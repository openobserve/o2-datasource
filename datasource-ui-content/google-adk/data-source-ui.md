# Google ADK — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Google ADK** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | Google ADK |
| Category | AI / Frameworks |
| Icon | `google-adk.svg` |
| Tagline | Trace every ADK agent run, LLM call, and tool execution |
| Supported runtime | Python 3.10+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=google-adk \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`openinference-instrumentation-google-adk`, `google-adk`, `python-dotenv` via
pip; verifies imports; writes `OPENOBSERVE_*` keys to `.env`.

This integration uses the **OpenInference** instrumentor family (not
OpenLLMetry like most provider cards). Both ecosystems co-exist in the same
venv without conflict.

## Section 2 — Paste this into your app

```python
from openinference.instrumentation.google_adk import GoogleADKInstrumentor
from openobserve import openobserve_init

GoogleADKInstrumentor().instrument()
openobserve_init()
```

> Four lines at the top of your app entrypoint, **before** importing any
> `google.adk` modules.

Works for any Agent invoked via `Runner.run_async()`. Tools and multi-turn
agents produce the expected nested span tree.

## Section 3 — Verify

> Run any ADK agent via `Runner.run_async()`.

Open Traces, look for `invocation [<app_name>]` root spans. Each invocation
produces a tree:

```
invocation [<app_name>]
└── agent_run [<agent_name>]
    └── call_llm (one per LLM round)
        └── execute_tool <tool_name> (one per tool use)
```

Attributes include `gcp_vertex_agent_name`, `gen_ai.request.model`,
`llm_usage_input_tokens`, `llm_usage_output_tokens`,
`llm_token_count_completion_details_reasoning` (Gemini 2.5 thinking
budget), `user_id`, `gen_ai_conversation_id`.

E2E example produced 3 spans for a single-turn agent (invocation +
agent_run + call_llm).

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| `ImportError: cannot import name 'Agent' from 'google.adk'` | Older `google-adk` version — the installer pulls latest |
| `GOOGLE_API_KEY not set` | Add it to `.env` or your shell env |
| No spans in OpenObserve | Move the four lines above all `google.adk` imports |

---

## Panel implementation notes

- Same template + copy-button pattern as the other framework cards.
- This is the OpenInference variant — the icon set should distinguish it
  from the OpenLLMetry providers if your panel uses ecosystem badges.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/frameworks/google-adk.md](../../openobserve-docs/docs/integration/ai/frameworks/google-adk.md)
