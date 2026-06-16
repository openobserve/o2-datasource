---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Anthropic (JS/TS)
  tagline: "Trace Anthropic SDK calls from Node.js: latency, token usage, model name, and messages."
  runtime: Node.js 18+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenInference Anthropic instrumentor sets
  # llm_system='anthropic' (lowercase). Spans also carry service_name='anthropic-js'.
  filter: "LOWER(llm_system) = 'anthropic'"
  model_label: claude-haiku-4-5

doc_url: https://openobserve.ai/docs/integration/ai/providers/anthropic-js/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Anthropic key."
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
        ANTHROPIC_API_KEY=your-anthropic-api-key
        OTEL_EXPORTER_OTLP_ENDPOINT={url}/api/{org}/v1/traces
        OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic {token}

  - title: Install & Instrument
    description: "Install the SDK + OpenInference instrumentor, then start the OTel SDK **before** `require()`-ing the Anthropic SDK so the patch applies."
    chip: { kind: editor, label: index.js }
    required: true
    complete_on: copy
    note: "Load the Anthropic SDK with require() AFTER sdk.start() — the instrumentation patches the CommonJS module cache at startup."
    code:
      lang: javascript
      filename: index.js
      text: |
        // npm install @anthropic-ai/sdk @arizeai/openinference-instrumentation-anthropic \
        //   @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-http \
        //   @opentelemetry/sdk-trace-node @opentelemetry/resources
        const { NodeSDK } = require("@opentelemetry/sdk-node");
        const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
        const { SimpleSpanProcessor } = require("@opentelemetry/sdk-trace-node");
        const { resourceFromAttributes } = require("@opentelemetry/resources");
        const { AnthropicInstrumentation } = require("@arizeai/openinference-instrumentation-anthropic");

        const authHeader = process.env.OTEL_EXPORTER_OTLP_HEADERS.replace("Authorization=", "");

        const sdk = new NodeSDK({
          resource: resourceFromAttributes({ "service.name": "anthropic-js" }),
          spanProcessors: [
            new SimpleSpanProcessor(
              new OTLPTraceExporter({
                url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT,
                headers: { Authorization: authHeader },
              })
            ),
          ],
          instrumentations: [new AnthropicInstrumentation()],
        });
        sdk.start();

        // require() AFTER sdk.start() so the instrumentation patch applies
        const Anthropic = require("@anthropic-ai/sdk").default;
        const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

  - title: Run Your App & Test
    description: "Make any Anthropic call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: javascript
      filename: index.js
      text: |
        async function main() {
          const response = await client.messages.create({
            model: "claude-haiku-4-5",
            max_tokens: 256,
            messages: [{ role: "user", content: "What is distributed tracing?" }],
          });
          console.log(response.content[0].text);
          await sdk.shutdown();
        }
        main().catch(console.error);

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = anthropic-js`. Each `Anthropic Messages` span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_completion

extras:
  installs:
    - "@anthropic-ai/sdk"
    - "@arizeai/openinference-instrumentation-anthropic"
    - "@opentelemetry/sdk-node"
    - "@opentelemetry/exporter-trace-otlp-http"
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - ANTHROPIC_API_KEY

fix_title: "Require The Anthropic SDK After sdk.start()"
fix_body: "If your app runs but no spans appear, the SDK was loaded before instrumentation patched it. Re-order so sdk.start() runs first:"
fix_lang: javascript
fix_snippet: |
  // start the OTel SDK FIRST
  sdk.start();
  // only THEN require the Anthropic SDK
  const Anthropic = require("@anthropic-ai/sdk").default;

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move the `require(\"@anthropic-ai/sdk\")` call below `sdk.start()`. The patch only applies to modules loaded after the SDK starts."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — spans set llm_system='anthropic' and service_name='anthropic-js'. Adjust the filter to match."
  - q: "Process exits before traces flush"
    a: "Call `await sdk.shutdown()` before the process ends so buffered spans are exported."
  - q: "Auth errors in the OpenObserve logs"
    a: "OTEL_EXPORTER_OTLP_HEADERS must be `Authorization=Basic <base64>`. Re-copy the token from Manage Tokens."

---

# Anthropic (JS/TS)

Trace Anthropic JS/TS SDK calls to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
