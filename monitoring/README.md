# Cluster upgrade monitoring

Monitor the OpenShift/ACM hub cluster until it is stable during or after an upgrade.

## Usage

**KUBECONFIG** can be set in the environment or passed on the CLI:

```bash
export KUBECONFIG=/home/midu/kubeconfig
python3 cluster_monitor.py
```

Or:

```bash
python3 cluster_monitor.py --kubeconfig /home/midu/kubeconfig
```

**Auto-approve InstallPlans** (optional):

```bash
python3 cluster_monitor.py --installplan
```

Without `--installplan`, pending InstallPlans are shown but not approved; approve them manually (e.g. in the console or with `oc patch installplan ...`).

**Polling interval** (default 60s):

```bash
python3 cluster_monitor.py --interval 120
```

**Require stable for N seconds before exiting** (default 0 = exit as soon as all checks pass once):

```bash
python3 cluster_monitor.py --stable-for 300
```

With `--stable-for 300`, the script exits with rc 0 only after the cluster has passed all stability checks for 300 seconds (5 minutes) in a row. If any check fails, the timer resets.

**API server metrics** (same format as `collect-apiserver-metrics.sh` / `collect-apiserver-metrics-day2.sh`):

```bash
python3 cluster_monitor.py --apiserver-metrics
```

With `--apiserver-metrics`, each loop collects Prometheus API server metrics (up, success rate, P99 latency, request rate, upgrade progress, operator progress) and writes them under a **release-specific directory** derived from the cluster version, e.g. `./data/release-419/` for 4.19.x or `./data/release-420/` for 4.20.x. The base directory can be set with `--data-dir` (default: `data`). Subdirectories are created if missing (`./data` and `./data/release-XXX/`); existing directories are reused. When the monitor exits (cluster stable or Ctrl+C), it prints a **composed API server availability summary** for the entire upgrade (samples, full/partial/degraded/outage counts, success rate, P99 latency) and writes `apiserver-availability-summary.json` in that release directory.

## What it does

Each loop iteration runs:

- `oc get cgu -A`
- `oc get clusterversion`
- `oc get co`
- `oc get policies -n local-cluster`
- `oc get nodes`
- `oc get mcp`
- `oc get installplan -A`
- `oc get csv -A` (ClusterServiceVersion – operator Installing/Succeeded status)

If `--installplan` is set, it approves all pending InstallPlans.

If `--apiserver-metrics` is set, each iteration also collects API server metrics from Prometheus/Thanos (same queries as `collect-apiserver-metrics.sh` and day-2 operator progress as in `collect-apiserver-metrics-day2.sh`) and appends to CSVs under `./data/release-XXX/`. On exit, a composed availability summary is printed and the summary JSON is written.

## Stability criteria (exit when all are true)

1. **Cluster operators** – None in `Progressing` state.
2. **Nodes** – All `Ready` (no nodes restarting).
3. **MCP (machine config pools)** – No pool in “updating” state for more than 10 minutes (avoids treating a stuck update as stable).
4. **Pods** – No pod in a transient state (other than `Running` or `Completed`/Succeeded) for more than 10 minutes.

5. **CSVs (operators)** – No ClusterServiceVersion in `Installing` state; any CSV in `Installing` for more than 10 minutes is treated as stuck. A short summary shows Installing vs Succeeded (and Failed/other) per namespace.

6. **Policies (ACM)** – All ACM policies in namespace `local-cluster` are `Compliant`. Only policies applied in `local-cluster` are evaluated; disabled policies are ignored. A summary shows Compliant vs NonCompliant vs Pending vs Disabled. For any NonCompliant or Pending policy, the monitor also prints **violation details** (from the policy status history) so you can see what is preventing the policy from becoming Compliant.

When all six are satisfied, the script exits with rc 0. By default it exits as soon as all checks pass once; use `--stable-for SECONDS` to require that the cluster remain stable for that many seconds before exiting. Use Ctrl+C to stop early.

## Requirements

- `oc` in `PATH` (OpenShift CLI).
- Valid kubeconfig with access to the cluster.
- Python 3.7+ (stdlib only).
