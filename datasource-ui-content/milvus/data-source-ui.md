---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Milvus
  tagline: "Trace Milvus vector search, insert, and delete operations: collection and result counts."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each operation is wrapped in a manual span
  # named e.g. milvus.search, which OpenObserve maps to operation_name.
  filter: "operation_name = 'milvus.search'"

doc_url: https://openobserve.ai/docs/integration/ai/tools/milvus/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials. For a remote server or Zilliz Cloud, add `MILVUS_URI` and `MILVUS_TOKEN`."
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
        # remote server / Zilliz Cloud only:
        # MILVUS_URI=https://your-cluster.zillizcloud.com
        # MILVUS_TOKEN=your-api-key

  - title: Install & Instrument
    description: "Install the SDK + PyMilvus, call `openobserve_init()` **before** importing PyMilvus, then wrap each operation in a manual span. Milvus Lite requires `pymilvus==2.5.1`. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk "pymilvus==2.5.1" milvus-lite opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os, random
        from pymilvus import MilvusClient

        tracer = trace.get_tracer(__name__)

        uri = os.environ.get("MILVUS_URI", "./milvus_data.db")
        token = os.environ.get("MILVUS_TOKEN", "")
        client = MilvusClient(uri=uri, token=token) if token else MilvusClient(uri=uri)

        DIM, COLLECTION = 128, "my_vectors"

  - title: Run It & Test
    description: "Create a collection, insert vectors, run a search, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        with tracer.start_as_current_span("milvus.create_collection") as span:
            span.set_attribute("milvus.collection", COLLECTION)
            if client.has_collection(COLLECTION):
                client.drop_collection(COLLECTION)
            client.create_collection(collection_name=COLLECTION, dimension=DIM)

        with tracer.start_as_current_span("milvus.insert") as span:
            span.set_attribute("milvus.collection", COLLECTION)
            data = [{"id": i, "vector": [random.random() for _ in range(DIM)]} for i in range(100)]
            client.insert(collection_name=COLLECTION, data=data)
            span.set_attribute("milvus.insert_count", len(data))

        with tracer.start_as_current_span("milvus.search") as span:
            span.set_attribute("milvus.collection", COLLECTION)
            results = client.search(collection_name=COLLECTION, data=[[random.random() for _ in range(DIM)]], limit=10)
            span.set_attribute("milvus.result_count", len(results[0]))

        client.close()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = milvus.search`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - milvus_collection
      - milvus_result_count
      - milvus_insert_count

extras:
  installs:
    - openobserve-telemetry-sdk
    - pymilvus
    - milvus-lite
    - opentelemetry-api
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Importing PyMilvus"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before importing pymilvus
  from openobserve import openobserve_init
  openobserve_init()

  # only then import and use pymilvus inside manual spans
  from pymilvus import MilvusClient

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() above any pymilvus import, and ensure each operation is wrapped in tracer.start_as_current_span()."
  - q: "Milvus Lite import or version errors"
    a: "Milvus Lite requires pymilvus==2.5.1. For a remote server or Zilliz Cloud, any recent pymilvus works."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. milvus.search). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Milvus

Trace Milvus vector database operations to OpenObserve via OpenTelemetry. The
Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
