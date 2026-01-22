#!/bin/bash

# OpenObserve Kubernetes Collector Uninstaller
# Usage: ./uninstall.sh [OPTIONS]
#
# Features:
#   - ✅ Safe defaults: Only removes collector, keeps shared components
#   - ✅ Selective removal: Choose what to remove with flags
#   - ✅ Dry-run mode: Preview what will be removed
#   - ✅ Safety checks: Warns about resources using CRDs
#   - ✅ Confirmation prompts: Prevents accidental deletion (skip with --force)
#   - ✅ Verification commands: Shows how to verify cleanup
#
# Usage Examples:
#   # Preview what will be removed (dry-run)
#   ./uninstall.sh --dry-run
#
#   # Remove only the collector (safe, keeps cert-manager, operators)
#   ./uninstall.sh
#
#   # Remove everything including shared components
#   ./uninstall.sh --remove-all
#
#   # Remove everything without prompts
#   ./uninstall.sh --remove-all --force
#
#   # Remove with custom namespace
#   ./uninstall.sh --namespace=my-collector
#
#   # Remove collector and operators, keep cert-manager
#   ./uninstall.sh --remove-otel-operator --remove-prometheus-crds
#
# Options:
#   --namespace=NS              Custom namespace (default: openobserve-collector)
#   --remove-cert-manager       Remove cert-manager
#   --remove-otel-operator      Remove OpenTelemetry operator
#   --remove-prometheus-crds    Remove Prometheus CRDs
#   --remove-all                Remove everything
#   --dry-run                   Show what would be removed
#   --force                     Skip confirmation prompts
#
# Safety Features:
#   - Warns if removing shared components
#   - Checks for existing resources using CRDs before removal
#   - Provides verification commands after uninstall
#   - Handles timeouts gracefully

set -e

# Default values
NAMESPACE="openobserve-collector"
REMOVE_CERT_MANAGER=false
REMOVE_OTEL_OPERATOR=false
REMOVE_PROMETHEUS_CRDS=false
DRY_RUN=false
FORCE=false

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
OpenObserve Kubernetes Collector Uninstaller

Usage:
    $0 [OPTIONS]

Options:
    --namespace=NS              Namespace where collector is installed (default: openobserve-collector)
    --remove-cert-manager       Also remove cert-manager
    --remove-otel-operator      Also remove OpenTelemetry operator
    --remove-prometheus-crds    Also remove Prometheus operator CRDs
    --remove-all                Remove all components (collector, operators, cert-manager, CRDs)
    --dry-run                   Show what would be removed without actually removing
    --force                     Skip confirmation prompts
    --help                      Show this help message

Examples:
    # Remove only the collector (safe, keeps shared components)
    ./uninstall.sh

    # Remove everything (including shared components)
    ./uninstall.sh --remove-all

    # Dry run to see what would be removed
    ./uninstall.sh --remove-all --dry-run

    # Remove with custom namespace
    ./uninstall.sh --namespace=my-namespace

EOF
}

# Parse arguments
for arg in "$@"; do
    case $arg in
        --namespace=*)
            NAMESPACE="${arg#*=}"
            shift
            ;;
        --remove-cert-manager)
            REMOVE_CERT_MANAGER=true
            shift
            ;;
        --remove-otel-operator)
            REMOVE_OTEL_OPERATOR=true
            shift
            ;;
        --remove-prometheus-crds)
            REMOVE_PROMETHEUS_CRDS=true
            shift
            ;;
        --remove-all)
            REMOVE_CERT_MANAGER=true
            REMOVE_OTEL_OPERATOR=true
            REMOVE_PROMETHEUS_CRDS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
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

# Show what will be removed
print_info "Uninstallation plan:"
echo ""
print_info "Will remove:"
print_info "  ✓ OpenObserve Collector (namespace: $NAMESPACE)"

if [ "$REMOVE_OTEL_OPERATOR" = true ]; then
    print_info "  ✓ OpenTelemetry Operator"
fi

if [ "$REMOVE_PROMETHEUS_CRDS" = true ]; then
    print_info "  ✓ Prometheus Operator CRDs"
fi

if [ "$REMOVE_CERT_MANAGER" = true ]; then
    print_info "  ✓ cert-manager"
fi

echo ""
print_info "Will keep:"

if [ "$REMOVE_OTEL_OPERATOR" = false ]; then
    print_info "  - OpenTelemetry Operator (shared component)"
fi

if [ "$REMOVE_PROMETHEUS_CRDS" = false ]; then
    print_info "  - Prometheus Operator CRDs (shared component)"
fi

if [ "$REMOVE_CERT_MANAGER" = false ]; then
    print_info "  - cert-manager (shared component)"
fi

echo ""

# Dry run mode
if [ "$DRY_RUN" = true ]; then
    print_success "Dry run mode: No changes will be made"
    exit 0
fi

# Confirmation prompt
if [ "$FORCE" = false ]; then
    print_warning "This will remove the components listed above."
    if [ "$REMOVE_CERT_MANAGER" = true ] || [ "$REMOVE_OTEL_OPERATOR" = true ] || [ "$REMOVE_PROMETHEUS_CRDS" = true ]; then
        print_warning "WARNING: Removing shared components may affect other applications in the cluster!"
    fi
    read -p "Continue with uninstallation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Uninstallation cancelled"
        exit 0
    fi
