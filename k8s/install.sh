#!/bin/bash

# OpenObserve Kubernetes Collector Quick Installer
# Usage: curl -sSL https://raw.githubusercontent.com/openobserve/openobserve/main/deploy/k8s/install.sh | bash -s -- --cluster-name=mycluster --o2-url=https://myinstance.openobserve.ai --org-id=myorg --access-key=base64key

set -e

# Default values
CLUSTER_NAME=""
O2_URL=""
ORG_ID=""
ACCESS_KEY=""
NAMESPACE="openobserve-collector"
SKIP_CERT_MANAGER=false
SKIP_OTEL_OPERATOR=false
INTERNAL_ENDPOINT=""

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
    --help                   Show this help message

Examples:
    # Basic installation
    curl -sSL https://raw.githubusercontent.com/openobserve/openobserve/main/deploy/k8s/install.sh | bash -s -- \\
      --cluster-name=production \\
      --o2-url=https://cloud.openobserve.ai \\
      --org-id=default \\
      --access-key=\$(echo -n "user@example.com:passcode" | base64)

    # Install with internal endpoint (same cluster)
    curl -sSL https://raw.githubusercontent.com/openobserve/openobserve/main/deploy/k8s/install.sh | bash -s -- \\
      --cluster-name=production \\
      --org-id=default \\
      --access-key=\$(echo -n "user@example.com:passcode" | base64) \\
      --internal-endpoint=http://o2-openobserve-router.openobserve.svc.cluster.local:5080

    # Skip cert-manager if already installed
    curl -sSL https://raw.githubusercontent.com/openobserve/openobserve/main/deploy/k8s/install.sh | bash -s -- \\
      --cluster-name=production \\
      --o2-url=https://cloud.openobserve.ai \\
      --org-id=default \\
      --access-key=base64key \\
      --skip-cert-manager

EOF
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

# Use internal endpoint if provided, otherwise use external URL
if [ -n "$INTERNAL_ENDPOINT" ]; then
    ENDPOINT="$INTERNAL_ENDPOINT"
    print_info "Using internal cluster endpoint: $ENDPOINT"
else
    ENDPOINT="$O2_URL"
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

print_success "Prerequisites check passed"
echo ""
print_info "Installation configuration:"
print_info "  Cluster Name: $CLUSTER_NAME"
print_info "  Endpoint: $ENDPOINT"
print_info "  Organization ID: $ORG_ID"
print_info "  Namespace: $NAMESPACE"
echo ""

# Install cert-manager
if [ "$SKIP_CERT_MANAGER" = false ]; then
    print_info "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.0/cert-manager.yaml
    print_success "cert-manager installation initiated"

    print_info "Waiting for cert-manager webhook to be ready (this may take 2-3 minutes)..."
    kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment/cert-manager-webhook || {
        print_warning "Webhook not ready yet, waiting additional time..."
        sleep 60
    }
    print_success "cert-manager is ready"
else
    print_info "Skipping cert-manager installation (--skip-cert-manager flag set)"
fi

# Update helm repo
print_info "Adding OpenObserve helm repository..."
helm repo add openobserve https://charts.openobserve.ai
helm repo update
print_success "Helm repository updated"

# Install Prometheus operator CRDs
if [ "$SKIP_OTEL_OPERATOR" = false ]; then
    print_info "Installing Prometheus operator CRDs..."
    kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml 2>/dev/null || kubectl replace -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
    kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml 2>/dev/null || kubectl replace -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
    kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml 2>/dev/null || kubectl replace -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml
    kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml 2>/dev/null || kubectl replace -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml
    print_success "Prometheus operator CRDs installed"

    # Install OpenTelemetry operator
    print_info "Installing OpenTelemetry operator..."
    kubectl apply -f https://raw.githubusercontent.com/openobserve/openobserve-helm-chart/refs/heads/main/opentelemetry-operator.yaml
    print_success "OpenTelemetry operator installed"
else
    print_info "Skipping OpenTelemetry operator installation (--skip-otel-operator flag set)"
fi

# Create namespace
print_info "Creating namespace: $NAMESPACE..."
kubectl create namespace $NAMESPACE 2>/dev/null || print_info "Namespace already exists"
print_success "Namespace ready"

# Install OpenObserve collector
print_info "Installing OpenObserve collector..."
helm --namespace $NAMESPACE \
  upgrade --install o2c openobserve/openobserve-collector \
  --set k8sCluster=$CLUSTER_NAME \
  --set exporters.'otlphttp/openobserve'.endpoint=$ENDPOINT/api/$ORG_ID \
  --set exporters.'otlphttp/openobserve'.headers.Authorization="Basic $ACCESS_KEY" \
  --set exporters.'otlphttp/openobserve_k8s_events'.endpoint=$ENDPOINT/api/$ORG_ID \
  --set exporters.'otlphttp/openobserve_k8s_events'.headers.Authorization="Basic $ACCESS_KEY"

print_success "OpenObserve collector installed successfully!"
echo ""
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
print_success "Installation complete! Check your OpenObserve dashboard for incoming data."
