#!/usr/bin/env bash
# OpenObserve synthetics private-agent installer — one public script, three
# platforms (Windows is install.ps1, right next to this file — bash can't run
# there). Source of truth for the agent binary/image is the (private)
# synthetic-o2-agent repo; this script is mirrored here because it has to be
# fetchable without auth, same reason install scripts for other OpenObserve
# components live in this repo (see k8s/install.sh). Release binaries for
# linux/Windows are published here too (GitHub Releases, tagged
# synthetics-agent-vX.Y.Z), same reason.
#
# Composed and copy-pasted from the OpenObserve UI (Synthetics → set up a
# private agent). The agent is outbound-only: it long-polls the o2 Job API for
# jobs, runs checks inside your network, and pushes results back. It holds no
# check config, so create/update/delete of checks never requires re-running
# this script — only the agent binary/image itself is updated by redeploying.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/synthetics/install.sh \
#     | bash -s -- \
#     --platform=docker \
#     --o2-url=https://o2.example.com \
#     --org=my-org \
#     --token=o2syn_xxx \
#     --location="Corp HQ" \
#     [--type=browser] \                      # protocol (default) | browser;
#                                             # browser selects the Playwright image
#     [--region=us-east] \
#     [--agent-name=corp-hq-agent-01] \
#     [--version=v0.0.1] \                   # pin a release; default: latest
#     [--image=ghcr.io/openobserve/synthetic-o2-agent:v0.0.1] \  # full override,
#                                             # mutually exclusive with --version
#     [--namespace=o2-synthetics]            # k8s only
#     [--state-dir=~/.config/openobserve/synthetics-agent]  # docker/linux only
#
# Platforms:
#   docker   docker run -d --restart=always                          (default)
#   k8s      kubectl apply of a Namespace+Secret+Deployment (replicas: 1)
#   linux    plain Go binary under a systemd unit — no Docker dependency
#   windows  not this script — see install.ps1 (Windows Service, no Docker)
#
# docker/linux write their config as one file under --state-dir (default
# ~/.config/openobserve/synthetics-agent/<agent>.env) — docker mounts it
# read-only and points the agent at it (AGENT_CONFIG_FILE), linux points
# systemd's EnvironmentFile= straight at it. `cat` that file any time to see
# exactly how the agent is configured; edit it + restart the
# container/service to apply a change, no need to re-run this script.
#
# --location declares the private location by name: the location row is
# auto-created in o2 on the agent's first register, and every agent installed
# with the same name joins (and shares) that location. --location-id pins an
# existing location instead (copy-setup on an existing row).
#
# The agent name is its stable identity: re-registering with the same
# (org, location, name) reuses the same agent record across restarts. Scale a
# location out by running the installer again with a different --agent-name.

set -euo pipefail

PLATFORM="docker"
O2_URL=""
ORG=""
TOKEN=""
LOCATION=""
LOCATION_ID=""
REGION=""
AGENT_NAME=""
IMAGE_REPO="ghcr.io/openobserve/synthetic-o2-agent"
# Browser checks run a separate Node/Playwright image; --type=browser selects it.
BROWSER_IMAGE_REPO="ghcr.io/openobserve/synthetics-browser-probe"
TYPE="protocol"
VERSION=""
IMAGE=""
NAMESPACE="o2-synthetics"
LEASE_MAX=""
STATE_DIR=""

# Where the linux (and install.ps1's Windows) binary releases are published.
# Not this repo — it's private, see header comment above.
BINARY_RELEASES_REPO="openobserve/o2-datasource"
BINARY_NAME="synthetic-o2-agent"

usage() { sed -n '2,54p' "$0" 2>/dev/null || true; }

