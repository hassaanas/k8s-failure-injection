#!/bin/bash
# =============================================================================
# Script:  fault-injection-mem-limit-app.sh
# Purpose: Inject a memory-exhaustion fault into a "ms-tod-app" MICROSERVICE pod
#          (e.g. ms-speed / ms-direction / ms-cruise) of the "tod" namespace and
#          measure how long the CONTAINER takes to restart in place and become
#          Ready again (container-restart recovery time / MTTR).
#
# Container restart vs. pod restart:
#   This script measures a CONTAINER RESTART, NOT a pod recreation. An OOM-kill
#   restarts the container *inside the same pod*: the pod keeps its name, UID,
#   node and IP, and only its RESTARTS count increases. (For full pod deletion/
#   recreation, use fault-injection-pod-delete.sh instead.)
#
# Intended target / image:
#   ms-tod-app microservices  ->  image localhost:5000/ms-tod-app:v1
#   Base: python:3.11-slim (DEBIAN). stress-ng + procps are BAKED INTO the image
#   (see docker-images/Dockerfile-tod-app-v2), so NO in-pod install is required.
#   This is the key difference vs. fault-injection-mem-limit.sh, which targets
#   the Alpine eclipse-mosquitto "broker" pod and must "apk add" stress-ng first.
#
# What it does (per iteration, $RUNS iterations total):
#   1. Locates the target pod (name contains $POD_MATCH) and reads its current
#      container restartCount.
#   2. Runs the pre-installed stress-ng directly (no install) to allocate more
#      memory than the container's limit (100Mi by default) -> OOM-kill.
#   3. Polls the SAME pod until its restartCount increments (container restarted)
#      and the pod is Ready again, or times out.
#   4. Prints per-run recovery time and an average MTTR.
#
# Usage:   ./fault-injection-mem-limit-app.sh
#          POD_MATCH=ms-direction ./fault-injection-mem-limit-app.sh
#          RUNS=3 MTBF=60 VM_BYTES=250M ./fault-injection-mem-limit-app.sh
#
# Requires: microk8s, kubectl access to the "tod" namespace, a running
#           ms-tod-app pod. NO in-pod internet needed (stress-ng pre-baked).
# Tunables (env vars below): NAMESPACE, POD_MATCH, CONTAINER, RUNS, MTBF,
#           VM_WORKERS, VM_BYTES, STRESS_TIMEOUT, RECOVERY_TIMEOUT,
#           POLL_INTERVAL, KUBECTL.
#
# CAVEAT (will the container actually restart?):
#   stress-ng runs as a CHILD of the container's PID 1 (the app loop). For the
#   container to restart, the OOM-killer must take down the whole container:
#     - On cgroup v2 with memory.oom.group=1 (default for k8s containers on
#       modern MicroK8s), the entire cgroup is killed together -> container
#       restarts. This is the expected case.
#     - On older cgroup v1, the kernel may kill only the stress-ng child and
#       leave PID 1 alive -> NO restart. If you see no restart, lower the pod's
#       memory limit or raise VM_BYTES/VM_WORKERS so the kill is unavoidable.
# =============================================================================
set -u

# ===== CONFIGURATION (overridable via environment) =====
NAMESPACE="${NAMESPACE:-tod}"
POD_MATCH="${POD_MATCH:-ms-speed}"      # microservice pod name substring
CONTAINER="${CONTAINER:-}"              # container name (empty = first container)
RUNS="${RUNS:-5}"                       # number of injection iterations
MTBF="${MTBF:-300}"                     # seconds to wait between iterations
VM_WORKERS="${VM_WORKERS:-1}"           # stress-ng --vm workers
VM_BYTES="${VM_BYTES:-200M}"            # memory per worker (must exceed limit)
STRESS_TIMEOUT="${STRESS_TIMEOUT:-10s}" # how long stress-ng runs
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}"  # max seconds to wait for restart
POLL_INTERVAL="${POLL_INTERVAL:-2}"     # seconds between polls
KUBECTL="${KUBECTL:-microk8s.kubectl}"
# =======================================================

