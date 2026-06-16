---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Semantic Kernel
  tagline: "Trace Semantic Kernel LLM calls, function invocations, and planner steps."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Semantic Kernel emits gen_ai spans natively;
  # chat completions store gen_ai_system = 'openai' (lowercased on ingest).
  filter: "LOWER(gen_ai_system) = 'openai'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/semantic-kernel/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials."
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
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + Semantic Kernel, set the OTel diagnostics env vars **before** `openobserve_init()`. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "The SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS env vars must be set before openobserve_init() — Semantic Kernel only emits spans when diagnostics are enabled."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk semantic-kernel python-dotenv
        import asyncio
        import os
        from dotenv import load_dotenv
        load_dotenv()

        os.environ["SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS"] = "true"
        os.environ["SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS_SENSITIVE"] = "true"

        from openobserve import openobserve_init
        openobserve_init()

        from semantic_kernel import Kernel
        from semantic_kernel.connectors.ai.open_ai import OpenAIChatCompletion
        from semantic_kernel.connectors.ai.open_ai import OpenAIChatPromptExecutionSettings
        from semantic_kernel.contents import ChatHistory

        kernel = Kernel()
        kernel.add_service(
            OpenAIChatCompletion(
                service_id="chat",
                ai_model_id="gpt-4o-mini",
                api_key=os.environ["OPENAI_API_KEY"],
            )
        )

        settings = OpenAIChatPromptExecutionSettings(max_tokens=100)

  - title: Run Your App & Test
    description: "Make any chat call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        async def main():
            chat = ChatHistory()
            chat.add_user_message("What is OpenTelemetry?")
            service = kernel.get_service("chat")
            result = await service.get_chat_message_contents(chat, settings=settings)
            print(str(result[0]))

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces**; spans appear named `chat gpt-4o-mini`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_request_model
      - gen_ai_usage_input_tokens
      - gen_ai_usage_output_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - semantic-kernel
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Enable Diagnostics Before Init"
fix_body: "If your app runs but no spans appear, diagnostics weren't enabled before init. Set the env vars first:"
fix_snippet: |
  # enable OTel diagnostics FIRST
  os.environ["SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS"] = "true"
  os.environ["SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS_SENSITIVE"] = "true"

  # only then initialize
  openobserve_init()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Set both SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS env vars before calling openobserve_init()."
  - q: "Spans appear but the filter matches nothing"
    a: "gen_ai_system is `openai` for OpenAI chat completions. If you use a different connector, open Traces and adjust the filter to the actual gen_ai_system value."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Semantic Kernel

Trace Semantic Kernel LLM calls and function invocations to OpenObserve via
OpenTelemetry. Semantic Kernel emits gen_ai spans natively once diagnostics are
enabled. The Data Sources panel renders the stepped setup card from the frontmatter.
