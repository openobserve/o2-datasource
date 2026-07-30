---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Koog
  logo: logo.png
  tagline: "Trace JetBrains Koog agent runs, LLM calls, and node-level span trees from Kotlin."
  runtime: JDK 17+ / Kotlin 2.x
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # Koog sets the OTLP resource service.name to koog-app in the sample config.
  filter: "service_name = 'koog-app'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/koog/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Export your OpenObserve credentials before running. The OTLP exporter reads them from the environment."
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
        # your model provider key
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Add the Koog and OpenTelemetry dependencies (Maven/Gradle), then build an OTLP exporter and install `OpenTelemetry.Feature` on each agent. Full details in the docs."
    chip: { kind: editor, label: Main.kt }
    required: true
    complete_on: copy
    note: "The OTLP endpoint is ${OPENOBSERVE_URL}api/${OPENOBSERVE_ORG}/v1/traces with the Authorization header set to your Basic token."
    code:
      lang: kotlin
      filename: Main.kt
      text: |
        // Gradle: implementation("ai.koog:koog-agents:0.7.1")
        //         implementation("io.opentelemetry:opentelemetry-exporter-otlp:1.43.0")
        import ai.koog.agents.features.opentelemetry.feature.OpenTelemetry
        import io.opentelemetry.exporter.otlp.http.trace.OtlpHttpSpanExporter
        import io.opentelemetry.sdk.OpenTelemetrySdk
        import io.opentelemetry.sdk.trace.SdkTracerProvider
        import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor

        val ooUrl = System.getenv("OPENOBSERVE_URL") ?: "http://localhost:5080/"
        val ooOrg = System.getenv("OPENOBSERVE_ORG") ?: "default"
        val ooAuth = System.getenv("OPENOBSERVE_AUTH_TOKEN") ?: ""

        val exporter = OtlpHttpSpanExporter.builder()
            .setEndpoint("${ooUrl}api/${ooOrg}/v1/traces")
            .addHeader("Authorization", ooAuth)
            .build()

        val tracerProvider = SdkTracerProvider.builder()
            .addSpanProcessor(SimpleSpanProcessor.create(exporter))
            .build()
        val sdk = OpenTelemetrySdk.builder().setTracerProvider(tracerProvider).build()

  - title: Run Your App & Test
    description: "Install the feature on an agent and run it, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: kotlin
      filename: Main.kt
      text: |
        import ai.koog.agents.core.agent.AIAgent
        import ai.koog.prompt.executor.clients.openai.OpenAIModels
        import ai.koog.prompt.executor.llms.all.simpleOpenAIExecutor

        val executor = simpleOpenAIExecutor(System.getenv("OPENAI_API_KEY"))

        val agent = AIAgent.builder()
            .promptExecutor(executor)
            .llmModel(OpenAIModels.Chat.GPT4oMini)
            .systemPrompt("You are a helpful assistant. Answer concisely.")
            .install(OpenTelemetry.Feature) { config ->
                config.setSdk(sdk)
                config.setServiceInfo("koog-app", "1.0")
            }
            .build()

        println(agent.run("What is distributed tracing?"))
        tracerProvider.shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = koog-app`. Each agent run produces a span tree (`create_agent` → `invoke_agent` → node spans) carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_request_model
      - gen_ai_usage_input_tokens
      - gen_ai_usage_output_tokens

extras:
  installs:
    - ai.koog:koog-agents
    - io.opentelemetry:opentelemetry-sdk
    - io.opentelemetry:opentelemetry-exporter-otlp
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_lang: kotlin
fix_title: "Shut Down the Tracer Provider"
fix_body: "If your app runs but no spans appear, the JVM may exit before spans are flushed. Shut down the tracer provider at the end of the run:"
fix_snippet: |
  // after agent.run(...)
  tracerProvider.shutdown()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Confirm the OTLP endpoint is ${OPENOBSERVE_URL}api/${OPENOBSERVE_ORG}/v1/traces and call tracerProvider.shutdown() before the JVM exits."
  - q: "401/403 from the OTLP endpoint"
    a: "The Authorization header must be the full `Basic <base64>` value. Re-copy OPENOBSERVE_AUTH_TOKEN from Manage Tokens."
  - q: "No traces under koog-app"
    a: "service.name is set via config.setServiceInfo and the resource. Open Traces, read the actual service_name, and adjust the filter if you renamed it."
  - q: "Maven/Gradle cannot resolve ai.koog dependencies"
    a: "Ensure Maven Central is configured and you are on the pinned versions (koog-agents 0.7.1, opentelemetry 1.43.0)."

---

# Koog

Trace JetBrains Koog agent runs to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
