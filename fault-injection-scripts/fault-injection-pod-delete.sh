#!/bin/bash
# =============================================================================
# Script:  fault-injection-pod-delete.sh
# Purpose: Inject a "pod delete" availability fault into the MQTT "broker" pod
#          of the "tod" namespace (MicroK8s) and measure how long Kubernetes
#          takes to reschedule and make a fresh pod Ready again (recovery time /
#          MTTR). Companion to the cpu/mem stress fault injectors.
#
# What it does (per iteration, $RUNS iterations total):
#   1. Locates the current broker pod and records its UID + delete time.
#   2. Deletes the pod (the controller, e.g. Deployment/StatefulSet, recreates
#      it). Set FORCE=1 to force-delete with grace period 0.
#   3. Polls until a *different* broker pod (new UID) reaches Running+Ready, or
#      until $RECOVERY_TIMEOUT is exceeded.
#   4. Prints the recovery time so MTTR can be computed across runs.
#
# Usage:   ./fault-injection-pod-delete.sh
#          FORCE=1 ./fault-injection-pod-delete.sh      # force delete
#          RUNS=3 MTBF=60 ./fault-injection-pod-delete.sh
#
# Requires: microk8s, kubectl access to the "tod" namespace, a "broker" pod
#           managed by a controller that recreates it after deletion.
# Tunables (env vars below): NAMESPACE, POD_MATCH, RUNS, MTBF,
#           RECOVERY_TIMEOUT, POLL_INTERVAL, FORCE.
# =============================================================================
set -u

# ===== CONFIGURATION (overridable via environment) =====
NAMESPACE="${NAMESPACE:-tod}"
POD_MATCH="${POD_MATCH:-broker}"        # substring used to find the target pod
RUNS="${RUNS:-5}"                       # number of delete iterations
MTBF="${MTBF:-300}"                     # seconds to wait between iterations
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}"  # max seconds to wait for recovery
POLL_INTERVAL="${POLL_INTERVAL:-2}"     # seconds between readiness polls
FORCE="${FORCE:-0}"                     # 1 = force delete (grace period 0)
KUBECTL="${KUBECTL:-microk8s.kubectl}"
# =======================================================

# Print the name of the first pod whose name contains $POD_MATCH.
get_broker_pod() {
    $KUBECTL get po -n "$NAMESPACE" --no-headers 2>/dev/null \
        | grep "$POD_MATCH" | awk '{print $1}' | head -n1
}

# Return 0 if pod $1 is Running and Ready.
pod_ready() {
    local phase ready
    phase=$($KUBECTL get po -n "$NAMESPACE" "$1" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
    ready=$($KUBECTL get po -n "$NAMESPACE" "$1" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [ "$phase" = "Running" ] && [ "$ready" = "True" ]
}

# Print the name of a Ready broker pod whose UID differs from $1 (the deleted
# pod). This correctly detects recovery for both Deployments (new pod name) and
# StatefulSets (same name, new UID).
find_recovered_pod() {
    local oldUid="$1" pod uid
    for pod in $($KUBECTL get po -n "$NAMESPACE" --no-headers 2>/dev/null \
                    | grep "$POD_MATCH" | awk '{print $1}'); do
        pod_ready "$pod" || continue
        uid=$($KUBECTL get po -n "$NAMESPACE" "$pod" \
                -o jsonpath='{.metadata.uid}' 2>/dev/null)
        if [ -n "$uid" ] && [ "$uid" != "$oldUid" ]; then
            echo "$pod"
            return 0
        fi
    done
    return 1
}

echo "Starting at $(date)"
echo "namespace=$NAMESPACE  pod match='$POD_MATCH'  runs=$RUNS  mtbf=${MTBF}s  force=$FORCE"

total_recovery=0
recovered_runs=0

for i in $(seq 1 "$RUNS"); do
    oldPod=$(get_broker_pod)
    if [ -z "$oldPod" ]; then
        echo "ERROR: no pod matching '$POD_MATCH' found in namespace '$NAMESPACE'. Aborting."
        exit 1
    fi
    oldUid=$($KUBECTL get po -n "$NAMESPACE" "$oldPod" \
                -o jsonpath='{.metadata.uid}' 2>/dev/null)

    deleteEpoch=$(date +%s)
    echo "===================================="
    echo "Run #$i"
    echo "Deleting broker pod '$oldPod' (uid=$oldUid) at $(date -d @"$deleteEpoch")"
    if [ "$FORCE" = "1" ]; then
        $KUBECTL delete po -n "$NAMESPACE" "$oldPod" --grace-period=0 --force --wait=false
    else
        $KUBECTL delete po -n "$NAMESPACE" "$oldPod" --wait=false
    fi

    # Poll for a fresh Ready broker pod within the recovery timeout.
    recovered=""
    elapsed=0
    while [ "$elapsed" -lt "$RECOVERY_TIMEOUT" ]; do
        if candidate=$(find_recovered_pod "$oldUid"); then
            recovered="$candidate"
            break
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    readyEpoch=$(date +%s)
    if [ -n "$recovered" ]; then
        recovery=$((readyEpoch - deleteEpoch))
        total_recovery=$((total_recovery + recovery))
        recovered_runs=$((recovered_runs + 1))
        echo "Recovered as pod '$recovered' at $(date -d @"$readyEpoch")"
        echo "Recovery time (MTTR) for run #$i: ${recovery}s"
    else
        echo "WARNING: no fresh Ready broker pod within ${RECOVERY_TIMEOUT}s"
    fi
    echo "===================================="

    if [ "$i" -lt "$RUNS" ]; then
        echo "Sleeping ${MTBF}s before next run..."
        sleep "$MTBF"
    fi
done

if [ "$recovered_runs" -gt 0 ]; then
    echo "Average recovery time over $recovered_runs run(s): $((total_recovery / recovered_runs))s"
fi
echo "Ending at $(date)"
