# k8s-failure-injection — Kubernetes Chaos Engineering & Fault Injection Toolkit

> Lightweight **chaos engineering / fault injection** scripts for **Kubernetes**
> (and **MicroK8s**) that inject **memory (OOM)**, **CPU**, and **pod-delete**
> faults, then measure **service availability**, **recovery time (MTTR)**, and
> **MQTT** message **latency / jitter** — used for **resilience testing** of a
> safety-critical **IoT / teleoperated driving (ToD)** microservices application.

Fault-injection scripts and measurement clients for evaluating the **resilience**
and **service availability** of microservices running on **Kubernetes
(MicroK8s)**. The toolkit deliberately breaks pods — exhausting memory with
`stress-ng` to force **OOM-kills / container restarts**, or deleting pods to test
**rescheduling** — and measures the impact on real-time **MQTT** message delivery
(latency, jitter) and **mean time to recovery (MTTR)**. The reference workload is
a **tele-operated driving (ToD)** cellular-IoT application, but the scripts work
against any pod.

**Keywords:** Kubernetes · chaos engineering · fault injection · resilience
testing · reliability engineering · MicroK8s · kubectl · OOM kill · memory
pressure · CPU stress · stress-ng · pod failure · container restart · MTTR ·
high availability · MQTT · Mosquitto · IoT · edge computing · microservices ·
SRE · DevOps · teleoperated / tele-operated driving · 5G / cellular IoT.

## Features

- **Memory-exhaustion (OOM) fault injection** via `stress-ng` — for both
  Alpine (`eclipse-mosquitto` broker) and Debian (`ms-tod-app`) pods.
- **Pod-delete fault injection** to test Kubernetes self-healing / rescheduling.
- **Automated recovery-time (MTTR) measurement** — container-restart and
  pod-recreation detection via `restartCount` / pod UID polling.
- **MQTT latency & jitter measurement** clients (publish/subscribe timestamping).
- **Dependency-free in-pod stressor** (pure-Python CPU + memory load, no
  `stress-ng`/`apt`/`apk` required).
- **Repeatable experiment loops** with configurable **MTBF**, run count, and load.

## References

The following two research papers explain the use case and experimentation. Please cite these papers if you reuse this code.

