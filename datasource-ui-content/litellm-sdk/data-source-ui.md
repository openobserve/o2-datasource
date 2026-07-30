---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LiteLLM SDK
  logo: logo.png
  tagline: "Trace LiteLLM completion calls across 100+ providers with token usage, latency, and cost."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # LiteLLM LLM spans store operation_name as completion.
  filter: "operation_name = 'completion'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/litellm/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and provider keys."
    chip: { kind: editor, label: .env }
    complete_on: copy
    code:
      lang: bash
      filename: .env
      download_env: true
      text: |
        OPENOBSERVE_URL={url}
        OPENOBSERVE_ORG={org}
        OPENOBSERVE_AUTH_TOKEN=Basic {token}
        # provider keys — add whichever backends you use
        OPENAI_API_KEY=your-openai-key
        ANTHROPIC_API_KEY=your-anthropic-key

  - title: Install & Instrument
    description: "Install the SDK + LiteLLM instrumentor, then call `LiteLLMInstrumentor().instrument()` **before** importing LiteLLM. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-litellm litellm python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.litellm import LiteLLMInstrumentor
        from openobserve import openobserve_init

        LiteLLMInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Make a completion call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import litellm

        response = litellm.completion(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": "Explain distributed tracing in one sentence."}],
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = completion`. Each completion call produces one LLM span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_usage_cost_input

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-litellm
    - litellm
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing LiteLLM"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing litellm
  LiteLLMInstrumentor().instrument()
  openobserve_init()

  # only then import and use litellm
  import litellm

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move LiteLLMInstrumentor().instrument() and openobserve_init() above any litellm import."
  - q: "Provider authentication failed"
    a: "Set the provider key for the model you call (e.g. OPENAI_API_KEY, ANTHROPIC_API_KEY) in your .env."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# LiteLLM SDK

Trace LiteLLM completion calls to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