fail() {
  echo "install.sh: error: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --o2-url=*)     O2_URL="${arg#*=}" ;;
    --org=*)        ORG="${arg#*=}" ;;
    --token=*)      TOKEN="${arg#*=}" ;;
    --location=*)   LOCATION="${arg#*=}" ;;
    --location-id=*) LOCATION_ID="${arg#*=}" ;;
    --region=*)     REGION="${arg#*=}" ;;
    --agent-name=*) AGENT_NAME="${arg#*=}" ;;
    --version=*)    VERSION="${arg#*=}" ;;
    --image=*)      IMAGE="${arg#*=}" ;;
    --type=*)       TYPE="${arg#*=}" ;;
    --namespace=*)  NAMESPACE="${arg#*=}" ;;
    --lease-max=*)  LEASE_MAX="${arg#*=}" ;;
    --state-dir=*)  STATE_DIR="${arg#*=}" ;;
    -h|--help)      usage; exit 0 ;;
    *) fail "unknown argument: $arg (see --help)" ;;
  esac
done

[ -n "$O2_URL" ] || fail "--o2-url is required"
[ -n "$ORG" ] || fail "--org is required (the org the token belongs to)"
[ -n "$TOKEN" ] || fail "--token is required (o2syn_ Job API token)"
case "$TOKEN" in o2syn_*) ;; *) fail "--token must be an o2syn_ Job API token (not an ingest token)" ;; esac
if [ -z "$LOCATION" ] && [ -z "$LOCATION_ID" ]; then
  fail "--location=\"<name>\" or --location-id=<id> is required"
fi
if [ -n "$LOCATION" ] && [ -n "$LOCATION_ID" ]; then
  fail "--location and --location-id are mutually exclusive"
fi
if [ -n "$IMAGE" ] && [ -n "$VERSION" ]; then
  fail "--image and --version are mutually exclusive"
fi
case "$TYPE" in protocol|browser) ;; *) fail "--type must be 'protocol' (default) or 'browser'" ;; esac
# Default image depends on the agent type — browser checks need the Playwright
# image, protocol checks the Go agent. An explicit --image overrides both.
if [ -z "$IMAGE" ]; then
  if [ "$TYPE" = "browser" ]; then
    IMAGE="${BROWSER_IMAGE_REPO}:${VERSION:-latest}"
  else
    IMAGE="${IMAGE_REPO}:${VERSION:-latest}"
  fi
fi
O2_URL="${O2_URL%/}"

# One host-owned directory for every agent's config (docker + linux; k8s uses
# etcd instead, see install_k8s). Not /etc — a plain `docker run` shouldn't
# need root, so this has to work for a non-root invocation too; `linux` mode
# already requires root (writes to /usr/local/bin + a systemd unit), so this
# resolves under $HOME of whichever account ran sudo (/root, deterministically,
# under the default sudo env_reset behavior).
STATE_DIR="${STATE_DIR:-$HOME/.config/openobserve/synthetics-agent}"

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Stable agent identity (see design D9): the server keys agents by
# (org, location, name), so the name must not change across restarts —
# never rely on a container's random hostname.
if [ -z "$AGENT_NAME" ]; then
  host_short="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo agent)"
  if [ -n "$LOCATION" ]; then
    AGENT_NAME="$(slugify "$LOCATION")-$(slugify "$host_short")"
  else
    AGENT_NAME="agent-$(slugify "$host_short")"
  fi
fi

CONTAINER_NAME="synthetic-o2-agent-$(slugify "$AGENT_NAME")"

