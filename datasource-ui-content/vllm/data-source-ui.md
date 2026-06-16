---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: vLLM
  tagline: "Trace local vLLM inference calls: token usage, latency, prompt text, and completion output."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. vLLM serves an OpenAI-compatible API, so the
  # OpenInference OpenAI instrumentor sets operation_name='Completion' (or
  # 'ChatCompletion' for chat). Spans also carry service_name='vllm'.
  filter: "service_name = 'vllm'"
  model_label: facebook/opt-125m

doc_url: https://openobserve.ai/docs/integration/ai/providers/vllm/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and vLLM base URL."
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
        VLLM_BASE_URL=http://localhost:8001/v1

  - title: Install & Instrument
    description: "Start vLLM, install the SDK + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` **before** creating the client pointed at your vLLM server."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Start the server first, e.g. `pip install vllm && vllm serve facebook/opt-125m --port 8001`. No server code changes are needed."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        OpenAIInstrumentor().instrument()

        from openobserve import openobserve_init
        openobserve_init(resource_attributes={"service.name": "vllm"})

        import os
        from openai import OpenAI

        client = OpenAI(
            api_key="not-needed",
            base_url=os.environ.get("VLLM_BASE_URL", "http://localhost:8001/v1"),
        )

  - title: Run Your App & Test
    description: "Make any inference call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        models = client.models.list()
        model_name = models.data[0].id

        response = client.completions.create(
            model=model_name,
            prompt="Explain distributed tracing in one sentence.",
            max_tokens=20,
        )
        print(response.choices[0].text)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = vllm`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_prompts_0_prompt_text
      - llm_token_count_total

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - VLLM_BASE_URL

fix_title: "Instrument Before Creating The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the OpenAI client is created
  OpenAIInstrumentor().instrument()
  openobserve_init(resource_attributes={"service.name": "vllm"})

  # only then create the client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the OpenAI client creation."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — spans set service_name='vllm' and operation_name='Completion' (or 'ChatCompletion' for chat). Adjust the filter to match."
  - q: "Connection refused to the vLLM server"
    a: "Confirm the server is running (`vllm serve ... --port 8001`) and VLLM_BASE_URL matches the host/port."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# vLLM

Trace local vLLM inference calls to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
