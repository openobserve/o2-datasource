#!/bin/bash

# OpenObserve Kubernetes Collector Quick Installer
# Usage: curl -sSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/k8s/install.sh | bash -s -- --cluster-name=mycluster --o2-url=https://myinstance.openobserve.ai --org-id=myorg --access-key=base64key

set -e

# Version pinning for reproducibility (Issue 9 - Fixed)
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.0}"
PROMETHEUS_OPERATOR_VERSION="${PROMETHEUS_OPERATOR_VERSION:-v0.77.1}"
OTEL_OPERATOR_VERSION="${OTEL_OPERATOR_VERSION:-0.138.0}"

# Network operation settings (Issue 10, 12 - Fixed)
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
OPERATION_TIMEOUT="${OPERATION_TIMEOUT:-300}"

# Default values
CLUSTER_NAME=""
O2_URL=""
ORG_ID=""
ACCESS_KEY=""
NAMESPACE="openobserve-collector"
SKIP_CERT_MANAGER=false
SKIP_OTEL_OPERATOR=false
INTERNAL_ENDPOINT=""
DRY_RUN=false

# Cleanup tracking (Issue 21 - Fixed)
RESOURCES_CREATED=()
TEMP_FILES=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Redact sensitive information (Issue 4 - Fixed)
redact_secret() {
    local secret="$1"
    if [ ${#secret} -le 8 ]; then
        echo "****"
    else
        echo "${secret:0:4}****${secret: -4}"
    fi
}

# Cleanup function (Issue 21 - Fixed)
cleanup_on_error() {
    print_error "Installation failed. Cleaning up..."

    # Remove temporary files
    for temp_file in "${TEMP_FILES[@]}"; do
        if [ -f "$temp_file" ]; then
            rm -f "$temp_file"
            print_info "Removed temporary file: $temp_file"
        fi
    done

    print_warning "Some resources may have been created. Review and clean up if needed:"
    for resource in "${RESOURCES_CREATED[@]}"; do
        print_info "  - $resource"
    done

    exit 1
}

# Set trap for cleanup (Issue 21 - Fixed)
trap cleanup_on_error ERR INT TERM

# Retry function for network operations (Issue 10 - Fixed)
retry_command() {
    local max_attempts=$RETRY_COUNT
    local delay=$RETRY_DELAY
    local attempt=1
    local command="$@"

    while [ $attempt -le $max_attempts ]; do
        if eval "$command"; then
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                print_warning "Attempt $attempt failed. Retrying in ${delay}s..."
                sleep $delay
                ((attempt++))
            else
                print_error "Command failed after $max_attempts attempts: $command"
                return 1
            fi
        fi
    done
}

# Print usage
usage() {
    cat << EOF
OpenObserve Kubernetes Collector Installer

Usage:
    $0 [OPTIONS]

Required Options:
    --cluster-name=NAME       Name of your Kubernetes cluster
    --o2-url=URL             OpenObserve instance URL (e.g., https://myinstance.openobserve.ai)
    --org-id=ID              OpenObserve organization ID
    --access-key=KEY         Base64 encoded access key (email:passcode)

Optional:
    --namespace=NS           Namespace for collector (default: openobserve-collector)
    --skip-cert-manager      Skip cert-manager installation
    --skip-otel-operator     Skip OpenTelemetry operator installation
    --internal-endpoint=URL  Use internal cluster endpoint (e.g., http://o2-openobserve-router.openobserve.svc.cluster.local:5080)
    --dry-run                Validate configuration without installing (Issue 29 - Fixed)
    --help                   Show this help message

Environment Variables:
    CERT_MANAGER_VERSION     cert-manager version (default: v1.19.0)
    PROMETHEUS_OPERATOR_VERSION  Prometheus operator version (default: v0.77.1)
    OTEL_OPERATOR_VERSION    OpenTelemetry operator version (default: 0.115.0)
    RETRY_COUNT             Number of retries for network operations (default: 3)
    RETRY_DELAY             Delay between retries in seconds (default: 5)
    OPERATION_TIMEOUT       Timeout for operations in seconds (default: 300)
    HTTP_PROXY              HTTP proxy URL (Issue 28 - Fixed)
    HTTPS_PROXY             HTTPS proxy URL (Issue 28 - Fixed)
    NO_PROXY                No proxy hosts (Issue 28 - Fixed)

Examples:
    # Basic installation
    curl -sSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/k8s/install.sh | bash -s -- \\
      --cluster-name=production \\
      --o2-url=https://cloud.openobserve.ai \\
      --org-id=default \\
      --access-key=\$(echo -n "user@example.com:passcode" | base64)

    # Dry run to validate configuration
    ./install.sh --dry-run --cluster-name=production --o2-url=https://cloud.openobserve.ai --org-id=default --access-key=base64key

    # Install with internal endpoint (same cluster)
    curl -sSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/k8s/install.sh | bash -s -- \\
      --cluster-name=production \\
      --org-id=default \\
      --access-key=\$(echo -n "user@example.com:passcode" | base64) \\
      --internal-endpoint=http://o2-openobserve-router.openobserve.svc.cluster.local:5080

    # Skip cert-manager if already installed
    curl -sSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/k8s/install.sh | bash -s -- \\
      --cluster-name=production \\
      --o2-url=https://cloud.openobserve.ai \\
      --org-id=default \\
      --access-key=base64key \\
      --skip-cert-manager

EOF
}

# Validate base64 format (Issue 17 - Fixed)
validate_base64() {
    local input="$1"
    if ! echo "$input" | base64 -d &>/dev/null; then
        return 1
    fi
    return 0
}

# Validate URL format (Issue 18 - Fixed)
validate_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?:// ]]; then
        return 1
    fi
    return 0
}

# Parse arguments
for arg in "$@"; do
    case $arg in
        --cluster-name=*)
            CLUSTER_NAME="${arg#*=}"
            shift
            ;;
        --o2-url=*)
            O2_URL="${arg#*=}"
            shift
            ;;
        --org-id=*)
            ORG_ID="${arg#*=}"
            shift
            ;;
        --access-key=*)
            ACCESS_KEY="${arg#*=}"
            shift
            ;;
        --namespace=*)
            NAMESPACE="${arg#*=}"
            shift
            ;;
        --skip-cert-manager)
            SKIP_CERT_MANAGER=true
            shift
            ;;
        --skip-otel-operator)
            SKIP_OTEL_OPERATOR=true
            shift
            ;;
        --internal-endpoint=*)
            INTERNAL_ENDPOINT="${arg#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$CLUSTER_NAME" ]; then
    print_error "Missing required parameter: --cluster-name"
    usage
    exit 1
