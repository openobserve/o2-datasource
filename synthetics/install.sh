#!/usr/bin/env bash
# OpenObserve synthetics private-agent installer — one public script, three
# platforms. Source of truth for the agent binary/image is the (private)
# synthetic-o2-agent repo; this script is mirrored here because it has to be
# fetchable without auth, same reason install scripts for other OpenObserve
# components live in this repo (see k8s/install.sh).
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
#     [--region=us-east] \
#     [--agent-name=corp-hq-agent-01] \
#     [--image=public.ecr.aws/zinclabs/synthetic-o2-agent:latest] \
#     [--namespace=o2-synthetics]            # k8s only
#
# Platforms:
#   docker   docker run -d --restart=always            (default)
#   k8s      kubectl apply of a Namespace+Secret+Deployment (replicas: 1)
#   linux    docker container under a systemd unit (survives reboots)
#   windows  not yet available
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
IMAGE="public.ecr.aws/zinclabs/synthetic-o2-agent:latest"
NAMESPACE="o2-synthetics"
LEASE_MAX=""

usage() { sed -n '2,40p' "$0" 2>/dev/null || true; }

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
    --image=*)      IMAGE="${arg#*=}" ;;
    --namespace=*)  NAMESPACE="${arg#*=}" ;;
    --lease-max=*)  LEASE_MAX="${arg#*=}" ;;
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
O2_URL="${O2_URL%/}"

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

# Shared env (docker + linux). k8s renders its own block below.
build_env_flags() {
  flags=(-e "AGENT_POLL_ENDPOINT=$O2_URL" -e "AGENT_ORG=$ORG" -e "AGENT_API_TOKEN=$TOKEN" -e "PROBE_AGENT_ID=$AGENT_NAME" -e "SSRF_POLICY_DEFAULT=relaxed")
  if [ -n "$LOCATION_ID" ]; then
    flags+=(-e "AGENT_LOCATION_ID=$LOCATION_ID")
  else
    flags+=(-e "AGENT_LOCATION=$LOCATION")
  fi
  if [ -n "$REGION" ]; then flags+=(-e "PROBE_REGION=$REGION"); fi
  if [ -n "$LEASE_MAX" ]; then flags+=(-e "PROBE_LEASE_MAX=$LEASE_MAX"); fi
}

install_docker() {
  command -v docker >/dev/null 2>&1 || fail "docker is not installed"
  build_env_flags
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
  docker run -d --restart=always --name "$CONTAINER_NAME" "${flags[@]}" "$IMAGE"
  echo "==> Agent '$AGENT_NAME' running. The location turns Online in the UI after first register."
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

install_linux() {
  # Docker under systemd: no public binary distribution yet, so the container
  # runtime does the heavy lifting and systemd owns restarts/boot persistence.
  command -v docker >/dev/null 2>&1 || fail "docker is not installed (linux install runs the agent container under systemd)"
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
  [ "$(id -u)" -eq 0 ] || fail "linux install writes a systemd unit — run with sudo"

  build_env_flags
  unit_name="$CONTAINER_NAME.service"
  unit_path="/etc/systemd/system/$unit_name"

  echo "==> Pulling $IMAGE"
  if ! docker pull "$IMAGE" 2>/dev/null; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
      || fail "cannot pull $IMAGE and no local image with that tag exists"
    echo "==> Pull failed; using local image $IMAGE"
  fi

  echo "==> Writing $unit_path"
  {
    echo "[Unit]"
    echo "Description=OpenObserve synthetics private agent ($AGENT_NAME)"
    echo "After=docker.service network-online.target"
    echo "Requires=docker.service"
    echo ""
    echo "[Service]"
    echo "Restart=always"
    echo "RestartSec=5"
    echo "ExecStartPre=-/usr/bin/docker rm -f $CONTAINER_NAME"
    printf 'ExecStart=/usr/bin/docker run --rm --name %s' "$CONTAINER_NAME"
    for f in "${flags[@]}"; do
      [ "$f" = "-e" ] && continue
      printf ' -e %q' "$f"
    done
    printf ' %s\n' "$IMAGE"
    echo "ExecStop=/usr/bin/docker stop $CONTAINER_NAME"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "$unit_path"
  chmod 600 "$unit_path"

  systemctl daemon-reload
  systemctl enable --now "$unit_name"
  echo "==> Agent '$AGENT_NAME' running under systemd ($unit_name)."
}

case "$PLATFORM" in
  docker)  install_docker ;;
  k8s|kubernetes) install_k8s ;;
  linux)   install_linux ;;
  windows) fail "Windows support is coming soon — use docker or k8s for now" ;;
  *) fail "unknown platform: $PLATFORM (docker|k8s|linux)" ;;
esac
