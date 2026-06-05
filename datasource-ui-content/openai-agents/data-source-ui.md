# OpenAI Agents SDK — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → OpenAI Agents** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | OpenAI Agents SDK |
| Category | AI / Frameworks |
| Icon | `openai-agents.svg` (or reuse openai.svg) |
| Tagline | Trace every agent workflow, handoff, and LLM call |
| Supported runtime | Python 3.10+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=openai-agents \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`openinference-instrumentation-openai-agents`, `openai-agents`,
`python-dotenv` via pip; verifies imports; writes `OPENOBSERVE_*` keys to
`.env`.

Uses the **OpenInference** instrumentor (like `google-adk`).

## Section 2 — Paste this into your app

```python
from openinference.instrumentation.openai_agents import OpenAIAgentsInstrumentor
from openobserve import openobserve_init

OpenAIAgentsInstrumentor().instrument()
openobserve_init()
```

> Four lines at the top of your app entrypoint, **before** importing the
> `agents` module.

Works for any agent invoked via `Runner.run()` — single-agent, tools,
multi-agent handoffs all produce nested span trees.

## Section 3 — Verify

> Call `Runner.run()` on any Agent.

Open Traces, look for `Agent workflow` (kind: `CHAIN`) root spans. Each agent
run produces a four-level tree:

```
Agent workflow [CHAIN]
└── Assistant
    └── turn
        └── response [LLM]   (one per model call)
```

Attributes include `openinference_span_kind`, `llm_model_name`,
`llm_token_count_prompt`, `llm_token_count_completion`,
`llm_token_count_completion_details_reasoning`,
`llm_token_count_prompt_details_cache_read`, `llm_usage_cost_input/output`.

E2E example produced 5 spans for a single-agent no-tools workflow.

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| `ImportError: No module named 'agents'` | The `pip install openai-agents` is the install — module name is `agents`, not `openai_agents` |
| Handoff produces only one CHAIN span | Make sure both agents are passed via `handoffs=[other_agent]` |
| No spans appear | Move the four lines above `from agents import ...` |

---

## Panel implementation notes

- Same template + copy-button as other framework cards.
- For multi-agent workflows, the panel could optionally surface a link to a
  "Service Map" view of handoff chains.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/frameworks/openai-agents.md](../../openobserve-docs/docs/integration/ai/frameworks/openai-agents.md)
