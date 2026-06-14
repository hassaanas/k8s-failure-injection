# k8s-failure-injection

Fault-injection scripts and measurement clients for evaluating the resilience of
the **ToD (Tele-operated Driving)** application running on Kubernetes (MicroK8s).
The tooling injects resource/availability faults into the MQTT `broker` pod and
measures the impact on message delivery (latency, jitter, recovery time).

## References

The following two research papers explain the use case and experimentation. Please cite these papers if you reuse this code.

[1] H. Siddiqui and F. Khendek, *Microservices for Reliable Safety-Critical Cellular IoT Systems — A Case Study*, in GLOBECOM 2024 - 2024 IEEE Global Communications Conference, Dec. 2024, pp. 1455–1460. doi: [10.1109/GLOBECOM52923.2024.10901455](https://doi.org/10.1109/GLOBECOM52923.2024.10901455)

[2] H. Siddiqui and F. Khendek, *Memory failures in microservices based Cellular IoT systems - An experimental evaluation of service availability*, in 2025 IEEE 102nd Vehicular Technology Conference (VTC2025-Fall), Chengdu, China, Oct. 2025. doi: [10.1109/VTC2025-Fall65116.2025.11309934](https://doi.org/10.1109/VTC2025-Fall65116.2025.11309934)

## Repository layout

```
k8s-failure-injection/
├── fault-injection-scripts/   # Bash scripts that inject faults into pods
│   ├── fault-injection-cpu-limit.sh   # memory stress (see note) of broker pod
│   ├── fault-injection-mem-limit.sh   # memory stress of broker pod (OOM/restart)
│   └── fault-injection-pod-delete.sh  # placeholder: delete-pod recovery test
├── clients/                   # Python MQTT / stress tooling
│   ├── amf-sub.py             # subscribe to set/<topic> and log messages
│   ├── pub-timestamp.py       # publish timestamps every 100 ms (latency source)
│   ├── sub-timestamp.py       # measure inter-arrival gap / jitter
│   └── mem-cpu-stress.py      # in-pod, pure-Python CPU + memory stressor
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

While the measurement clients run, inject a fault into the broker pod:

```bash
./fault-injection-scripts/fault-injection-mem-limit.sh
```

Each run stresses the broker's memory to trigger an OOM-kill/restart, then
reports the injection time vs. the recovered pod's start time so recovery time
(MTTR) can be computed. Tunables (`mtbf`, iteration count) are at the top of the
script.

### 4. In-pod stress (alternative)

To stress a pod from the inside without `stress-ng`, copy `mem-cpu-stress.py`
into the pod and run it; tune `CPU_LOAD`, `DURATION`, and `MEMORY_FRACTION` in
its configuration block.

## Known issues / notes

- `fault-injection-cpu-limit.sh` is currently identical to the mem-limit script
  and stresses **memory**, not CPU. Adjust it to use `stress-ng --cpu` for a true
  CPU fault.
- `fault-injection-pod-delete.sh` is a documented placeholder (no logic yet); a
  suggested skeleton is included in the file.
- The bash scripts assume an Alpine broker image with internet access and use
  fragile log parsing to find the recovered pod's start time.
- The Python clients use the deprecated paho-mqtt v1 callback API; they may need
  updating for paho-mqtt 2.x.
