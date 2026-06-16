---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Vercel AI SDK
  tagline: "Trace Vercel AI SDK calls: token usage, model name, and finish reason."
  runtime: Node.js 18+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. With experimental_telemetry enabled each call
  # emits an outer span whose operation_name is ai.generateText.
  filter: "operation_name = 'ai.generateText'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/vercel-ai-sdk/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Set the standard OTLP env vars and your OpenAI key before running your script."
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
        OTEL_EXPORTER_OTLP_ENDPOINT={url}/api/{org}/v1/traces
        OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic {token}
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the AI SDK + OTel packages, set up the NodeSDK exporter, then pass `experimental_telemetry: { isEnabled: true }` to any call. Full details in the docs."
    chip: { kind: editor, label: index.js }
    required: true
    complete_on: copy
    note: "Call sdk.start() before importing/using the AI SDK so spans are captured, and await sdk.shutdown() before the script exits to flush them."
    code:
      lang: javascript
      filename: index.js
      text: |
        // npm install ai @ai-sdk/openai @opentelemetry/sdk-node \
        //   @opentelemetry/exporter-trace-otlp-http @opentelemetry/sdk-trace-node @opentelemetry/resources
        const { NodeSDK } = require("@opentelemetry/sdk-node");
        const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
        const { SimpleSpanProcessor } = require("@opentelemetry/sdk-trace-node");
        const { resourceFromAttributes } = require("@opentelemetry/resources");

        const authHeader = process.env.OTEL_EXPORTER_OTLP_HEADERS.replace("Authorization=", "");

        const sdk = new NodeSDK({
          resource: resourceFromAttributes({ "service.name": "vercel-ai" }),
          spanProcessors: [
            new SimpleSpanProcessor(
              new OTLPTraceExporter({
                url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT,
                headers: { Authorization: authHeader },
              })
            ),
          ],
        });
        sdk.start();

        const { generateText } = require("ai");
        const { createOpenAI } = require("@ai-sdk/openai");
        const openai = createOpenAI({ apiKey: process.env.OPENAI_API_KEY });

  - title: Run Your App & Test
    description: "Make any generateText call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: javascript
      filename: index.js
      text: |
        async function main() {
          const result = await generateText({
            model: openai("gpt-4o-mini"),
            prompt: "What is distributed tracing?",
            maxTokens: 256,
            experimental_telemetry: { isEnabled: true },
          });
          console.log(result.text);
          await sdk.shutdown();
        }

        main().catch(console.error);

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = ai.generateText`. Each call produces an outer span plus a child `doGenerate` span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - ai_model_id
      - ai_usage_inputtokens
      - ai_usage_outputtokens

extras:
  installs:
    - ai
    - "@ai-sdk/openai"
    - "@opentelemetry/sdk-node"
    - "@opentelemetry/exporter-trace-otlp-http"
  env_vars:
    - OTEL_EXPORTER_OTLP_ENDPOINT
    - OTEL_EXPORTER_OTLP_HEADERS
    - OPENAI_API_KEY

fix_title: "Start the SDK and Enable Telemetry"
fix_body: "If your app runs but no spans appear, the OTel SDK wasn't started or telemetry wasn't enabled on the call. Verify both:"
fix_lang: javascript
fix_snippet: |
  // start the SDK BEFORE any AI SDK call
  sdk.start();

  // enable telemetry per call
  await generateText({ model, prompt, experimental_telemetry: { isEnabled: true } });

  // flush before the process exits
  await sdk.shutdown();

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call sdk.start() before any generateText call, pass experimental_telemetry: { isEnabled: true }, and await sdk.shutdown() before exiting so spans flush."
  - q: "Spans appear but the filter matches nothing"
    a: "The outer span operation_name is ai.generateText (or ai.streamText / ai.generateObject). Open Traces and adjust the filter to the call type you use."
  - q: "Export fails with a 401"
    a: "OTEL_EXPORTER_OTLP_HEADERS must be Authorization=Basic <base64>. Re-copy the token from Manage Tokens."
  - q: "Endpoint not found / 404"
    a: "OTEL_EXPORTER_OTLP_ENDPOINT must be {url}/api/{org}/v1/traces with the correct org."

---

# Vercel AI SDK

Trace Vercel AI SDK calls to OpenObserve via OpenTelemetry using the SDK's
built-in experimental_telemetry option and a standard OTLP exporter. The Data
Sources panel renders the stepped setup card from the frontmatter above.
