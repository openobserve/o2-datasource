---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: BytePlus ModelArk
  tagline: "Trace BytePlus ModelArk inference calls: latency, token usage, model name, and reasoning tokens."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. ModelArk uses the OpenAI-compatible API, so
  # the OpenInference OpenAI instrumentor sets operation_name='ChatCompletion'.
  # Spans also carry service_name='byteplus'.
  filter: "operation_name = 'ChatCompletion'"
  model_label: seed-1-8

doc_url: https://openobserve.ai/docs/integration/ai/providers/byteplus/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and BytePlus settings."
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
        BYTEPLUS_API_KEY=your-byteplus-api-key
        BYTEPLUS_BASE_URL=https://ark.ap-southeast.bytepluses.com/api/v3
        BYTEPLUS_ENDPOINT_ID=ep-xxxxxxxxxxxxxxxx-xxxxx

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` **before** `openobserve_init()` and the client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        OpenAIInstrumentor().instrument()

        from openobserve import openobserve_init, openobserve_shutdown
        openobserve_init(resource_attributes={"service.name": "byteplus"})

        import os
        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["BYTEPLUS_API_KEY"],
            base_url=os.environ["BYTEPLUS_BASE_URL"],
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
        response = client.chat.completions.create(
            model=os.environ["BYTEPLUS_ENDPOINT_ID"],
            messages=[{"role": "user", "content": "What is distributed tracing?"}],
            max_tokens=256,
        )
        print(response.choices[0].message.content)
        openobserve_shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = byteplus`. Each `ChatCompletion` span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_completion_details_reasoning

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
    - BYTEPLUS_API_KEY

fix_title: "Instrument Before Creating The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the OpenAI client is created
  OpenAIInstrumentor().instrument()
  openobserve_init(resource_attributes={"service.name": "byteplus"})

  # only then create the client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the OpenAI client creation."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attributes — spans set operation_name='ChatCompletion' and service_name='byteplus'. Adjust the filter to match."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# BytePlus ModelArk

Trace BytePlus ModelArk inference calls to OpenObserve via OpenTelemetry. The
Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
