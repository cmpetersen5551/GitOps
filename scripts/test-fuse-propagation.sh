#!/bin/bash

# FUSE Propagation Test Runner
# This script executes the test plan in order with proper logging
# Usage: ./run-fuse-test.sh

set -e

LOGFILE="fuse-test-$(date +%Y%m%d-%H%M%S).log"
NODE="k3s-w2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_header() {
  echo -e "${BLUE}=== $1 ===${NC}" | tee -a "$LOGFILE"
}

echo_success() {
  echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOGFILE"
}

echo_warning() {
  echo -e "${YELLOW}⚠ $1${NC}" | tee -a "$LOGFILE"
}

echo_error() {
  echo -e "${RED}✗ $1${NC}" | tee -a "$LOGFILE"
}

cmd() {
  echo "[CMD] $@" | tee -a "$LOGFILE"
  "$@" 2>&1 | tee -a "$LOGFILE"
}

# Phase 1: Host Setup
echo_header "PHASE 1: Host Setup on $NODE"
echo "Logging to: $LOGFILE"

echo_header "Checking SSH Access"
if ssh root@$NODE "echo 'SSH OK'" > /dev/null 2>&1; then
  echo_success "SSH access verified"
else
  echo_error "Cannot SSH to root@$NODE"
  exit 1
fi

echo_header "Checking FUSE Module"
if ssh root@$NODE "lsmod | grep fuse" >> "$LOGFILE"; then
  echo_success "FUSE module loaded"
else
  echo_warning "FUSE module not found"
fi

echo_header "Checking Current FUSE Config"
ssh root@$NODE "cat /etc/fuse.conf 2>/dev/null || echo 'No fuse.conf found'" >> "$LOGFILE"

echo_header "Enabling user_allow_other"
ssh root@$NODE "sudo bash -c 'grep -q \"user_allow_other\" /etc/fuse.conf || echo \"user_allow_other\" >> /etc/fuse.conf'" 2>&1 | tee -a "$LOGFILE"
echo_success "user_allow_other configured"

echo_header "Verifying Configuration"
if ssh root@$NODE "grep -q 'user_allow_other' /etc/fuse.conf"; then
  echo_success "user_allow_other is enabled"
else
  echo_error "Failed to enable user_allow_other"
  exit 1
fi

echo_header "Creating Test Directory"
cmd ssh root@$NODE "sudo mkdir -p /tmp/fuse-test-bridge && sudo chmod 755 /tmp/fuse-test-bridge"
cmd ssh root@$NODE "sudo touch /tmp/fuse-test-bridge/.marker-host"
echo_success "Test directory created and ready"

# Phase 2: Deploy Producer
echo_header "PHASE 2: Deploying Producer Pod"

cmd kubectl create namespace fuse-test 2>/dev/null || true
cmd kubectl apply -f clusters/homelab/testing/fuse-propagation-test/namespace.yaml
cmd kubectl apply -f clusters/homelab/testing/fuse-propagation-test/producer.yaml

echo_warning "Waiting 15 seconds for producer to start..."
sleep 15

echo_header "Checking Producer Pod Status"
kubectl get pod -n fuse-test fuse-producer -o wide 2>&1 | tee -a "$LOGFILE"

echo_header "Producer Logs"
if kubectl logs -n fuse-test fuse-producer 2>&1 | tee -a "$LOGFILE" | grep -q "Initial /mnt/dfs"; then
  echo_success "Producer pod is creating files"
else
  echo_warning "Producer logs not yet available (pod may still be starting)"
fi

echo_header "Checking Host-Level Files"
if ssh root@$NODE "ls -la /tmp/fuse-test-bridge/" 2>&1 | tee -a "$LOGFILE" | grep -q "producer"; then
  echo_success "Producer files visible on host"
else
  echo_warning "Producer files not yet visible on host (checking again in 10s)"
  sleep 10
  ssh root@$NODE "ls -la /tmp/fuse-test-bridge/" 2>&1 | tee -a "$LOGFILE"
fi

# Phase 3: Deploy Consumer
echo_header "PHASE 3: Deploying Consumer Pod"

