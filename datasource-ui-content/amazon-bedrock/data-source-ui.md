---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Amazon Bedrock
  tagline: "Trace every Bedrock converse call: token usage, latency, and model metadata."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # confirmed against the docs: openinference-instrumentation-bedrock names the
  # converse span 'bedrock.converse' (operation_name).
  filter: "operation_name = 'bedrock.converse'"
  model_label: amazon.nova-lite-v1:0

doc_url: https://openobserve.ai/docs/integration/ai/providers/amazon-bedrock/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and AWS keys. The AWS credentials need `AmazonBedrockFullAccess`."
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
        AWS_ACCESS_KEY_ID=your-access-key-id
        AWS_SECRET_ACCESS_KEY=your-secret-access-key
        AWS_DEFAULT_REGION=us-east-1

  - title: Install & Instrument
    description: "Install the SDK + instrumentor, then call `BedrockInstrumentor().instrument()` **before** creating any boto3 client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-bedrock boto3 python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.bedrock import BedrockInstrumentor
        from openobserve import openobserve_init

        BedrockInstrumentor().instrument()
        openobserve_init(resource_attributes={"service.name": "amazon-bedrock"})

        import os
        import boto3

        bedrock = boto3.client(
            "bedrock-runtime",
            region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        )

  - title: Run Your App & Test
    description: "Make any `converse` call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = bedrock.converse(
            modelId="amazon.nova-lite-v1:0",
            messages=[{"role": "user", "content": [{"text": "Explain observability in one sentence."}]}],
        )
        print(response["output"]["message"]["content"][0]["text"])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = bedrock.converse`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_completion
      - llm_token_count_total

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-bedrock
    - boto3
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - AWS_ACCESS_KEY_ID
    - AWS_SECRET_ACCESS_KEY
    - AWS_DEFAULT_REGION

fix_title: "Instrument Before Creating The boto3 Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. BedrockInstrumentor().instrument() must run before boto3.client(...) is called:"
fix_snippet: |
  # instrument FIRST — before any boto3 client exists
  from openinference.instrumentation.bedrock import BedrockInstrumentor
  from openobserve import openobserve_init

  BedrockInstrumentor().instrument()
  openobserve_init(resource_attributes={"service.name": "amazon-bedrock"})

  import boto3
  bedrock = boto3.client("bedrock-runtime")

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move BedrockInstrumentor().instrument() and openobserve_init() above the boto3.client(...) call — clients created before instrumentation are not traced."
  - q: "AccessDeniedException from Bedrock"
    a: "Your AWS credentials need AmazonBedrockFullAccess, and the model (e.g. amazon.nova-lite-v1:0) must have access enabled in the Bedrock console for your region."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces, read the actual operation_name on a span, and adjust the filter. The instrumentor names converse spans 'bedrock.converse'."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Amazon Bedrock

Trace Amazon Bedrock `converse` calls to OpenObserve via the OpenInference
Bedrock instrumentor. The Data Sources panel renders the stepped setup card from
the frontmatter above; this body is human-readable notes only.