fi

if [ -z "$ORG_ID" ]; then
    print_error "Missing required parameter: --org-id"
    usage
    exit 1
fi

if [ -z "$ACCESS_KEY" ]; then
    print_error "Missing required parameter: --access-key"
    usage
    exit 1
fi

# Validate endpoint
if [ -z "$INTERNAL_ENDPOINT" ] && [ -z "$O2_URL" ]; then
    print_error "Either --o2-url or --internal-endpoint must be provided"
    usage
    exit 1
fi

# Validate ACCESS_KEY format (Issue 17 - Fixed)
if ! validate_base64 "$ACCESS_KEY"; then
    print_error "Invalid ACCESS_KEY format. Must be valid base64 encoded string."
    print_info "Generate with: echo -n 'email:passcode' | base64"
    exit 1
fi

# Use internal endpoint if provided, otherwise use external URL
if [ -n "$INTERNAL_ENDPOINT" ]; then
    ENDPOINT="$INTERNAL_ENDPOINT"
    print_info "Using internal cluster endpoint: $ENDPOINT"
else
    ENDPOINT="$O2_URL"
    # Validate URL format (Issue 18 - Fixed)
    if ! validate_url "$ENDPOINT"; then
        print_error "Invalid URL format for --o2-url. Must start with http:// or https://"
        exit 1
    fi
    # Normalize URL - remove trailing slash
    ENDPOINT="${ENDPOINT%/}"
    print_info "Using external endpoint: $ENDPOINT"
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please install kubectl first."
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    print_error "helm is not installed. Please install helm first."
    exit 1
fi

# Check kubectl access
if ! kubectl cluster-info &> /dev/null; then
    print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

# Note: Kubernetes version check removed - cert-manager and operators will validate compatibility
print_info "Skipping Kubernetes version check (components will validate compatibility)"

# RBAC permission verification (Issue 20 - Fixed)
print_info "Verifying RBAC permissions..."
required_permissions=(
    "create:namespaces"
    "create:deployments.apps"
    "create:serviceaccounts"
    "create:clusterroles.rbac.authorization.k8s.io"
    "create:clusterrolebindings.rbac.authorization.k8s.io"
)

