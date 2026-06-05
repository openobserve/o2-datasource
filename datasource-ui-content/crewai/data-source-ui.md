# CrewAI — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → CrewAI** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | CrewAI |
| Category | AI / Frameworks |
| Icon | `crewai.svg` |
| Tagline | Trace every crew, agent, task, and tool execution |
| Supported runtime | Python 3.10+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=crewai \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`openinference-instrumentation-crewai`, `crewai>=1.10.1`, `python-dotenv`.
Verifies the imports work. Writes `OPENOBSERVE_*` keys plus
`CREWAI_TELEMETRY_OPT_OUT=true` to `.env`.

**Important compat notes:**

- The OpenInference CrewAI instrumentor (`openinference-instrumentation-crewai>=1.1.8`)
  requires `crewai>=1.10.1`. Older CrewAI versions (`1.6.x`) will install but
  produce zero instrumentor spans.
- CrewAI ships its own OTel pipeline and tracing UI. We opt out via
  `CREWAI_TELEMETRY_OPT_OUT=true` so it doesn't fight with the OpenObserve
  TracerProvider.

## Section 2 — Paste this into your app

```python
import os
os.environ["CREWAI_TELEMETRY_OPT_OUT"] = "true"

from openobserve import openobserve_init
openobserve_init()

from openinference.instrumentation.crewai import CrewAIInstrumentor
CrewAIInstrumentor().instrument()
```

> Paste at the top of your app entrypoint, **before** importing CrewAI or
> the instrumentor.
>
> **Order matters.** `openobserve_init()` must run before the OpenInference
> CrewAI instrumentor is imported. The instrumentor pulls in modules that
> may register their own `TracerProvider`, and OTel ignores subsequent
> `set_tracer_provider()` calls — so initializing OpenObserve first is what
> makes the BatchSpanProcessor + OTLP exporter the active pipeline.

Works for `Crew`, `Agent`, `Task`, `Flow`, sequential/hierarchical
processes, and tool calls.

## Section 3 — Verify

> Call `crew.kickoff()` on any `Crew`.

Open Traces, look for spans named `Crew_<uuid>.kickoff` (root) plus per-agent
`<AgentRole>._execute_core` children. Attributes include `gen_ai.system`,
`gen_ai.request.model`, `gen_ai.usage.input_tokens/output_tokens`,
`crewai.agent.role`, `crewai.task.description`.

E2E example: a single-agent, single-task crew produced 2 spans
(`Crew_<uuid>.kickoff` + `Responder._execute_core`).

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| App runs but no spans in OpenObserve | Almost always wrong import order. `openobserve_init()` must run before the instrumentor import. Move both above all CrewAI imports. |
| Console prints `Overriding of current TracerProvider is not allowed` | Something installed a TracerProvider before `openobserve_init()`. Most often the import order is wrong. Verify the openobserve_init line runs first. |
| CrewAI's own "Tracing Preference Saved" panel appears at startup | Harmless — that's CrewAI confirming it disabled its built-in telemetry because of `CREWAI_TELEMETRY_OPT_OUT=true`. Spans still flow to OpenObserve. |
| Only `gen_ai` metrics appear, no trace spans | You're on the older OpenLLMetry instrumentor (`opentelemetry-instrumentation-crewai==0.60.0`). The installer uses OpenInference (`openinference-instrumentation-crewai`) which emits spans. Re-run the installer. |
| `ModuleNotFoundError: openinference.instrumentation.crewai` | The pip install was skipped or partial — re-run the installer. |

---

## Panel implementation notes

- Same panel template as the other framework cards.
- The two-step snippet (init first, instrumentor second) is unusual relative
  to the other framework cards (most do instrumentor then init). Worth
  calling out visually — maybe a "⚠️ order matters" note next to the
  snippet — so users don't reflexively rearrange.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/frameworks/crewai.md](../../openobserve-docs/docs/integration/ai/frameworks/crewai.md)

**Docs feedback to send back:** the existing doc references the OpenLLMetry
instrumentor (`opentelemetry-instrumentation-crewai`), which emits only
metrics and no spans on modern CrewAI. Switch the doc to OpenInference:

- Replace `opentelemetry-instrumentation-crewai` with `openinference-instrumentation-crewai`
- Replace `from opentelemetry.instrumentation.crewai import CrewAIInstrumentor`
  with `from openinference.instrumentation.crewai import CrewAIInstrumentor`
- Pin `crewai>=1.10.1`
- Document the `openobserve_init()`-before-instrumentor ordering
- Document `CREWAI_TELEMETRY_OPT_OUT=true`