cmd kubectl apply -f clusters/homelab/testing/fuse-propagation-test/consumer.yaml

echo_warning "Waiting 20 seconds for consumer to start and detect producer..."
sleep 20

echo_header "Consumer Pod Status"
kubectl get pod -n fuse-test fuse-consumer -o wide 2>&1 | tee -a "$LOGFILE"

echo_header "Checking Consumer Logs for SUCCESS"
CONSUMER_STATUS=$(kubectl logs -n fuse-test fuse-consumer 2>&1 | tee -a "$LOGFILE")

if echo "$CONSUMER_STATUS" | grep -q "SUCCESS: Producer marker found"; then
  echo_success "CONSUMER SUCCESSFULLY DETECTED PRODUCER!"
  echo_success "FUSE propagation appears to be working!"
else
  if echo "$CONSUMER_STATUS" | grep -q "ERROR"; then
    echo_error "Consumer detected an error"
    echo "Full logs:"
    kubectl logs -n fuse-test fuse-consumer
  else
    echo_warning "Consumer status unclear, checking again..."
    sleep 10
    kubectl logs -n fuse-test fuse-consumer 2>&1 | tee -a "$LOGFILE"
  fi
fi

# Phase 4: Stale Mount Test
echo_header "PHASE 4: Stale Mount Test (Kill Producer)"

echo_warning "Deleting producer pod to test stale mount behavior..."
kubectl delete pod -n fuse-test fuse-producer --grace-period=0 --force 2>&1 | tee -a "$LOGFILE"

echo "Waiting 10 seconds..."
sleep 10

echo_header "Consumer Status After Producer Death"
CONSUMER_STATUS=$(kubectl get pod -n fuse-test fuse-consumer -o wide 2>&1 | tee -a "$LOGFILE")
CONSUMER_LOGS=$(kubectl logs -n fuse-test fuse-consumer 2>&1 | tee -a "$LOGFILE")

if echo "$CONSUMER_LOGS" | grep -q "ERROR: Mount became inaccessible"; then
  echo_warning "Consumer detected mount became inaccessible (expected behavior)"
  echo_warning "This means stale mounts are detectable → can implement auto-recovery"
elif echo "$CONSUMER_LOGS" | grep -q "Mount is accessible"; then
  echo_success "Consumer mount still accessible (surprising but good)"
else
  echo_warning "Consumer status unknown"
fi

# Phase 5: Recovery Test
echo_header "PHASE 5: Producer Recovery Test"

echo_warning "Redeploying producer pod..."
cmd kubectl apply -f clusters/homelab/testing/fuse-propagation-test/producer.yaml

sleep 15

echo_header "Checking if Consumer Automatically Recovered"
CONSUMER_STATUS=$(kubectl get pod -n fuse-test fuse-consumer -o wide 2>&1 | tee -a "$LOGFILE")

if echo "$CONSUMER_STATUS" | grep -q "Running"; then
  echo_success "Consumer is still running"
  CONSUMER_LOGS=$(kubectl logs -n fuse-test fuse-consumer 2>&1 | tee -a "$LOGFILE")
  if echo "$CONSUMER_LOGS" | grep -q "Mount is accessible"; then
    echo_success "Consumer mount recovered without explicit restart!"
  else
    echo_warning "Consumer mount state unclear"
  fi
else
  echo_warning "Consumer pod status changes detected"
fi

# Summary
echo_header "TEST SUMMARY"
echo "All test phases complete. Results logged to: $LOGFILE"
echo ""
echo "Next Steps:"
echo "1. Review $LOGFILE for detailed output"
echo "2. Check if test shows FUSE propagation works:"
echo "   - grep 'SUCCESS: Producer marker found' $LOGFILE"
echo "3. Check mount stale behavior:"
echo "   - grep 'inaccessible' $LOGFILE"
echo ""
echo "Cleanup (when ready):"
echo "  kubectl delete namespace fuse-test"
echo "  ssh root@$NODE 'sudo rm -rf /tmp/fuse-test-bridge'"
echo ""

echo_header "DONE"
