# Claude Agent SDK — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Claude Agent SDK** panel should
render.

> **Note**: Claude Agent SDK has no built-in OpenTelemetry instrumentor.
> Tracing is added by wrapping `query()` calls in manual spans using the
> standard OTel API. The installer sets up the OpenObserve OTel SDK; the
> snippet shows the wrapper pattern.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | Claude Agent SDK |
| Category | AI / SDKs |
| Icon | `claude.svg` |
| Tagline | Trace every agent run — token usage, turn counts, error status |
| Prerequisites | Python 3.10+, Claude Code CLI on PATH, Anthropic API key |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=claude-agent-sdk \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`, `claude-agent-sdk`,
`python-dotenv` via pip; verifies imports; writes `OPENOBSERVE_*` keys to
`.env`.

Note: the user must have **Claude Code CLI** (`@anthropic-ai/claude-code`)
installed and on PATH — the SDK runs it as a subprocess. Install via:

```bash
npm install -g @anthropic-ai/claude-code
```

## Section 2 — Paste this into your app

```python
from openobserve import openobserve_init
openobserve_init()

from opentelemetry import trace
from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

tracer = trace.get_tracer(__name__)

# Wrap each query() call in a manual span:
async def run_agent(prompt):
    options = ClaudeAgentOptions(max_turns=1, allowed_tools=[])
    with tracer.start_as_current_span("claude_agent.query") as span:
        span.set_attribute("claude_agent.prompt", prompt[:100])
        async for message in query(prompt=prompt, options=options):
            if isinstance(message, ResultMessage):
                span.set_attribute("claude_agent.num_turns", message.num_turns)
                span.set_attribute("claude_agent.is_error", message.is_error)
                if message.usage:
                    span.set_attribute("claude_agent.input_tokens",
                                       message.usage.get("input_tokens", 0))
                    span.set_attribute("claude_agent.output_tokens",
                                       message.usage.get("output_tokens", 0))
```

> Paste at the top of your app entrypoint. The `with tracer.start_as_current_span(...)`
> block goes around each `query()` call.

## Section 3 — Verify

> Run any `query()` call wrapped in the span.

Open Traces, filter `operation_name = claude_agent.query`. Each query
produces one span with `claude_agent.num_turns`, `claude_agent.input_tokens`,
`claude_agent.output_tokens`, `claude_agent.cache_read_input_tokens`,
`claude_agent.duration_api_ms`, `claude_agent.is_error`.

E2E example: a single `query("say ok", options=ClaudeAgentOptions(max_turns=1, allowed_tools=[]))`
produced 1 span with those attributes.

## Section 4 — Important gotchas

| Gotcha | Mitigation |
|---|---|
| **`permission_mode="bypassPermissions"` fails as root** | Claude CLI refuses `--dangerously-skip-permissions` when running as root. In CI/docker, run as non-root OR don't set bypassPermissions. For simple prompts with no tool calls, `allowed_tools=[]` is enough |
| **Claude Code CLI must be on PATH** | The SDK shells out — install it globally with npm before running your Python app |
| **No auto-instrumentor** | Spans are user-created. Other Claude integrations (Anthropic SDK direct) have auto-instrumentors; this one doesn't |

## Section 5 — Troubleshooting

| Symptom | Fix |
|---|---|
| `CLINotFoundError` | Install `@anthropic-ai/claude-code` globally |
| `Command failed with exit code 1` with no detail | Pass `stderr=print` in `ClaudeAgentOptions` to surface claude's error |
| `--dangerously-skip-permissions cannot be used with root/sudo` | Don't use `bypassPermissions` mode in root containers |
| No spans appear | You forgot to wrap `query()` in `tracer.start_as_current_span()` |

---

## Panel implementation notes

- Different shape from auto-instrumented framework cards — this one requires
  user code change for span wrapping. Make sure the snippet is full enough
  to be copy-paste-ready.
- The Claude Code CLI prerequisite is the most common failure — the panel
  should detect or at least prominently note it.

## Reference

Full integration docs:
[openobserve-docs/docs/integration/ai/frameworks/claude-agent-sdk.md](../../openobserve-docs/docs/integration/ai/frameworks/claude-agent-sdk.md)