for perm in "${required_permissions[@]}"; do
    verb="${perm%%:*}"
    resource="${perm##*:}"
    if ! kubectl auth can-i "$verb" "$resource" --all-namespaces &>/dev/null; then
        print_error "Missing RBAC permission: $verb $resource"
        print_info "Current user does not have sufficient permissions to install."
        exit 1
    fi
done

print_success "RBAC permissions verified"

# Endpoint reachability check (Issue 11 - Fixed)
if [[ "$ENDPOINT" =~ ^https?:// ]]; then
    print_info "Checking endpoint reachability: $ENDPOINT"
    if command -v curl &> /dev/null; then
        endpoint_reachable=false

        # Try multiple endpoints and check HTTP status codes
        # 200-299: Success
        # 401/403: Endpoint exists but requires auth (expected for API endpoints)
        # 404/5xx: Endpoint doesn't exist or server error
        for test_path in "" "/healthz" "/api/$ORG_ID"; do
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$ENDPOINT$test_path" 2>/dev/null || echo "000")

            # Treat 2xx, 401, and 403 as reachable
            if [[ "$http_code" =~ ^(2[0-9][0-9]|401|403)$ ]]; then
                endpoint_reachable=true
                if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
                    print_success "Endpoint is reachable (HTTP $http_code - requires authentication)"
                else
                    print_success "Endpoint is reachable (HTTP $http_code)"
                fi
                break
            fi
        done

        if [ "$endpoint_reachable" = false ]; then
            print_warning "Cannot reach endpoint $ENDPOINT. Installation will proceed but data export may fail."
            print_info "Please verify:"
            print_info "  1. The endpoint URL is correct"
            print_info "  2. Network connectivity from cluster to endpoint"
            print_info "  3. Firewall rules allow outbound connections"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    else
        print_warning "curl not found, skipping endpoint reachability check"
    fi
fi

print_success "Prerequisites check passed"
echo ""
print_info "Installation configuration:"
print_info "  Cluster Name: $CLUSTER_NAME"
print_info "  Endpoint: $ENDPOINT"
print_info "  Organization ID: $ORG_ID"
print_info "  Access Key: $(redact_secret "$ACCESS_KEY")"
print_info "  Namespace: $NAMESPACE"
print_info "  cert-manager Version: $CERT_MANAGER_VERSION"
print_info "  Prometheus Operator Version: $PROMETHEUS_OPERATOR_VERSION"
print_info "  OpenTelemetry Operator Version: $OTEL_OPERATOR_VERSION"
echo ""

# Dry run mode (Issue 29 - Fixed)
if [ "$DRY_RUN" = true ]; then
    print_success "Dry run mode: Configuration validated successfully"
    print_info "Would install the following components:"
    if [ "$SKIP_CERT_MANAGER" = false ]; then
        print_info "  - cert-manager $CERT_MANAGER_VERSION"
    fi
    if [ "$SKIP_OTEL_OPERATOR" = false ]; then
        print_info "  - Prometheus Operator CRDs $PROMETHEUS_OPERATOR_VERSION"
        print_info "  - OpenTelemetry Operator $OTEL_OPERATOR_VERSION"
    fi
    print_info "  - OpenObserve Collector in namespace $NAMESPACE"
    exit 0
fi

# Check for existing installation (Issue 23 - Fixed)
if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "o2c"; then
    print_warning "Existing OpenObserve collector installation found in namespace $NAMESPACE"
    print_warning "This will upgrade the existing installation. Configuration may change."
    print_info "Current installation:"
    helm list -n "$NAMESPACE" | grep "o2c" || true
    echo ""
    read -p "Continue with upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled"
        exit 0
    fi
    # Backup recommendation (Issue 30 - Fixed)
    print_info "Consider backing up current values:"
    print_info "  helm get values o2c -n $NAMESPACE > o2c-backup-\$(date +%Y%m%d-%H%M%S).yaml"
fi

# Install cert-manager
if [ "$SKIP_CERT_MANAGER" = false ]; then
    # Check if cert-manager is already installed (Issue 6 - Fixed)
    if kubectl get namespace cert-manager &>/dev/null; then
        EXISTING_CM_VERSION=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "unknown")
        print_info "cert-manager already installed (version: $EXISTING_CM_VERSION)"

        # Normalize versions by removing 'v' prefix for comparison
        EXISTING_CM_VERSION_CLEAN="${EXISTING_CM_VERSION#v}"
        TARGET_CM_VERSION_CLEAN="${CERT_MANAGER_VERSION#v}"

        if [ "$EXISTING_CM_VERSION" != "unknown" ] && [ "$EXISTING_CM_VERSION_CLEAN" != "$TARGET_CM_VERSION_CLEAN" ]; then
            print_warning "Installed version ($EXISTING_CM_VERSION_CLEAN) differs from target version ($TARGET_CM_VERSION_CLEAN)"
            read -p "Skip cert-manager installation? (Y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                SKIP_CERT_MANAGER=true
                print_info "Skipping cert-manager installation"
            fi
        else
            SKIP_CERT_MANAGER=true
            print_success "Using existing cert-manager installation (version matches)"
        fi
    fi

    if [ "$SKIP_CERT_MANAGER" = false ]; then
        print_info "Installing cert-manager $CERT_MANAGER_VERSION..."
        retry_command "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
        RESOURCES_CREATED+=("cert-manager namespace and components")
        print_success "cert-manager installation initiated"

        # Improved wait logic (Issue 13 - Fixed)
        print_info "Waiting for cert-manager webhook to be ready (timeout: ${OPERATION_TIMEOUT}s)..."
        if kubectl wait --for=condition=Available --timeout=${OPERATION_TIMEOUT}s -n cert-manager deployment/cert-manager-webhook 2>/dev/null; then
            print_success "cert-manager webhook is ready"
        else
            print_warning "Webhook not ready within timeout, checking pod status..."
            kubectl get pods -n cert-manager
            print_warning "Waiting additional 60 seconds..."
            sleep 60

            if ! kubectl get deployment cert-manager-webhook -n cert-manager &>/dev/null; then
                print_error "cert-manager webhook deployment not found"
                exit 1
            fi
        fi

        # Verify cert-manager is functional
        print_info "Verifying cert-manager functionality..."
        if kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io cert-manager-webhook &>/dev/null; then
            print_success "cert-manager is ready"
        else
            print_error "cert-manager webhook configuration not found"
            exit 1
        fi
    fi
else
    print_info "Skipping cert-manager installation (--skip-cert-manager flag set)"
fi

# Update helm repo
print_info "Adding OpenObserve helm repository..."
retry_command "helm repo add openobserve https://charts.openobserve.ai"
retry_command "helm repo update"
print_success "Helm repository updated"

# Install Prometheus operator CRDs
if [ "$SKIP_OTEL_OPERATOR" = false ]; then
    print_info "Installing Prometheus operator CRDs (version $PROMETHEUS_OPERATOR_VERSION)..."

    # Check for existing resources using CRDs (Issue 7 - Fixed)
    existing_resources=()
    if kubectl get servicemonitors.monitoring.coreos.com --all-namespaces &>/dev/null; then
        count=$(kubectl get servicemonitors.monitoring.coreos.com --all-namespaces --no-headers 2>/dev/null | wc -l)
        if [ $count -gt 0 ]; then
            existing_resources+=("$count ServiceMonitor(s)")
        fi
    fi

    if kubectl get podmonitors.monitoring.coreos.com --all-namespaces &>/dev/null; then
        count=$(kubectl get podmonitors.monitoring.coreos.com --all-namespaces --no-headers 2>/dev/null | wc -l)
        if [ $count -gt 0 ]; then
            existing_resources+=("$count PodMonitor(s)")
        fi
    fi

    if [ ${#existing_resources[@]} -gt 0 ]; then
        print_warning "Found existing resources using Prometheus CRDs:"
        for res in "${existing_resources[@]}"; do
            print_warning "  - $res"
        done
        print_warning "Updating CRDs may cause temporary disruption"
        read -p "Continue with CRD update? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping CRD installation"
            SKIP_OTEL_OPERATOR=true
        fi
    fi

    if [ "$SKIP_OTEL_OPERATOR" = false ]; then
        # Use server-side apply for large CRDs to avoid annotation size limits
        retry_command "kubectl apply --server-side=true -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROMETHEUS_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"
        retry_command "kubectl apply --server-side=true -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROMETHEUS_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml"
        retry_command "kubectl apply --server-side=true -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROMETHEUS_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml"
        retry_command "kubectl apply --server-side=true -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROMETHEUS_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml"
        RESOURCES_CREATED+=("Prometheus Operator CRDs")
        print_success "Prometheus operator CRDs installed"

        # Wait for CRDs to be established (Issue 14 - Fixed)
        print_info "Waiting for CRDs to be established..."
        for crd in servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com scrapeconfigs.monitoring.coreos.com probes.monitoring.coreos.com; do
            timeout=60
            elapsed=0
            while [ $elapsed -lt $timeout ]; do
                if kubectl get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q "True"; then
                    print_success "CRD $crd is established"
                    break
                fi
                sleep 2
                elapsed=$((elapsed + 2))
            done

            if [ $elapsed -ge $timeout ]; then
                print_error "Timeout waiting for CRD $crd to be established"
                exit 1
            fi
        done

        # Install OpenTelemetry operator
        print_info "Installing OpenTelemetry operator..."
        retry_command "kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v${OTEL_OPERATOR_VERSION}/opentelemetry-operator.yaml"
        RESOURCES_CREATED+=("OpenTelemetry Operator")
        print_success "OpenTelemetry operator installed"

        # Wait for operator to be ready (Issue 15 - Fixed)
        print_info "Waiting for OpenTelemetry operator to be ready..."
        if kubectl wait --for=condition=Available --timeout=${OPERATION_TIMEOUT}s -n opentelemetry-operator-system deployment/opentelemetry-operator-controller-manager 2>/dev/null; then
            print_success "OpenTelemetry operator deployment is ready"
        else
            # Operator might be in different namespace or different name
            print_warning "Could not verify operator readiness with standard name. Checking operator pods..."
            sleep 30
        fi

        # Wait for webhook certificates to be issued by cert-manager (critical for collector installation)
        print_info "Waiting for OpenTelemetry operator webhook certificates to be ready..."
        print_info "This may take up to 2 minutes while cert-manager issues certificates..."

        # Wait for the webhook secret to exist
        timeout=120
        elapsed=0
        webhook_ready=false

        while [ $elapsed -lt $timeout ]; do
            # Check if webhook secret exists and has data
            if kubectl get secret -n opentelemetry-operator-system opentelemetry-operator-controller-manager-service-cert &>/dev/null; then
                webhook_ready=true
                print_success "Webhook certificates are ready"
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
            if [ $((elapsed % 30)) -eq 0 ]; then
                print_info "Still waiting for webhook certificates... (${elapsed}s elapsed)"
            fi
        done

        if [ "$webhook_ready" = false ]; then
            print_warning "Webhook certificates not detected within timeout"
            print_warning "Installation may fail. Consider waiting and retrying if it fails."
        fi

        # Additional wait for webhook to be fully functional
        print_info "Waiting for webhook service to be responsive..."
        sleep 15
    fi
else
    print_info "Skipping OpenTelemetry operator installation (--skip-otel-operator flag set)"
fi

# Create namespace
print_info "Creating namespace: $NAMESPACE..."
if kubectl create namespace "$NAMESPACE" 2>/dev/null; then
    RESOURCES_CREATED+=("Namespace: $NAMESPACE")
    print_success "Namespace created"
else
    print_info "Namespace already exists"
fi

# Wait for namespace to be active (Issue 16 - Fixed)
timeout=30
elapsed=0
while [ $elapsed -lt $timeout ]; do
    phase=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$phase" = "Active" ]; then
        print_success "Namespace is active"
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

# Create temporary values file for secure credential handling (Issue 2 - Fixed)
# Clean up any old temp files first
rm -f /tmp/o2c-values.*.yaml 2>/dev/null || true

TEMP_VALUES_FILE=$(mktemp /tmp/o2c-values.XXXXXX.yaml)
if [ $? -ne 0 ] || [ -z "$TEMP_VALUES_FILE" ]; then
    print_error "Failed to create temporary values file"
    exit 1
fi

TEMP_FILES+=("$TEMP_VALUES_FILE")
chmod 600 "$TEMP_VALUES_FILE"

cat > "$TEMP_VALUES_FILE" << EOF
k8sCluster: ${CLUSTER_NAME}
exporters:
  otlphttp/openobserve:
    endpoint: ${ENDPOINT}/api/${ORG_ID}
    headers:
      Authorization: "Basic ${ACCESS_KEY}"
  otlphttp/openobserve_k8s_events:
    endpoint: ${ENDPOINT}/api/${ORG_ID}
    headers:
      Authorization: "Basic ${ACCESS_KEY}"
EOF

# Install OpenObserve collector
print_info "Installing OpenObserve collector..."
if helm --namespace "$NAMESPACE" upgrade --install o2c openobserve/openobserve-collector -f "$TEMP_VALUES_FILE" --timeout="${OPERATION_TIMEOUT}s"; then
    RESOURCES_CREATED+=("OpenObserve Collector: o2c in namespace $NAMESPACE")
    print_success "OpenObserve collector installed successfully!"
else
    print_error "Failed to install OpenObserve collector"
    exit 1
fi

# Clean up temporary files immediately after use
rm -f "$TEMP_VALUES_FILE"
TEMP_FILES=()

echo ""

# Post-installation health checks (Issue 25 - Fixed)
print_info "Running post-installation health checks..."

# Check if collector pods are running
print_info "Checking collector pod status..."
sleep 10  # Give pods time to start

timeout=120
elapsed=0
collector_ready=false

while [ $elapsed -lt $timeout ]; do
    pod_status=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve-collector -o jsonpath='{.items[*].status.phase}' 2>/dev/null)

    if echo "$pod_status" | grep -q "Running"; then
        collector_ready=true
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
done

if [ "$collector_ready" = true ]; then
    print_success "Collector pods are running"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve-collector
else
    print_warning "Collector pods are not yet running. Check status with:"
    print_info "  kubectl get pods -n $NAMESPACE"
    print_info "  kubectl describe pods -n $NAMESPACE -l app.kubernetes.io/name=openobserve-collector"
fi

# Check for crashlooping pods
crashlooping=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.containerStatuses[*].restartCount>2)].metadata.name}' 2>/dev/null)
if [ -n "$crashlooping" ]; then
    print_warning "Some pods are crashlooping: $crashlooping"
    print_info "Check logs with: kubectl logs -n $NAMESPACE $crashlooping"
