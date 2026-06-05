# Cursor — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Cursor** panel should render.

> ⚠ **Two-step setup, two pieces of software.** Cursor's OTel hook is
> maintained by [LangGuard-AI/cursor-otel-hook](https://github.com/LangGuard-AI/cursor-otel-hook).
> Our installer configures it to ship to OpenObserve, but the upstream tool
> itself must be installed once first (or by our installer's bootstrap step).

---

## Card metadata

| Field | Value |
|---|---|
| Display name | Cursor |
| Category | AI / Agents |
| Icon | `cursor.svg` |
| Tagline | Trace Cursor Agent activity — tool calls, file ops, prompt context |
| Prerequisites | Cursor IDE installed; macOS / Linux / Windows; Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/agents/cursor/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:**

1. Bootstraps the upstream `cursor-otel-hook` by fetching + running its
   `setup.sh` (installs the binary, the wrapper script, registers Cursor
   hook events in `~/.cursor/hooks.json`).
2. Writes `~/.cursor/hooks/otel_config.json` with OpenObserve OTLP values
   layered on top of whatever default the upstream wrote.

**Already installed cursor-otel-hook?** Pass `--skip-bootstrap` to only
write the OpenObserve config.

**Restart Cursor after the install** so it re-reads `~/.cursor/hooks.json`.

## Section 2 — Verify (manual)

> Cursor IDE doesn't run headless, so this step is manual.

1. In Cursor, open a project, hit ⌘+I (or ⌘+L), type any prompt.
2. `tail -f ~/.cursor/hooks/cursor_otel_hook.log`
3. In OpenObserve, **Traces** tab → filter `service_name = cursor`. You'll
   see spans for `sessionStart`, `preToolUse`, `postToolUse`, `sessionEnd`,
   etc.

## Section 3 — What gets captured

| Attribute | Source |
|---|---|
| `service_name` | always `cursor` |
| Span names | `sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`, MCP call events |
| Tool name, args, result | from each `preToolUse` / `postToolUse` event |
| Shell commands run | from shell-command tool events |
| File operations | path + diff |
| MCP server calls | name + request + response |

Set `CURSOR_OTEL_MASK_PROMPTS=true` in `otel_config.json` to redact prompt
text (default: off). Our installer doesn't set this; user opts in by editing.

## Section 4 — Limitations

| Limitation | Workaround |
|---|---|
| **Windows requires PowerShell bootstrap** | Run upstream's `setup.ps1` manually, then run our installer with `--skip-bootstrap` from WSL or Git Bash |
| **Cursor IDE must be restarted** for hooks to reload | One-time per install |
| **Upstream cursor-otel-hook is third-party** | Pin `--upstream-ref=<tag>` for reproducibility |
| **Real-trace verification requires GUI** | Can't be automated in a docker-only test |

## Section 5 — Troubleshooting

| Symptom | Fix |
|---|---|
| Log file doesn't exist | Hook not registered — re-run install + restart Cursor |
| Log says `OTLP export 401` | Token wrong — re-run installer with the right `--token` |
| `~/.cursor/hooks.json` missing after install | Bootstrap didn't run — re-run with `--skip-bootstrap=0` (default) |
| Hook fires but no span in OpenObserve | Check `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` in `otel_config.json` matches your URL |

---

## Panel implementation notes

- This card needs a "step 2 of 2" feel — the install command is single-line,
  but the verify step is several manual actions in the IDE.
- Consider surfacing a "Cursor not detected" warning if the user is browsing
  the panel from a machine that's not the one running Cursor.
- The link to upstream `cursor-otel-hook` is important — that's the project
  that maintains the actual hook binary; we're just configuring it.

## Reference

Live installer:
[openobserve-telemetry-installers/agents/cursor/install.sh](../../openobserve-telemetry-installers/agents/cursor/install.sh)

Upstream: <https://github.com/LangGuard-AI/cursor-otel-hook>