# Print the name of the first pod whose name contains $POD_MATCH.
get_target_pod() {
    $KUBECTL get po -n "$NAMESPACE" --no-headers 2>/dev/null \
        | grep "$POD_MATCH" | awk '{print $1}' | head -n1
}

# jsonpath selecting the tracked container's status entry (by name if CONTAINER
# is set, otherwise the first container [0]).
container_status_path() {
    if [ -n "$CONTAINER" ]; then
        echo "{.status.containerStatuses[?(@.name==\"$CONTAINER\")]"
    else
        echo "{.status.containerStatuses[0]"
    fi
}

# Print the restartCount of the tracked container in pod $1 (empty if unknown).
get_restart_count() {
    $KUBECTL get po -n "$NAMESPACE" "$1" \
        -o jsonpath="$(container_status_path).restartCount}" 2>/dev/null
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

echo "Starting at $(date)"
echo "namespace=$NAMESPACE  pod match='$POD_MATCH'  runs=$RUNS  mtbf=${MTBF}s"
echo "stressor: stress-ng --vm $VM_WORKERS --vm-bytes $VM_BYTES --timeout $STRESS_TIMEOUT (pre-baked, no install)"
echo "measuring: CONTAINER restart in place (same pod), not pod recreation"

total_recovery=0
recovered_runs=0

for i in $(seq 1 "$RUNS"); do
    pod=$(get_target_pod)
    if [ -z "$pod" ]; then
        echo "ERROR: no pod matching '$POD_MATCH' found in namespace '$NAMESPACE'. Aborting."
        exit 1
    fi
    oldRestarts=$(get_restart_count "$pod")
    [ -z "$oldRestarts" ] && oldRestarts=0

    injectEpoch=$(date +%s)
    echo "===================================="
    echo "Run #$i"
    echo "Stressing memory of pod '$pod' (restarts=$oldRestarts) at $(date -d @"$injectEpoch")"
    # stress-ng is pre-installed in the ms-tod-app image; call it directly.
    # The exec is expected to be OOM-killed (non-zero exit) — that is the fault.
    $KUBECTL exec -n "$NAMESPACE" "$pod" -- \
        /bin/sh -c "stress-ng --vm $VM_WORKERS --vm-bytes $VM_BYTES --timeout $STRESS_TIMEOUT" \
        || echo "(stress-ng exec returned non-zero — expected on OOM-kill)"

    # Wait for the SAME pod's container to restart (restartCount increments) and
    # become Ready again, within the recovery timeout.
    restarted=0
    elapsed=0
    while [ "$elapsed" -lt "$RECOVERY_TIMEOUT" ]; do
        newRestarts=$(get_restart_count "$pod")
        [ -z "$newRestarts" ] && newRestarts="$oldRestarts"
        if [ "$newRestarts" -gt "$oldRestarts" ] && pod_ready "$pod"; then
            restarted=1
            break
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    readyEpoch=$(date +%s)
    if [ "$restarted" -eq 1 ]; then
        recovery=$((readyEpoch - injectEpoch))
        total_recovery=$((total_recovery + recovery))
        recovered_runs=$((recovered_runs + 1))
        echo "Container restarted in pod '$pod' (restarts=$oldRestarts -> $newRestarts), Ready at $(date -d @"$readyEpoch")"
        echo "Recovery time (MTTR) for run #$i: ${recovery}s"
    else
        echo "WARNING: container did not restart within ${RECOVERY_TIMEOUT}s"
        echo "         The OOM-killer likely killed only the stress-ng child and"
        echo "         left PID 1 alive (see CAVEAT). Lower the memory limit or"
        echo "         raise VM_BYTES/VM_WORKERS. Check: kubectl get po -n $NAMESPACE"
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
