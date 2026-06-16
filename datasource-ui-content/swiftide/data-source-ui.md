---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Swiftide
  tagline: "Trace Swiftide agent runs: latency, model name, input, and error details."
  runtime: Rust 1.75+
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # The resource sets service.name=swiftide, stored as service_name on every span.
  filter: "service_name = 'swiftide'"
  model_label: claude-haiku-4-5

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/swiftide/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Set your OpenObserve credentials and provider key. Swiftide sets the OTLP endpoint/headers in code; the values below mirror that config."
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
        # used in init_tracing():
        #   endpoint = {url}/api/{org}/v1/traces
        #   header   = Authorization: Basic {token}
        ANTHROPIC_API_KEY=your-anthropic-api-key

  - title: Install & Instrument
    description: "Add the OpenTelemetry + Swiftide crates to `Cargo.toml`, initialize the OTLP provider, then wrap each `agent.query()` in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.rs }
    required: true
    complete_on: copy
    note: "Swiftide does not emit OTel spans automatically — the outer manual span is what flows to OpenObserve. Set the endpoint to {url}/api/{org}/v1/traces and the Authorization header to Basic {token}."
    code:
      lang: rust
      filename: main.rs
      text: |
        // Cargo.toml: swiftide = { version = "0.32", features = ["anthropic"] }
        //             swiftide-agents = "0.32", opentelemetry = "0.27",
        //             opentelemetry_sdk, opentelemetry-otlp, tokio, dotenvy, anyhow
        use opentelemetry::{global, trace::{Span, SpanKind, Status, Tracer, TracerProvider as _}, KeyValue};
        use opentelemetry_otlp::{WithExportConfig, WithHttpConfig};
        use opentelemetry_sdk::{runtime::Tokio, trace::TracerProvider, Resource};

        fn init_tracing() -> anyhow::Result<TracerProvider> {
            let mut headers = std::collections::HashMap::new();
            headers.insert("Authorization".to_string(), "Basic {token}".to_string());

            let exporter = opentelemetry_otlp::SpanExporter::builder()
                .with_http()
                .with_endpoint("{url}/api/{org}/v1/traces")
                .with_headers(headers)
                .build()?;

            let provider = TracerProvider::builder()
                .with_batch_exporter(exporter, Tokio)
                .with_resource(Resource::new(vec![KeyValue::new("service.name", "swiftide")]))
                .build();

            global::set_tracer_provider(provider.clone());
            Ok(provider)
        }

  - title: Run Your App & Test
    description: "Run an agent query inside a manual span, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: rust
      filename: main.rs
      text: |
        let tracer = global::tracer("swiftide");
        let mut span = tracer
            .span_builder("swiftide.agent_run")
            .with_kind(SpanKind::Internal)
            .with_attributes(vec![
                KeyValue::new("model", "claude-haiku-4-5-20251001"),
                KeyValue::new("question", "What is RAG?"),
            ])
            .start(&tracer);

        let mut agent = Agent::builder().llm(&anthropic).build()?;
        let _ = agent.query("What is RAG?".to_string()).await;
        span.set_status(Status::Ok);
        span.end();
        provider.shutdown()?;

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = swiftide`. Each `swiftide.agent_run` span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - model
      - question
      - span_status

extras:
  installs:
    - swiftide
    - swiftide-agents
    - opentelemetry-otlp
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - ANTHROPIC_API_KEY

fix_title: "Flush the Provider Before Exit"
fix_body: "Short-lived programs can exit before the batch exporter flushes. Shut down the provider after your last span:"
fix_lang: rust
fix_snippet: |
  // initialize the provider, keep the handle
  let provider = init_tracing()?;

  // ... run agent queries inside spans ...

  // flush + shut down before main() returns
  provider.shutdown()?;

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Make sure init_tracing() runs before any agent query, and call provider.shutdown() before main() returns so the batch exporter flushes."
  - q: "Spans appear but the filter matches nothing"
    a: "The filter matches the resource service.name (here swiftide). If you changed it, update the service_name value in the filter accordingly."
  - q: "Export fails with a TLS or connection error"
    a: "Confirm the endpoint is {url}/api/{org}/v1/traces and the reqwest/rustls-tls features are enabled in Cargo.toml."
  - q: "Auth errors in the OpenObserve logs"
    a: "The Authorization header must be `Basic <base64>`. Re-copy the token from Manage Tokens."

---

# Swiftide

Trace Swiftide (Rust) agent runs to OpenObserve via OTLP HTTP. Swiftide does not
emit spans automatically, so each agent.query() is wrapped in a manual span. The
Data Sources panel renders the stepped setup card from the frontmatter above.