[1] H. Siddiqui and F. Khendek, *Microservices for Reliable Safety-Critical Cellular IoT Systems — A Case Study*, in GLOBECOM 2024 - 2024 IEEE Global Communications Conference, Dec. 2024, pp. 1455–1460. doi: [10.1109/GLOBECOM52923.2024.10901455](https://doi.org/10.1109/GLOBECOM52923.2024.10901455)

[2] H. Siddiqui and F. Khendek, *Memory failures in microservices based Cellular IoT systems - An experimental evaluation of service availability*, in 2025 IEEE 102nd Vehicular Technology Conference (VTC2025-Fall), Chengdu, China, Oct. 2025. doi: [10.1109/VTC2025-Fall65116.2025.11309934](https://doi.org/10.1109/VTC2025-Fall65116.2025.11309934)

## Repository layout

```
k8s-failure-injection/
├── fault-injection-scripts/   # Fault injectors / stress payloads
│   ├── fault-injection-cpu-limit.sh       # mem stress of BROKER pod (apk install)
│   ├── fault-injection-mem-limit.sh       # mem stress of BROKER pod (apk install)
│   ├── fault-injection-mem-limit-app.sh   # mem stress of ms-tod-app pods (no install)
│   ├── fault-injection-pod-delete.sh      # delete any pod, measure recovery (MTTR)
│   └── mem-cpu-stress.py                  # in-pod, pure-Python CPU + memory stressor
├── clients/                   # Python MQTT measurement clients
│   ├── amf-sub.py             # subscribe to set/<topic> and log messages
│   ├── pub-timestamp.py       # publish timestamps every 100 ms (latency source)
│   └── sub-timestamp.py       # measure inter-arrival gap / jitter
└── results/                   # Experiment output (git-ignored data)
    ├── obu/                   # on-board-unit experiment logs
    ├── edge/                  # edge experiment logs
    └── rds/                   # remote-driving-station experiment logs
```

> Files under `results/` (`*.log`, `*.txt`) are **not** tracked in git — they are
> large generated artifacts. The directories are kept via `.gitkeep`.

## Prerequisites

- A running [MicroK8s](https://microk8s.io/) cluster with the ToD app deployed in
  the `tod` namespace (must include a pod whose name contains `broker`).
- `microk8s.kubectl` access to the `tod` namespace.
- The broker pod image must be Alpine-based with network access (the stress
  scripts `apk add stress-ng` inside the pod).
- Python 3 with [`paho-mqtt`](https://pypi.org/project/paho-mqtt/) for the
  clients:

  ```bash
  pip install paho-mqtt
  ```

## Configuration

The Python clients read the broker address from environment variables:

| Variable     | Used by                                  | Default (amf-sub only) |
| ------------ | ---------------------------------------- | ---------------------- |
| `BROKERIP`   | all clients                              | `127.0.0.1`            |
| `BROKERPORT` | all clients                              | `1883`                 |

```bash
export BROKERIP=10.152.183.84
export BROKERPORT=1883
```

> Note: `pub-timestamp.py` and `sub-timestamp.py` require both variables to be
> set (they have no defaults and will error otherwise).

## Usage

### 1. Measure latency / jitter

In one terminal, start the timestamp publisher (publishes to `set/<ms>` every
100 ms):

```bash
./clients/pub-timestamp.py speed
```

In another terminal, start the subscriber that reports inter-arrival gaps and
flags any delivery gap > 110 ms:

```bash
./clients/sub-timestamp.py speed
```

### 2. Log actuation commands

```bash
# ./clients/amf-sub.py <topic_suffix> [log_file]
./clients/amf-sub.py speed                 # -> logs to mqtt_log_speed.txt
./clients/amf-sub.py direction mylog.txt   # -> logs to mylog.txt
```

### 3. Inject a fault

Pick the injector that matches the **target pod's image** (this matters because
`stress-ng` must be available inside the pod):

| Target pod | Image / base | Injector | In-pod install? |
| ---------- | ------------ | -------- | --------------- |
| `broker` | `eclipse-mosquitto` (Alpine) | `fault-injection-mem-limit.sh` (or `-cpu-limit.sh`) | Yes — `apk add stress-ng` (needs in-pod network) |
| `ms-tod-app` (`ms-speed`, `ms-direction`, `ms-cruise`) | `ms-tod-app:v1` (Debian, `python:3.11-slim`) | `fault-injection-mem-limit-app.sh` | No — `stress-ng` is baked into the image |
| any pod | image-agnostic | `fault-injection-pod-delete.sh` | No — only deletes the pod |

Stress the **broker** (installs stress-ng in-pod):

```bash
./fault-injection-scripts/fault-injection-mem-limit.sh
```

Stress a **ms-tod-app microservice** (uses the pre-baked stress-ng, no install):

```bash
./fault-injection-scripts/fault-injection-mem-limit-app.sh                 # default ms-speed
POD_MATCH=ms-direction ./fault-injection-scripts/fault-injection-mem-limit-app.sh
```

Delete a pod and measure recovery (works on any pod):

```bash
./fault-injection-scripts/fault-injection-pod-delete.sh                    # default broker
POD_MATCH=ms-speed ./fault-injection-scripts/fault-injection-pod-delete.sh
```

Each injector loops `$RUNS` times and reports the per-run recovery time and an
average MTTR. Tunables are env vars / variables at the top of each script.

### 4. In-pod stress (alternative)

To stress a pod from the inside without `stress-ng`, copy `mem-cpu-stress.py`
into the pod and run it; tune `CPU_LOAD`, `DURATION`, and `MEMORY_FRACTION` in
its configuration block. Note it is deliberately *safe* (sub-limit) and will
**not** trigger an OOM/restart.

## Known issues / notes

- `fault-injection-cpu-limit.sh` is currently identical to the mem-limit script
  and stresses **memory**, not CPU. Adjust it to use `stress-ng --cpu` for a true
  CPU fault.
- The broker injectors `apk add stress-ng` at runtime, so the broker pod needs
  in-pod network egress; the app injector avoids this by relying on the baked-in
  binary.
- `fault-injection-mem-limit-app.sh` measures a **container restart in place**
  (same pod, `RESTARTS` increments) — not pod recreation. On cgroup v2 with
  `memory.oom.group=1` the whole container is OOM-killed and restarts; on older
  cgroup v1 the killer may only kill the `stress-ng` child and leave PID 1
  alive (no restart). If that happens, lower the pod's memory limit or raise
  `VM_BYTES`/`VM_WORKERS` (see the script's CAVEAT).
- Detection methods differ by script: the original broker scripts parse logs
  for the recovered pod's start time; `*-app.sh` watches the container's
  `restartCount`; `pod-delete.sh` watches for a new pod UID (pod recreation).
- The Python clients use the deprecated paho-mqtt v1 callback API; they may need
  updating for paho-mqtt 2.x.

## Keywords

Kubernetes fault injection, Kubernetes chaos engineering, MicroK8s chaos testing,
pod failure simulation, OOM kill testing, memory limit stress test, CPU stress
Kubernetes, container restart, pod delete recovery, mean time to recovery (MTTR),
service availability measurement, MQTT latency benchmark, Mosquitto broker
failure, IoT resilience, edge computing reliability, microservices fault
tolerance, SRE/DevOps testing, teleoperated driving, 5G cellular IoT.