# Writes the flat KEY=VALUE config file the agent reads at startup via
# AGENT_CONFIG_FILE (docker mounts it in read-only; linux points systemd's
# EnvironmentFile= straight at it, already root). Single source of truth —
# not a separate passive snapshot: `cat` this file to see exactly how the
# agent is configured, and a plain `docker restart` / `systemctl restart`
# picks up an edit to it (the agent re-reads the file on every start).
# Overwritten on every re-run, same idempotency as the old docker rm -f.
write_config_file() {
  mkdir -p "$STATE_DIR"
  CONFIG_PATH="$STATE_DIR/$CONTAINER_NAME.env"
  {
    echo "AGENT_POLL_ENDPOINT=$O2_URL"
    echo "AGENT_ORG=$ORG"
    echo "AGENT_API_TOKEN=$TOKEN"
    echo "PROBE_AGENT_ID=$AGENT_NAME"
    echo "SSRF_POLICY_DEFAULT=relaxed"
    if [ -n "$LOCATION_ID" ]; then
      echo "AGENT_LOCATION_ID=$LOCATION_ID"
    else
      echo "AGENT_LOCATION=$LOCATION"
    fi
    [ -n "$REGION" ] && echo "PROBE_REGION=$REGION"
    [ -n "$LEASE_MAX" ] && echo "PROBE_LEASE_MAX=$LEASE_MAX"
  } > "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
}

# Where the config file is bind-mounted inside the container — the image's
# nonroot user's real home (gcr.io/distroless/static-debian12:nonroot,
# uid 65532, confirmed via its /etc/passwd: nonroot:...:/home/nonroot:...),
# so this is genuinely that user's ~/.config, not an arbitrary internal path.
CONTAINER_CONFIG_DIR="/home/nonroot/.config/openobserve/synthetics-agent"

install_docker() {
  command -v docker >/dev/null 2>&1 || fail "docker is not installed"
  write_config_file
  echo "==> Pulling $IMAGE"
  if ! docker pull "$IMAGE" 2>/dev/null; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
      || fail "cannot pull $IMAGE and no local image with that tag exists"
    echo "==> Pull failed; using local image $IMAGE"
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "==> Replacing existing container $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi
  echo "==> Starting $CONTAINER_NAME"
  docker run -d --restart=always --name "$CONTAINER_NAME" \
    -v "$STATE_DIR:${CONTAINER_CONFIG_DIR}:ro" \
    -e "AGENT_CONFIG_FILE=${CONTAINER_CONFIG_DIR}/$CONTAINER_NAME.env" \
    "$IMAGE"
  echo "==> Agent '$AGENT_NAME' running. Config: $CONFIG_PATH (edit + \`docker restart $CONTAINER_NAME\` to apply changes). The location turns Online in the UI after first register."
}

install_k8s() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed"
  deploy_name="$CONTAINER_NAME"
  if [ -n "$LOCATION_ID" ]; then
    loc_env="        - name: AGENT_LOCATION_ID
          value: \"$LOCATION_ID\""
  else
    loc_env="        - name: AGENT_LOCATION
          value: \"$LOCATION\""
  fi
  region_env=""
  if [ -n "$REGION" ]; then region_env="
        - name: PROBE_REGION
          value: \"$REGION\""
  fi
  lease_env=""
  if [ -n "$LEASE_MAX" ]; then lease_env="
        - name: PROBE_LEASE_MAX
          value: \"$LEASE_MAX\""
  fi

  echo "==> Applying namespace/$NAMESPACE, secret + deployment $deploy_name"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
---
apiVersion: v1
kind: Secret
metadata:
  name: $deploy_name-token
  namespace: $NAMESPACE
type: Opaque
stringData:
  AGENT_API_TOKEN: "$TOKEN"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deploy_name
  namespace: $NAMESPACE
  labels:
    app: $deploy_name
spec:
  # One replica per agent identity: the agent name is its stable identity on
  # the server. Scale a location by installing again with another --agent-name.
  replicas: 1
  selector:
    matchLabels:
      app: $deploy_name
  template:
    metadata:
      labels:
        app: $deploy_name
    spec:
      containers:
      - name: agent
        image: $IMAGE
        env:
        - name: AGENT_POLL_ENDPOINT
          value: "$O2_URL"
        - name: AGENT_ORG
          value: "$ORG"
        - name: PROBE_AGENT_ID
          value: "$AGENT_NAME"
        - name: SSRF_POLICY_DEFAULT
          value: "relaxed"
