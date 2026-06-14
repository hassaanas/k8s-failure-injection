#!/bin/bash
# =============================================================================
# Script:  fault-injection-mem-limit.sh
# Purpose: Repeatedly inject a memory-exhaustion fault into the MQTT "broker"
#          pod of the "tod" namespace (MicroK8s) to test the pod's recovery /
#          restart behaviour and measure its recovery time.
#
# What it does (per iteration, 5 iterations total):
#   1. Locates the running broker pod in the "tod" namespace.
#   2. Installs stress-ng inside the pod (Alpine "apk add").
#   3. Runs a memory stressor (--vm 1 --vm-bytes 200M --timeout 2s) to exceed
#      the pod's memory limit and trigger an OOM-kill / restart.
#   4. Waits, then reads the new pod's start time from its logs and prints the
#      injection time vs. recovery time so MTTR can be computed.
#
# Usage:   ./fault-injection-mem-limit.sh
# Requires: microk8s, kubectl access to the "tod" namespace, a "broker" pod,
#           network access inside the pod for "apk add".
# Tunables: mtbf=300  (seconds between runs);  loop count {1..5}.
# =============================================================================
d1=`date`
echo "Starting at $d1"
mtbf=300

for i in {1..5}
do
        broker=`microk8s.kubectl get po -n tod | grep broker | awk '{print $1}'`
        microk8s.kubectl exec -n tod $broker -- /bin/sh -c "apk add --upgrade stress-ng"
        d2=`date`
        echo "Stressing memeory limit of broker pod $broker at $d2"
        microk8s.kubectl exec -n tod $broker -- /bin/sh -c "stress-ng --vm 1 --vm-bytes 200M --timeout 2s"
        #d3=`date`
        #echo "pod deleted at $d3"
        sleep 180
        newBroker=`microk8s.kubectl get po -n tod | grep broker | awk '{print $1}'`
        newPodTime=`microk8s.kubectl logs -n tod $newBroker | grep running | awk '{print $1}' | sed 's/://'`
        echo $newPodTime
        newTime=`date -d @$newPodTime`
        echo "****************************"
        echo "Run # $i"
        echo "****************************"
        echo $newTime | awk '{print $4}'
        echo $d2 | awk '{print $4}'
        #echo $d3 | awk '{print $4}'
        echo "****************************"
        #microk8s.kubectl exec -n tod $broker -- /bin/sh -c "apk add --upgrade stress-ng"
        sleep $mtbf
done


endTime=`date`
echo "Ending at $endTime"