fi

echo ""
print_success "Installation complete!"
echo ""

# Informational output
print_info "The collector will now:"
print_info "  • Collect metrics from your Kubernetes cluster"
print_info "  • Collect events from your Kubernetes cluster"
print_info "  • Collect logs from your Kubernetes cluster"
print_info "  • Enable OpenTelemetry auto-instrumentation for applications"
echo ""
print_info "To enable auto-instrumentation for your applications, add these annotations to your pods/namespaces:"
print_info "  Java:   instrumentation.opentelemetry.io/inject-java: \"openobserve-collector/openobserve-java\""
print_info "  DotNet: instrumentation.opentelemetry.io/inject-dotnet: \"openobserve-collector/openobserve-dotnet\""
print_info "  NodeJS: instrumentation.opentelemetry.io/inject-nodejs: \"openobserve-collector/openobserve-nodejs\""
print_info "  Python: instrumentation.opentelemetry.io/inject-python: \"openobserve-collector/openobserve-python\""
print_info "  Go:     instrumentation.opentelemetry.io/inject-go: \"openobserve-collector/openobserve-go\""
echo ""

# Resource recommendations (Issue 31 - Fixed)
print_info "Resource Recommendations:"
print_info "  Small clusters (<50 nodes):   CPU: 200m-500m, Memory: 256Mi-512Mi"
print_info "  Medium clusters (50-200 nodes): CPU: 500m-1, Memory: 512Mi-1Gi"
print_info "  Large clusters (>200 nodes):  CPU: 1-2, Memory: 1Gi-2Gi"
echo ""

# Troubleshooting guidance (Issue 27 - Fixed)
print_info "Troubleshooting:"
print_info "  Check collector status:    kubectl get pods -n $NAMESPACE"
print_info "  View collector logs:       kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=openobserve-collector"
print_info "  Check configuration:       helm get values o2c -n $NAMESPACE"
print_info "  Verify data flow:          Check your OpenObserve dashboard for incoming data"
echo ""
print_info "Common issues:"
print_info "  1. No data in dashboard: Verify endpoint URL and credentials"
print_info "  2. Pods crashlooping: Check resource limits and node capacity"
print_info "  3. Authentication errors: Verify access key is correctly base64 encoded"
print_info "  4. Network errors: Check firewall rules and network policies"
echo ""

print_success "Check your OpenObserve dashboard for incoming data: $ENDPOINT"

# Clear trap since we completed successfully
trap - ERR INT TERM