fi

echo ""
print_info "Starting uninstallation..."
echo ""

# Remove OpenObserve Collector
print_info "Removing OpenObserve Collector..."
if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "o2c"; then
    if helm uninstall o2c -n "$NAMESPACE" --timeout=120s; then
        print_success "OpenObserve Collector removed"
    else
        print_error "Failed to remove OpenObserve Collector"
        print_info "You may need to manually clean up with: helm uninstall o2c -n $NAMESPACE"
    fi
else
    print_warning "OpenObserve Collector not found in namespace $NAMESPACE"
fi

# Remove namespace
print_info "Removing namespace: $NAMESPACE..."
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    if kubectl delete namespace "$NAMESPACE" --timeout=60s 2>/dev/null; then
        print_success "Namespace removed"
    else
        print_warning "Namespace deletion initiated but may take time to complete"
        print_info "Check status with: kubectl get namespace $NAMESPACE"
    fi
else
    print_warning "Namespace $NAMESPACE does not exist"
fi

# Remove OpenTelemetry Operator
if [ "$REMOVE_OTEL_OPERATOR" = true ]; then
    echo ""
    print_info "Removing OpenTelemetry Operator..."

    # Check if operator is installed
    if kubectl get namespace opentelemetry-operator-system &>/dev/null; then
        # Remove operator resources
        if kubectl delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.115.0/opentelemetry-operator.yaml --timeout=60s 2>/dev/null; then
            print_success "OpenTelemetry Operator removed"
        else
            print_warning "Failed to remove OpenTelemetry Operator automatically"
            print_info "Try manually: kubectl delete namespace opentelemetry-operator-system"
        fi
    else
        print_warning "OpenTelemetry Operator not found"
    fi
fi

# Remove Prometheus Operator CRDs
if [ "$REMOVE_PROMETHEUS_CRDS" = true ]; then
    echo ""
    print_info "Removing Prometheus Operator CRDs..."

    # Check if CRDs exist and if any resources are using them
    crds_to_remove=()
    crds_with_resources=()

    for crd in servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com scrapeconfigs.monitoring.coreos.com probes.monitoring.coreos.com; do
        if kubectl get crd "$crd" &>/dev/null; then
            crds_to_remove+=("$crd")
            # Check if any resources exist
            count=$(kubectl get "$crd" --all-namespaces --no-headers 2>/dev/null | wc -l)
            if [ "$count" -gt 0 ]; then
                crds_with_resources+=("$crd: $count resources")
            fi
        fi
    done

    if [ ${#crds_with_resources[@]} -gt 0 ]; then
        print_warning "Found existing resources using Prometheus CRDs:"
        for res in "${crds_with_resources[@]}"; do
            print_warning "  - $res"
        done

        if [ "$FORCE" = false ]; then
            print_warning "Removing these CRDs will delete all associated resources!"
            read -p "Continue with CRD removal? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Skipping CRD removal"
                REMOVE_PROMETHEUS_CRDS=false
            fi
        fi
    fi

    if [ "$REMOVE_PROMETHEUS_CRDS" = true ] && [ ${#crds_to_remove[@]} -gt 0 ]; then
        for crd in "${crds_to_remove[@]}"; do
            if kubectl delete crd "$crd" --timeout=30s 2>/dev/null; then
                print_success "Removed CRD: $crd"
            else
                print_warning "Failed to remove CRD: $crd"
            fi
        done
    else
        print_warning "No Prometheus Operator CRDs found"
    fi
fi

# Remove cert-manager
if [ "$REMOVE_CERT_MANAGER" = true ]; then
    echo ""
    print_info "Removing cert-manager..."

    if kubectl get namespace cert-manager &>/dev/null; then
        print_warning "Removing cert-manager may affect other applications using certificates!"

        if [ "$FORCE" = false ]; then
            read -p "Are you sure you want to remove cert-manager? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Skipping cert-manager removal"
                REMOVE_CERT_MANAGER=false
            fi
        fi

        if [ "$REMOVE_CERT_MANAGER" = true ]; then
            if kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.0/cert-manager.yaml --timeout=120s 2>/dev/null; then
                print_success "cert-manager removed"
            else
                print_warning "Failed to remove cert-manager automatically"
                print_info "Try manually: kubectl delete namespace cert-manager"
            fi
        fi
    else
        print_warning "cert-manager not found"
    fi
fi

echo ""
print_success "Uninstallation complete!"
echo ""

# Show cleanup verification commands
print_info "Verification commands:"
print_info "  Check namespace:           kubectl get namespace $NAMESPACE"
print_info "  Check helm releases:       helm list -A"

if [ "$REMOVE_OTEL_OPERATOR" = true ]; then
    print_info "  Check OTel operator:       kubectl get namespace opentelemetry-operator-system"
fi

if [ "$REMOVE_PROMETHEUS_CRDS" = true ]; then
    print_info "  Check Prometheus CRDs:     kubectl get crd | grep monitoring.coreos.com"
fi

if [ "$REMOVE_CERT_MANAGER" = true ]; then
    print_info "  Check cert-manager:        kubectl get namespace cert-manager"
fi

echo ""
print_info "If any resources remain, they may be in terminating state. Wait a few minutes and check again."