$loc_env$region_env$lease_env
        - name: AGENT_API_TOKEN
          valueFrom:
            secretKeyRef:
              name: $deploy_name-token
              key: AGENT_API_TOKEN
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            memory: 512Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65532
EOF
  echo "==> Agent '$AGENT_NAME' deploying. The location turns Online in the UI after first register."
}

# linux amd64/arm64 -> the release asset arch suffix (§ scripts/build-release-binaries.sh).
agent_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) fail "unsupported architecture: $(uname -m) (linux supports amd64/arm64)" ;;
  esac
}

# Resolves the newest synthetics-agent-vX.Y.Z release tag on the public
# binary-releases repo, or synthetics-agent-$VERSION when --version is
# pinned. Not GitHub's generic /releases/latest — that repo may host other
# products' releases too, so "latest" there isn't necessarily ours.
resolve_agent_tag() {
  if [ -n "$VERSION" ]; then
    echo "synthetics-agent-${VERSION}"
    return
  fi
  curl -fsSL "https://api.github.com/repos/${BINARY_RELEASES_REPO}/releases" \
    | grep -o '"tag_name": *"synthetics-agent-v[^"]*"' \
    | head -1 \
    | sed -E 's/.*"(synthetics-agent-v[^"]*)".*/\1/'
}

install_linux() {
  # Plain Go binary under a systemd unit — no Docker dependency.
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
  [ "$(id -u)" -eq 0 ] || fail "linux install writes to /usr/local/bin and a systemd unit — run with sudo"

  write_config_file
  arch="$(agent_arch)"
  tag="$(resolve_agent_tag)"
  [ -n "$tag" ] || fail "could not resolve a synthetics-agent release tag (pass --version to pin one explicitly)"

  asset="${BINARY_NAME}-linux-${arch}"
  base_url="https://github.com/${BINARY_RELEASES_REPO}/releases/download/${tag}"
  bin_path="/usr/local/bin/${BINARY_NAME}"
  unit_name="$CONTAINER_NAME.service"
  unit_path="/etc/systemd/system/$unit_name"

  echo "==> Downloading ${asset} (${tag})"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL -o "$tmp" "${base_url}/${asset}" || fail "download failed: ${base_url}/${asset}"

  if curl -fsSL -o "${tmp}.sha256" "${base_url}/${asset}.sha256" 2>/dev/null; then
    echo "==> Verifying checksum"
    (cd "$(dirname "$tmp")" && echo "$(cat "${tmp}.sha256" | awk '{print $1}')  $(basename "$tmp")" | sha256sum -c -) \
      || fail "checksum verification failed for ${asset}"
    rm -f "${tmp}.sha256"
  else
    echo "==> No checksum asset published for ${tag}; skipping verification"
  fi

  install -m 755 "$tmp" "$bin_path"
  rm -f "$tmp"
  trap - EXIT

  echo "==> Writing $unit_path"
  {
    echo "[Unit]"
    echo "Description=OpenObserve synthetics private agent ($AGENT_NAME)"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo ""
    echo "[Service]"
    echo "Restart=always"
    echo "RestartSec=5"
    echo "EnvironmentFile=$CONFIG_PATH"
    echo "ExecStart=$bin_path"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "$unit_path"
  chmod 600 "$unit_path"

  systemctl daemon-reload
  systemctl enable --now "$unit_name"
  echo "==> Agent '$AGENT_NAME' running under systemd ($unit_name), no Docker involved. Config: $CONFIG_PATH (edit + \`systemctl restart $unit_name\` to apply changes)."
}

case "$PLATFORM" in
  docker)  install_docker ;;
  k8s|kubernetes) install_k8s ;;
  linux)   install_linux ;;
  windows) fail "run install.ps1 instead — this script is bash-only, Windows install is a Windows Service, not a platform flag here" ;;
  *) fail "unknown platform: $PLATFORM (docker|k8s|linux)" ;;
esac
