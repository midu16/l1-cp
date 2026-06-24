#!/usr/bin/env python3
"""
Monitor OpenShift/ACM cluster until it stabilises.

Runs in a loop: oc get cgu -A, clusterversion, co, policies -A, nodes, mcp, installplan -A.
Supports KUBECONFIG from environment or --kubeconfig.
Optional --installplan to auto-approve all InstallPlans; otherwise user approves manually.

Validates in an endless loop that no pod is in a transient state (non-Running/Completed)
for more than 10 minutes, plus other stability checks. Exits with rc 0 only after the
cluster has been stable for a given duration (--stable-for).

Stability criteria:
- No cluster operators in Progressing state
- No nodes restarting (all Ready)
- No MCP (machine config pool) updating for more than 10 minutes (stuck)
- No pod in non-Running/Completed state for more than 10 minutes (transient state)
- No CSV (ClusterServiceVersion) in Installing state, or in Installing for more than 10 minutes (stuck)
- All ACM policies in namespace local-cluster Compliant (no NonCompliant or Pending)
- No cluster operators Degraded (airgap/day-2 rollout health)

When all criteria pass for at least --stable-for seconds, the program exits with rc 0.

When stability checks fail, a troubleshooting report is printed (disable with --no-troubleshoot)
covering common disconnected-hub issues: ImagePullBackOff / missing IDMS, ArgoCD init images,
AgentServiceConfig RHCOS URLs, MCP node rolls, stale installer/debug pods, and degraded operators.

Optional --apiserver-metrics: collect Prometheus API server metrics (same format as
collect-apiserver-metrics.sh / collect-apiserver-metrics-day2.sh) under ./data/release-XXX/
(version derived from cluster version, e.g. release-419 for 4.19.x). On exit, prints a
composed API server availability summary for the entire upgrade.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timezone

# Default stability thresholds (seconds)
MCP_UPDATING_MAX_SECONDS = 10 * 60   # 10 minutes
POD_STUCK_SECONDS = 10 * 60         # 10 minutes
CSV_INSTALLING_MAX_SECONDS = 10 * 60  # 10 minutes (Installing longer = stuck)

# Policy evaluation scope: only policies in this namespace are checked for stability
POLICY_NAMESPACE = "local-cluster"

# Supplemental IDMS sources (must match scripts/sync-idms-from-oc-mirror.sh SUPPLEMENT_SOURCES).
SUPPLEMENTAL_IDMS_SOURCES = frozenset({
    "registry.redhat.io/rhceph/rhceph-9-rhel9",
    "registry.redhat.io/openshift-gitops-1/argocd-rhel9",
    "registry.redhat.io/openshift-gitops-1/dex-rhel9",
    "registry.redhat.io/openshift-gitops-1/console-plugin-rhel9",
    "registry.redhat.io/openshift-gitops-1/gitops-rhel9",
    "registry.redhat.io/odf4/odf-blackbox-exporter-rhel9",
    "registry.redhat.io/rhel9/postgresql-16",
    "registry.redhat.io/odf4/mcg-core-rhel9",
    "registry.redhat.io/odf4/odf-cloudnative-pg-rhel9-operator",
    "registry.redhat.io/odf4/odf-external-snapshotter-rhel9-operator",
    "registry.redhat.io/odf4/odf-external-snapshotter-sidecar-rhel9",
    "registry.redhat.io/openshift4/ztp-site-generate-rhel8",
    "registry.redhat.io/rhel8/support-tools",
    "registry.redhat.io/rhel9/support-tools",
    "registry.redhat.io/multicluster-engine/cluster-permission-rhel9",
    "registry.redhat.io/oadp/oadp-cli-binaries-rhel9",
    "registry.redhat.io/oadp/oadp-vmdp-binaries-rhel9",
    "registry.redhat.io/openshift-gitops-1/gitops-rhel9-operator",
})

# Hostnames that indicate misconfigured assisted-service / AgentServiceConfig osImages.
BAD_OS_IMAGE_HOSTS = ("mirror.example.com", "mirror.example", "<http-server-address:port>")

# Namespaces where ImagePullBackOff is most often an airgap mirror/IDMS issue during hub rollout.
AIRGAP_WATCH_NAMESPACES = frozenset({
    "openshift-gitops",
    "openshift-gitops-operator",
    "multicluster-engine",
    "open-cluster-management-backup",
    "openshift-storage",
    "openshift-adp",
})

PULL_FAILURE_REASONS = frozenset({
    "ImagePullBackOff", "ErrImagePull", "Init:ImagePullBackOff", "Init:ErrImagePull",
})

# API server metrics (Prometheus/Thanos)
PROM_NS = "openshift-monitoring"
PROM_POD = "prometheus-k8s-0"
THANOS_URL = "https://thanos-querier.openshift-monitoring.svc:9091"
# Namespaces tracked for day-2 operator upgrade progress (same as collect-apiserver-metrics-day2.sh)
TRACKED_OPERATOR_NAMESPACES = [
    "open-cluster-management",
    "multicluster-engine",
    "openshift-operators",
    "openshift-gitops-operator",
    "openshift-local-storage",
    "openshift-storage",
    "openshift-logging",
    "openshift-adp",
    "open-cluster-management-backup",
]

# CSV filenames for apiserver metrics (must match collect-apiserver-metrics*.sh format)
CSV_APISERVER_UP = "apiserver-up.csv"
CSV_AGGREGATE = "apiserver-aggregate-availability.csv"
CSV_SUCCESS = "apiserver-request-success-rate.csv"
CSV_LATENCY = "apiserver-p99-latency.csv"
CSV_REQRATE = "apiserver-request-rate.csv"
CSV_UPGRADE = "upgrade-progress.csv"
CSV_OPERATOR = "operator-upgrade-progress.csv"
SUMMARY_JSON = "apiserver-availability-summary.json"


def run_oc(args, kubeconfig=None, timeout=120):
    """Run oc with optional KUBECONFIG. Returns (success, stdout, stderr)."""
    env = os.environ.copy()
    if kubeconfig:
        env["KUBECONFIG"] = kubeconfig
    try:
        result = subprocess.run(
            ["oc"] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return result.returncode == 0, result.stdout, result.stderr
    except FileNotFoundError:
        return False, "", "oc not found in PATH"
    except subprocess.TimeoutExpired:
        return False, "", "oc command timed out"


def oc_get_json(resource, namespace=None, kubeconfig=None):
    """Run oc get <resource> -o json. namespace=None: -A; namespace='': cluster-scoped (no -n/-A); else -n <ns>."""
    args = ["get", resource, "-o", "json"]
    if namespace is None:
        args.append("-A")
    elif namespace != "":
        args.extend(["-n", namespace])
    ok, out, err = run_oc(args, kubeconfig)
    if not ok:
        return None, err
    try:
        return json.loads(out), None
    except json.JSONDecodeError:
        return None, out or err or "invalid JSON"


def print_section(title):
    print("\n" + "=" * 60)
    print(title)
    print("=" * 60)


def run_and_print(cmd_desc, oc_args, kubeconfig):
    """Run oc and print output; return success."""
    ok, out, err = run_oc(oc_args, kubeconfig)
    print_section(cmd_desc)
    if ok:
        print(out or "(no output)")
    else:
        print("ERROR:", err or out or "unknown")
    return ok


# ---------------------------------------------------------------------------
# API server metrics (from collect-apiserver-metrics.sh / collect-apiserver-metrics-day2.sh)
# ---------------------------------------------------------------------------

def get_cluster_version_for_data_dir(kubeconfig):
    """
    Get the cluster's desired/current version and derive release label for data dir.
    Returns (version_string, release_label) e.g. ("4.19.23", "release-419").
    release_label is used as subdir: ./data/release-419/
    """
    data, err = oc_get_json("clusterversion", "", kubeconfig)
    if err or not data:
        return "unknown", "release-unknown"
    items = data.get("items") or []
    if not items:
        return "unknown", "release-unknown"
    cv = items[0]
    # Prefer desired version; fallback to history[0].version
    desired = (cv.get("status") or {}).get("desired", {}).get("version")
    if desired:
        version = desired
    else:
        history = (cv.get("status") or {}).get("history") or []
        version = (history[0] or {}).get("version", "unknown") if history else "unknown"
    # Normalize to release-XXX e.g. 4.19.23 -> release-419, 4.20.14 -> release-420
    parts = str(version).split(".")
    if len(parts) >= 2:
        try:
            major, minor = int(parts[0]), int(parts[1])
            release_label = f"release-{major}{minor:02d}"
        except (ValueError, IndexError):
            release_label = "release-unknown"
    else:
        release_label = "release-unknown"
    return version, release_label


def ensure_release_data_dir(base_dir, release_label):
    """
    Ensure base_dir and base_dir/release_label exist. Create if missing (exist_ok=True).
    Returns the full path to the release subdir (e.g. ./data/release-419).
    """
    base_dir = os.path.abspath(base_dir or "data")
    release_dir = os.path.join(base_dir, release_label)
    try:
        os.makedirs(base_dir, exist_ok=True)
        os.makedirs(release_dir, exist_ok=True)
    except OSError as e:
        print(f"Warning: could not create data dir {release_dir}: {e}", file=sys.stderr)
    return release_dir


def init_apiserver_csvs(data_dir):
    """Create CSV files with headers if they do not exist (same format as collect-apiserver-metrics*.sh)."""
    headers = [
        (CSV_APISERVER_UP, "timestamp,instance,up"),
        (CSV_AGGREGATE, "timestamp,up_instances,total_instances"),
        (CSV_SUCCESS, "timestamp,success_rate"),
        (CSV_LATENCY, "timestamp,p99_latency_seconds"),
        (CSV_REQRATE, "timestamp,requests_per_second"),
        (CSV_UPGRADE, "timestamp,version,state,message"),
        (CSV_OPERATOR, "timestamp,namespace,subscription,current_csv,installed_csv,state,pending_installplans"),
    ]
    for fname, header in headers:
        path = os.path.join(data_dir, fname)
        if not os.path.isfile(path):
            try:
                with open(path, "w") as f:
                    f.write(header + "\n")
            except OSError:
                pass


def get_prom_token(kubeconfig):
    """Create a token for prometheus-k8s in openshift-monitoring. Returns token string or None."""
    ok, out, err = run_oc(
        ["create", "token", "prometheus-k8s", "-n", PROM_NS, "--duration=1h"],
        kubeconfig=kubeconfig,
        timeout=30,
    )
    if not ok or not out:
        return None
    return out.strip()


def prom_query(kubeconfig, token, query):
    """Run a Prometheus query via oc exec into prometheus-k8s-0 (Thanos URL). Returns parsed JSON or None."""
    quoted = urllib.parse.quote(query, safe="")
    curl_cmd = (
        f"curl -sk -H \"Authorization: Bearer {token}\" "
        f"\"{THANOS_URL}/api/v1/query\" --data-urlencode \"query={quoted}\""
    )
    ok, out, err = run_oc(
        ["exec", "-n", PROM_NS, "-c", "prometheus", PROM_POD, "--", "sh", "-c", curl_cmd],
        kubeconfig=kubeconfig,
        timeout=30,
    )
    if not ok or not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def collect_apiserver_metrics_once(data_dir, kubeconfig, ts_iso):
    """
    Collect one round of API server metrics and append to CSVs (same as collect-apiserver-metrics.sh).
    Returns (up_count, total_count) or (None, None) on failure.
    """
    token = get_prom_token(kubeconfig)
    if not token:
        return None, None
    # 1) up{job="apiserver"}
    up_json = prom_query(kubeconfig, token, 'up{job="apiserver"}')
    if not up_json or "data" not in up_json:
        return None, None
    results = up_json.get("data", {}).get("result") or []
    up_path = os.path.join(data_dir, CSV_APISERVER_UP)
    agg_path = os.path.join(data_dir, CSV_AGGREGATE)
    for r in results:
        metric = r.get("metric") or {}
        instance = metric.get("instance", "")
        val = (r.get("value") or [None, None])[1]
        with open(up_path, "a") as f:
            f.write(f"{ts_iso},{instance},{val}\n")
    up_count = sum(1 for r in results if (r.get("value") or [None, None])[1] == "1")
    total_count = len(results)
    with open(agg_path, "a") as f:
        f.write(f"{ts_iso},{up_count},{total_count}\n")
    # 2) success rate
    sr_json = prom_query(
        kubeconfig, token,
        '1 - (sum(rate(apiserver_request_total{job="apiserver",code=~"5.."}[2m])) / sum(rate(apiserver_request_total{job="apiserver"}[2m])))',
    )
    sr_val = "NaN"
    if sr_json and (sr_json.get("data") or {}).get("result"):
        sr_val = (sr_json["data"]["result"][0].get("value") or [None, "NaN"])[1]
    with open(os.path.join(data_dir, CSV_SUCCESS), "a") as f:
        f.write(f"{ts_iso},{sr_val}\n")
    # 3) P99 latency
    lat_json = prom_query(
        kubeconfig, token,
        'histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{job="apiserver",verb!="WATCH"}[2m])) by (le))',
    )
    lat_val = "NaN"
    if lat_json and (lat_json.get("data") or {}).get("result"):
        lat_val = (lat_json["data"]["result"][0].get("value") or [None, "NaN"])[1]
    with open(os.path.join(data_dir, CSV_LATENCY), "a") as f:
        f.write(f"{ts_iso},{lat_val}\n")
    # 4) request rate
    rr_json = prom_query(kubeconfig, token, 'sum(rate(apiserver_request_total{job="apiserver"}[2m]))')
    rr_val = "NaN"
    if rr_json and (rr_json.get("data") or {}).get("result"):
        rr_val = (rr_json["data"]["result"][0].get("value") or [None, "NaN"])[1]
    with open(os.path.join(data_dir, CSV_REQRATE), "a") as f:
        f.write(f"{ts_iso},{rr_val}\n")
    # 5) upgrade progress (clusterversion)
    cv_data, _ = oc_get_json("clusterversion", "", kubeconfig)
    version, state, msg = "unknown", "Unknown", "N/A"
    if cv_data and (cv_data.get("items") or []):
        status = (cv_data["items"][0].get("status") or {})
        version = status.get("desired", {}).get("version", "unknown")
        history = status.get("history") or []
        if history:
            state = history[0].get("state", "Unknown")
        for c in status.get("conditions") or []:
            if c.get("type") == "Progressing":
                msg = (c.get("message") or "N/A").replace(",", ";").replace("\n", " ")[:200]
                break
    with open(os.path.join(data_dir, CSV_UPGRADE), "a") as f:
        f.write(f"{ts_iso},{version},{state},{msg}\n")
    return up_count, total_count


def collect_operator_progress_once(data_dir, kubeconfig, ts_iso):
    """Append one row per subscription in tracked namespaces to operator-upgrade-progress.csv (day2)."""
    op_path = os.path.join(data_dir, CSV_OPERATOR)
    for ns in TRACKED_OPERATOR_NAMESPACES:
        data, err = oc_get_json("subscription.operators.coreos.com", ns, kubeconfig)
        if err or not data:
            continue
        for sub in data.get("items") or []:
            meta = sub.get("metadata") or {}
            status = sub.get("status") or {}
            sub_name = meta.get("name", "")
            current_csv = status.get("currentCSV") or "none"
            installed_csv = status.get("installedCSV") or "none"
            state = status.get("state") or "Unknown"
            ip_data, _ = oc_get_json("installplan.operators.coreos.com", ns, kubeconfig)
            pending_ips = 0
            if ip_data and ip_data.get("items"):
                pending_ips = sum(1 for ip in ip_data["items"] if not (ip.get("spec") or {}).get("approved"))
            with open(op_path, "a") as f:
                f.write(f"{ts_iso},{ns},{sub_name},{current_csv},{installed_csv},{state},{pending_ips}\n")


def generate_apiserver_summary(data_dir, kubeconfig):
    """
    Read CSVs under data_dir and produce apiserver-availability-summary.json plus a summary dict.
    Same logic as generate_summary in collect-apiserver-metrics.sh.
    """
    agg_path = os.path.join(data_dir, CSV_AGGREGATE)
    success_path = os.path.join(data_dir, CSV_SUCCESS)
    lat_path = os.path.join(data_dir, CSV_LATENCY)
    summary_path = os.path.join(data_dir, SUMMARY_JSON)
    if not os.path.isfile(agg_path):
        return None
    # Parse aggregate (timestamp, up_instances, total_instances)
    total_samples = 0
    full_avail = partial_avail = degraded = zero_avail = 0
    with open(agg_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("timestamp"):
                continue
            total_samples += 1
            parts = line.split(",", 2)
            if len(parts) < 3:
                continue
            try:
                up = int(parts[1])
            except ValueError:
                continue
            if up >= 3:
                full_avail += 1
            elif up == 2:
                partial_avail += 1
            if up <= 1:
                degraded += 1
            if up == 0:
                zero_avail += 1
    # Success rate min/avg
    min_success = float("nan")
    avg_success = float("nan")
    if os.path.isfile(success_path):
        vals = []
        with open(success_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("timestamp"):
                    continue
                parts = line.split(",", 1)
                if len(parts) < 2:
                    continue
                try:
                    vals.append(float(parts[1]))
                except ValueError:
                    pass
        if vals:
            min_success = min(vals)
            avg_success = sum(vals) / len(vals)
    # P99 max/avg
    max_p99 = avg_p99 = float("nan")
    if os.path.isfile(lat_path):
        vals = []
        with open(lat_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("timestamp"):
                    continue
                parts = line.split(",", 1)
                if len(parts) < 2:
                    continue
                try:
                    vals.append(float(parts[1]))
                except ValueError:
                    pass
        if vals:
            max_p99 = max(vals)
            avg_p99 = sum(vals) / len(vals)
    # Upgrade window: first/last from aggregate
    start_ts = end_ts = ""
    with open(agg_path) as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("timestamp")]
    if lines:
        start_ts = lines[0].split(",", 1)[0]
        end_ts = lines[-1].split(",", 1)[0]
    def _num(v):
        return v if v is not None and not math.isnan(v) else None

    summary = {
        "monitoring_window": {"start": start_ts, "end": end_ts},
        "total_samples": total_samples,
        "api_server_availability": {
            "full_3_of_3": full_avail,
            "partial_2_of_3": partial_avail,
            "degraded_1_or_less": degraded,
            "total_outage_0_of_3": zero_avail,
        },
        "request_success_rate": {"minimum": _num(min_success), "average": _num(avg_success)},
        "request_latency_p99": {"max_seconds": _num(max_p99), "avg_seconds": _num(avg_p99)},
    }
    try:
        with open(summary_path, "w") as f:
            json.dump(summary, f, indent=2)
    except OSError:
        pass
    return summary


def print_upgrade_summary_report(data_dir, kubeconfig):
    """
    Generate apiserver summary and print a composed availability report for the entire upgrade.
    Call this when cluster_monitor is about to exit (upgrade done, cluster stable).
    """
    summary = generate_apiserver_summary(data_dir, kubeconfig)
    if not summary:
        print_section("API server availability summary")
        print("  No aggregate data found; metrics were not collected or directory is empty.")
        return
    print_section("API server availability – upgrade summary")
    print(f"  Monitoring window: {summary.get('monitoring_window', {}).get('start', '')} -> {summary.get('monitoring_window', {}).get('end', '')}")
    print(f"  Total samples: {summary.get('total_samples', 0)}")
    avail = summary.get("api_server_availability") or {}
    print("  API server availability (samples):")
    print(f"    Full (3/3 up):     {avail.get('full_3_of_3', 0)}")
    print(f"    Partial (2/3 up):  {avail.get('partial_2_of_3', 0)}")
    print(f"    Degraded (≤1 up):  {avail.get('degraded_1_or_less', 0)}")
    print(f"    Total outage (0):  {avail.get('total_outage_0_of_3', 0)}")
    def _fmt(v):
        return v if v is not None else "N/A"
    sr = summary.get("request_success_rate") or {}
    print(f"  Request success rate: min={_fmt(sr.get('minimum'))}, avg={_fmt(sr.get('average'))}")
    lat = summary.get("request_latency_p99") or {}
    print(f"  P99 latency (s):      max={_fmt(lat.get('max_seconds'))}, avg={_fmt(lat.get('avg_seconds'))}")
    summary_path = os.path.join(data_dir, SUMMARY_JSON)
    print(f"\n  Summary JSON: {summary_path}")
    print("=" * 60)


def approve_pending_installplans(kubeconfig):
    """Approve all pending InstallPlans in all namespaces."""
    data, err = oc_get_json("installplan.operators.coreos.com", None, kubeconfig)
    if err or not data:
        return 0
    items = data.get("items") or []
    approved = 0
    for ip in items:
        spec = ip.get("spec") or {}
        if spec.get("approved"):
            continue
        name = ip.get("metadata", {}).get("name")
        ns = ip.get("metadata", {}).get("namespace", "")
        if not name:
            continue
        ok, _, err_out = run_oc(
            ["patch", "installplan.operators.coreos.com", name, "-n", ns,
             "-p", "{\"spec\":{\"approved\":true}}", "--type=merge"],
            kubeconfig,
        )
        if ok:
            approved += 1
            print(f"  Approved InstallPlan {ns}/{name}")
        else:
            print(f"  Failed to approve {ns}/{name}: {err_out}")
    return approved


def check_cluster_operators(kubeconfig):
    """Return (stable, message). Stable if no CO is Progressing."""
    data, err = oc_get_json("co", "", kubeconfig)
    if err or not data:
        return False, f"could not get CO: {err or 'no data'}"
    items = data.get("items") or []
    progressing = []
    for co in items:
        name = co.get("metadata", {}).get("name", "?")
        for c in co.get("status", {}).get("conditions", []) or []:
            if c.get("type") == "Progressing" and c.get("status") == "True":
                progressing.append(name)
                break
    if progressing:
        return False, f"Cluster operators still progressing: {', '.join(progressing)}"
    return True, "No cluster operators progressing"


def check_nodes(kubeconfig):
    """Return (stable, message). Stable if all nodes Ready and not restarting."""
    data, err = oc_get_json("nodes", "", kubeconfig)
    if err or not data:
        return False, f"could not get nodes: {err or 'no data'}"
    items = data.get("items") or []
    not_ready = []
    for node in items:
        name = node.get("metadata", {}).get("name", "?")
        for c in node.get("status", {}).get("conditions", []) or []:
            if c.get("type") == "Ready":
                if c.get("status") != "True":
                    not_ready.append(name)
                break
    if not_ready:
        return False, f"Nodes not Ready: {', '.join(not_ready)}"
    return True, "All nodes Ready"


def check_mcp(kubeconfig, updating_since):
    """
    Return (stable, message).
    Stable if no MCP pool is in 'updating' state for more than MCP_UPDATING_MAX_SECONDS.
    updating_since: dict pool_name -> first time we saw it updating (timestamp).
    """
    data, err = oc_get_json("mcp", "", kubeconfig)
    if err:
        # mcp might not exist on some clusters; treat as stable
        if "the server doesn't have a resource type" in (err or "").lower() or "unknown" in (err or "").lower():
            return True, "MCP not available (skipped)"
        return False, f"could not get MCP: {err}"
    items = data.get("items") or []
    now = time.time()
    still_updating = []
    for pool in items:
        name = pool.get("metadata", {}).get("name", "?")
        status = pool.get("status") or {}
        updated = int(status.get("updatedMachineCount") or 0)
        total = int(status.get("machineCount") or 0)
        if total == 0:
            continue
        if updated < total:
            if name not in updating_since:
                updating_since[name] = now
            if (now - updating_since[name]) > MCP_UPDATING_MAX_SECONDS:
                still_updating.append(f"{name} (updating > {MCP_UPDATING_MAX_SECONDS // 60} min)")
        else:
            updating_since.pop(name, None)
    if still_updating:
        return False, f"MCP updating too long: {', '.join(still_updating)}"
    return True, "MCP stable or not updating beyond threshold"


def _pod_check_ignore(ns, name):
    """Skip pods that are benign leftovers and should not block stability checks."""
    # Static pod installer jobs can leave Failed pods after a later retry succeeds.
    if ns.startswith("openshift-kube-") and name.startswith("installer-"):
        return True
    # Assisted installer node debug pods are optional post-install leftovers.
    if ns == "assisted-installer" and ("-debug-" in name or name.endswith("-debug")):
        return True
    return False


def check_pods(kubeconfig):
    """Return (stable, message). Stable if no pod in transient state (not Running/Completed) for > POD_STUCK_SECONDS."""
    data, err = oc_get_json("pods", None, kubeconfig)
    if err or not data:
        return False, f"could not get pods: {err or 'no data'}"
    items = data.get("items") or []
    now = time.time()
    stuck = []
    for pod in items:
        ns = pod.get("metadata", {}).get("namespace", "?")
        name = pod.get("metadata", {}).get("name", "?")
        if _pod_check_ignore(ns, name):
            continue
        phase = pod.get("status", {}).get("phase", "Unknown")
        if phase in ("Running", "Succeeded"):
            continue
        start_time = pod.get("status", {}).get("startTime")
        if not start_time:
            stuck.append(f"{ns}/{name} ({phase})")
            continue
        try:
            # startTime is RFC3339 (e.g. 2024-01-15T10:00:00Z)
            s = start_time.replace("Z", "+00:00")
            st = datetime.fromisoformat(s)
            if st.tzinfo is None:
                st = st.replace(tzinfo=timezone.utc)
            age = now - st.timestamp()
        except Exception:
            age = 0
        if age > POD_STUCK_SECONDS:
            entry = f"{ns}/{name} ({phase}, {int(age)}s)"
            pull = _pod_pull_failure(pod)
            if pull:
                entry += f" [{pull['reason']}: {pull['image']}]"
            stuck.append(entry)
    if stuck:
        return False, f"Pods not Running/Completed > {POD_STUCK_SECONDS // 60} min: " + "; ".join(stuck[:5]) + ("..." if len(stuck) > 5 else "")
    return True, "No stuck pods"


def check_csv(kubeconfig):
    """
    Return (stable, message).
    Stable if no CSV is in Installing, or any CSV in Installing for no more than CSV_INSTALLING_MAX_SECONDS.
    Also report counts: Installing vs Succeeded.
    """
    data, err = oc_get_json("csv", None, kubeconfig)
    if err:
        if "the server doesn't have a resource type" in (err or "").lower():
            return True, "CSV not available (skipped)"
        return False, f"could not get CSV: {err}"
    items = data.get("items") or []
    now = time.time()
    installing = []       # ns/name
    installing_stuck = [] # (ns/name, phase, seconds)
    succeeded = []
    other = []           # Failed, Unknown, etc.
    for csv in items:
        ns = csv.get("metadata", {}).get("namespace", "?")
        name = csv.get("metadata", {}).get("name", "?")
        display_name = csv.get("spec", {}).get("displayName") or name
        phase = csv.get("status", {}).get("phase", "Unknown")
        if phase == "Succeeded":
            succeeded.append(f"{ns}/{display_name}")
            continue
        if phase == "Installing":
            # Check how long it has been Installing (use lastTransitionTime from conditions or status)
            last_transition = None
            for c in csv.get("status", {}).get("conditions", []) or []:
                if c.get("type") == "Installing" and c.get("status") == "True":
                    last_transition = c.get("lastTransitionTime")
                    break
            if not last_transition:
                last_transition = csv.get("status", {}).get("lastUpdateTime") or csv.get("metadata", {}).get("creationTimestamp")
            age = 0
            if last_transition:
                try:
                    s = last_transition.replace("Z", "+00:00")
                    st = datetime.fromisoformat(s)
                    if st.tzinfo is None:
                        st = st.replace(tzinfo=timezone.utc)
                    age = now - st.timestamp()
                except Exception:
                    pass
            installing.append(f"{ns}/{display_name}")
            if age > CSV_INSTALLING_MAX_SECONDS:
                installing_stuck.append((f"{ns}/{display_name}", phase, int(age)))
            continue
        other.append(f"{ns}/{display_name} ({phase})")
    if installing_stuck:
        stuck_str = "; ".join(f"{x[0]} ({x[2]}s)" for x in installing_stuck[:5])
        if len(installing_stuck) > 5:
            stuck_str += "..."
        return False, f"CSV(s) stuck in Installing > {CSV_INSTALLING_MAX_SECONDS // 60} min: " + stuck_str
    if installing:
        return False, f"CSV(s) still Installing: " + ", ".join(installing[:8]) + ("..." if len(installing) > 8 else "")
    # All Succeeded (or other terminal); report summary
    return True, f"All CSVs ready (Succeeded: {len(succeeded)}, other: {len(other)})"


def print_csv_summary(kubeconfig):
    """Print a short CSV status summary: Installing vs Succeeded counts and notable items."""
    data, err = oc_get_json("csv", None, kubeconfig)
    if err or not data:
        return
    items = data.get("items") or []
    by_phase = {}
    for csv in items:
        phase = csv.get("status", {}).get("phase", "Unknown")
        by_phase.setdefault(phase, []).append(
            (csv.get("metadata", {}).get("namespace", "?"),
             csv.get("spec", {}).get("displayName") or csv.get("metadata", {}).get("name", "?"))
        )
    print_section("CSV status (operators)")
    for phase in ("Installing", "Succeeded", "Failed", "Unknown"):
        if phase not in by_phase:
            continue
        entries = by_phase[phase]
        print(f"  {phase}: {len(entries)}")
        for ns, name in entries[:10]:
            print(f"    - {ns}/{name}")
        if len(entries) > 10:
            print(f"    ... and {len(entries) - 10} more")
    other = [p for p in by_phase if p not in ("Installing", "Succeeded", "Failed", "Unknown")]
    if other:
        print(f"  Other phases: {', '.join(other)}")


def check_policies(kubeconfig):
    """
    Return (stable, message).
    Stable if all ACM policies in namespace local-cluster are Compliant.
    Only policies in POLICY_NAMESPACE (local-cluster) are evaluated.
    """
    # ACM Policy CRD: resource can be 'policies' or full name
    data, err = oc_get_json("policies.policy.open-cluster-management.io", None, kubeconfig)
    if err:
        # Fallback short name in case server has it
        data, err = oc_get_json("policies", None, kubeconfig)
    if err:
        if "the server doesn't have a resource type" in (err or "").lower() or "unknown" in (err or "").lower():
            return True, "Policies not available (ACM not installed?)"
        return False, f"could not get policies: {err}"
    items = data.get("items") or []
    items = [p for p in items if p.get("metadata", {}).get("namespace") == POLICY_NAMESPACE]
    compliant = []
    non_compliant = []
    pending = []
    disabled = []
    for pol in items:
        ns = pol.get("metadata", {}).get("namespace", "?")
        name = pol.get("metadata", {}).get("name", "?")
        if pol.get("spec", {}).get("disabled"):
            disabled.append(f"{ns}/{name}")
            continue
        status = pol.get("status", {}).get("compliant", "Unknown")
        if status == "Compliant":
            compliant.append(f"{ns}/{name}")
        elif status == "NonCompliant":
            non_compliant.append(f"{ns}/{name}")
        elif status == "Pending":
            pending.append(f"{ns}/{name}")
        else:
            pending.append(f"{ns}/{name} ({status})")
    if non_compliant:
        return False, f"NonCompliant policies: " + ", ".join(non_compliant[:8]) + ("..." if len(non_compliant) > 8 else "")
    if pending:
        return False, f"Pending policies: " + ", ".join(pending[:8]) + ("..." if len(pending) > 8 else "")
    return True, f"All {POLICY_NAMESPACE} policies Compliant ({len(compliant)}), disabled ({len(disabled)})"


def get_policy_violation_messages(policy_obj):
    """
    Extract messages that explain why a Policy is not Compliant.
    Reads status.details[].history[].message for NonCompliant/Pending details.
    Returns a list of strings (one per template or cluster detail).
    """
    reasons = []
    status = policy_obj.get("status") or {}
    details = status.get("details") or []
    for detail in details:
        if not isinstance(detail, dict):
            continue
        compliant = detail.get("compliant", "")
        if compliant == "Compliant":
            continue
        template_name = (detail.get("templateMeta") or {}).get("name", "policy")
        history = detail.get("history") or []
        # Prefer the most recent message (last in list); fall back to any non-compliant message
        msg = None
        for h in reversed(history) if history else []:
            m = (h or {}).get("message", "").strip()
            if m and ("noncompliant" in m.lower() or "violation" in m.lower() or "pending" in m.lower() or compliant != "Compliant"):
                msg = m
                break
        if not msg and history:
            msg = (history[-1] or {}).get("message", "").strip()
        if msg:
            reasons.append(f"[{template_name}] {msg}")
        else:
            reasons.append(f"[{template_name}] status: {compliant} (no history message)")
    # If no details, use top-level status message if present
    if not reasons and status.get("compliant") != "Compliant":
        msg = status.get("message") or status.get("reason") or str(status.get("compliant", "Unknown"))
        reasons.append(msg)
    return reasons


def print_policy_violations(kubeconfig):
    """
    For policies in local-cluster that are not Compliant, print the violation/reason
    messages from status.details.history so users can see what prevents compliance.
    """
    data, _ = oc_get_json("policies.policy.open-cluster-management.io", None, kubeconfig)
    if not data:
        data, _ = oc_get_json("policies", None, kubeconfig)
    if not data:
        return
    items = data.get("items") or []
    items = [p for p in items if p.get("metadata", {}).get("namespace") == POLICY_NAMESPACE]
    non_ok = [
        p for p in items
        if not p.get("spec", {}).get("disabled")
        and p.get("status", {}).get("compliant") not in ("Compliant", None)
    ]
    if not non_ok:
        return
    print_section(f"Policy violation details (why not Compliant, {POLICY_NAMESPACE})")
    for pol in non_ok:
        ns = pol.get("metadata", {}).get("namespace", "?")
        name = pol.get("metadata", {}).get("name", "?")
        compliant = pol.get("status", {}).get("compliant", "Unknown")
        reasons = get_policy_violation_messages(pol)
        print(f"  Policy {ns}/{name} ({compliant}):")
        if reasons:
            for r in reasons[:10]:
                # Wrap long lines for readability
                for line in r.split("\n"):
                    print(f"    | {line}")
            if len(reasons) > 10:
                print(f"    ... and {len(reasons) - 10} more detail(s)")
        else:
            print("    (no violation details in status; check policy status with 'oc get policy <name> -o yaml')")
        print()


def _image_source_repo(image):
    """Normalize container image to repository (strip tag/digest)."""
    if not image:
        return ""
    repo = image.split("@", 1)[0]
    if "/" in repo:
        last_segment = repo.rsplit("/", 1)[-1]
        if ":" in last_segment:
            repo = repo.rsplit(":", 1)[0]
    return repo


def _pod_container_states(pod):
    """Yield (container_name, state_dict, image) for init and regular containers."""
    spec = pod.get("spec") or {}
    status = pod.get("status") or {}
    init_by_name = {c.get("name"): c for c in spec.get("initContainers") or []}
    cont_by_name = {c.get("name"): c for c in spec.get("containers") or []}
    for cs in (status.get("initContainerStatuses") or []) + (status.get("containerStatuses") or []):
        name = cs.get("name", "?")
        image = cs.get("image") or ""
        if not image:
            image = (init_by_name.get(name) or cont_by_name.get(name) or {}).get("image", "")
        for key in ("waiting", "terminated"):
            state = (cs.get("state") or {}).get(key)
            if state:
                yield name, state, image


def _pod_pull_failure(pod):
    """Return dict with pull failure details or None."""
    for cname, state, image in _pod_container_states(pod):
        reason = state.get("reason", "")
        if reason not in ("ImagePullBackOff", "ErrImagePull"):
            continue
        message = (state.get("message") or "")[:240]
        return {
            "container": cname,
            "image": image,
            "source": _image_source_repo(image),
            "reason": reason,
            "message": message,
        }
    return None


def collect_ignored_pods(kubeconfig):
    """Return list of ns/name for pods skipped by stability checks."""
    data, err = oc_get_json("pods", None, kubeconfig)
    if err or not data:
        return []
    ignored = []
    for pod in data.get("items") or []:
        ns = pod.get("metadata", {}).get("namespace", "?")
        name = pod.get("metadata", {}).get("name", "?")
        if _pod_check_ignore(ns, name):
            phase = pod.get("status", {}).get("phase", "Unknown")
            ignored.append(f"{ns}/{name} ({phase})")
    return ignored


def collect_pull_failure_pods(kubeconfig):
    """Return pull-failure pod details for troubleshooting."""
    data, err = oc_get_json("pods", None, kubeconfig)
    if err or not data:
        return []
    failures = []
    for pod in data.get("items") or []:
        ns = pod.get("metadata", {}).get("namespace", "?")
        name = pod.get("metadata", {}).get("name", "?")
        if _pod_check_ignore(ns, name):
            continue
        phase = pod.get("status", {}).get("phase", "Unknown")
        if phase in ("Running", "Succeeded"):
            continue
        pull = _pod_pull_failure(pod)
        if not pull:
            continue
        failures.append({
            "ns": ns,
            "name": name,
            "phase": phase,
            **pull,
        })
    return failures


def get_idms_operator_sources(kubeconfig):
    """Return set of source registries configured in idms-operator-0."""
    data, err = oc_get_json("imagedigestmirrorset.config.openshift.io", "", kubeconfig)
    if err or not data:
        data, err = oc_get_json("imagedigestmirrorset", "", kubeconfig)
    if err or not data:
        return set()
    for doc in data.get("items") or []:
        if doc.get("metadata", {}).get("name") != "idms-operator-0":
            continue
        return {
            e.get("source")
            for e in (doc.get("spec") or {}).get("imageDigestMirrors") or []
            if e.get("source")
        }
    return set()


def get_missing_supplemental_idms(kubeconfig):
    """Supplemental sources from repo template that are absent on the cluster."""
    configured = get_idms_operator_sources(kubeconfig)
    if not configured:
        return sorted(SUPPLEMENTAL_IDMS_SOURCES)
    return sorted(SUPPLEMENTAL_IDMS_SOURCES - configured)


def check_degraded_cluster_operators(kubeconfig):
    """Return (stable, message). Stable if no CO is Degraded."""
    data, err = oc_get_json("co", "", kubeconfig)
    if err or not data:
        return True, "could not get CO for Degraded check (skipped)"
    degraded = []
    for co in data.get("items") or []:
        name = co.get("metadata", {}).get("name", "?")
        for c in co.get("status", {}).get("conditions", []) or []:
            if c.get("type") == "Degraded" and c.get("status") == "True":
                msg = (c.get("message") or "").replace("\n", " ")[:80]
                degraded.append(f"{name} ({msg})" if msg else name)
                break
    if degraded:
        tail = "..." if len(degraded) > 5 else ""
        return False, "Degraded cluster operators: " + ", ".join(degraded[:5]) + tail
    return True, "No degraded cluster operators"


def get_mcp_status_detail(kubeconfig):
    """Return list of (name, updating, ready, total, config) tuples."""
    data, err = oc_get_json("mcp", "", kubeconfig)
    if err or not data:
        return []
    rows = []
    for pool in data.get("items") or []:
        name = pool.get("metadata", {}).get("name", "?")
        status = pool.get("status") or {}
        spec = pool.get("spec") or {}
        ready = int(status.get("readyMachineCount") or 0)
        total = int(status.get("machineCount") or 0)
        updating = any(
            c.get("type") == "Updating" and c.get("status") == "True"
            for c in status.get("conditions") or []
        )
        if not updating and total and ready < total:
            updating = True
        config = spec.get("configuration", {}).get("name", "?")
        rows.append((name, updating, ready, total, config))
    return rows


def check_argocd_init_images(kubeconfig):
    """Return list of problem strings for ArgoCD repo initContainers on registry.redhat.io."""
    data, err = oc_get_json("argocd", "openshift-gitops", kubeconfig)
    if err or not data:
        return []
    items = data.get("items") or []
    if not items:
        return []
    problems = []
    inits = ((items[0].get("spec") or {}).get("repo") or {}).get("initContainers") or []
    for ic in inits:
        image = ic.get("image", "")
        name = ic.get("name", "?")
        if image.startswith("registry.redhat.io/") or image.startswith("quay.io/redhat"):
            problems.append(f"initContainer {name}: {image}")
    return problems


def check_agentserviceconfig_os_images(kubeconfig):
    """Return list of problem strings for bad assisted-service RHCOS URLs."""
    data, err = oc_get_json("agentserviceconfig.agent-install.openshift.io", "multicluster-engine", kubeconfig)
    if err or not data:
        data, err = oc_get_json("agentserviceconfig", "multicluster-engine", kubeconfig)
    if err or not data:
        return []
    items = data.get("items") or []
    if not items:
        return []
    problems = []
    for entry in (items[0].get("spec") or {}).get("osImages") or []:
        url = entry.get("url") or ""
        version = entry.get("openshiftVersion", "?")
        for bad in BAD_OS_IMAGE_HOSTS:
            if bad in url:
                problems.append(f"osImages {version}: url={url}")
                break
    return problems


def check_assisted_image_service(kubeconfig):
    """Return list of problem strings for assisted-image-service crash/backoff."""
    data, err = oc_get_json("pods", "multicluster-engine", kubeconfig)
    if err or not data:
        return []
    problems = []
    for pod in data.get("items") or []:
        name = pod.get("metadata", {}).get("name", "")
        if name != "assisted-image-service-0":
            continue
        phase = pod.get("status", {}).get("phase", "")
        for cs in (pod.get("status") or {}).get("containerStatuses") or []:
            waiting = (cs.get("state") or {}).get("waiting") or {}
            if waiting.get("reason") in ("CrashLoopBackOff", "Error"):
                problems.append(
                    "assisted-image-service-0: CrashLoopBackOff – check AgentServiceConfig osImages (webcache URLs)"
                )
            elif phase != "Running":
                pull = _pod_pull_failure(pod)
                if pull:
                    problems.append(f"assisted-image-service-0: {pull['reason']} on {pull['image']}")
    return problems


def _remediation_for_pull(failure, missing_idms):
    """Return short remediation hints for a pull failure."""
    source = failure.get("source", "")
    image = failure.get("image", "")
    hints = []
    if source in missing_idms:
        hints.append(
            f"add IDMS mapping for {source} (workingdir/openshift/idms-oc-mirror.yaml supplemental section)"
        )
        hints.append("apply idms-operator-0 and wait for MCP master pool (oc get mcp -w)")
    if image.startswith("registry.redhat.io/") or image.startswith("quay.io/"):
        hints.append("node pulls public registry; verify ImageDigestMirrorSet and airgap mirror")
    if "openshift-gitops" in failure.get("ns", "") and "ztp-site-generate" in image:
        hints.append("patch ArgoCD initContainers to airgap path; update addPluginsPolicy.yaml")
    if "cluster-permission" in image or "oadp-" in image:
        hints.append("ensure oc-mirror copied image and IDMS includes repository path")
    if not hints:
        hints.append(f"oc describe pod -n {failure['ns']} {failure['name']} | tail -20")
    return hints


def print_troubleshooting_report(kubeconfig):
    """Print airgap/day-2 troubleshooting guidance when stability checks fail."""
    print_section("Troubleshooting (disconnected hub / day-2 operators)")

    mcp_rows = get_mcp_status_detail(kubeconfig)
    if mcp_rows:
        print("  MCP (MachineConfigPool) status:")
        for name, updating, ready, total, config in mcp_rows:
            state = "UPDATING" if updating else "stable"
            print(f"    - {name}: {state} ready={ready}/{total} config={config}")
        if any(r[1] for r in mcp_rows):
            print("    → IDMS changes trigger MCP node rolls; ImagePullBackOff during roll is often transient.")
            print("    → Wait for: oc get mcp master -w  (UPDATED=True, readyMachineCount=machineCount)")

    missing_idms = get_missing_supplemental_idms(kubeconfig)
    if missing_idms:
        print(f"  Missing supplemental IDMS entries ({len(missing_idms)}):")
        for src in missing_idms[:8]:
            print(f"    - {src}")
        if len(missing_idms) > 8:
            print(f"    ... and {len(missing_idms) - 8} more")
        print("    → Fix: make sync-oc-mirror-manifests")
        print("    → Then: scripts/render-idms-oc-mirror.sh <registry>/hub-demo workingdir/openshift/idms-oc-mirror.yaml")
        print("    → Apply idms-operator-0 from rendered idms-oc-mirror.yaml")

    pull_failures = collect_pull_failure_pods(kubeconfig)
    if pull_failures:
        print(f"  Image pull failures ({len(pull_failures)}):")
        for f in pull_failures[:8]:
            print(f"    - {f['ns']}/{f['name']} ({f['reason']}): {f['image']}")
            for hint in _remediation_for_pull(f, missing_idms)[:2]:
                print(f"        → {hint}")
        if len(pull_failures) > 8:
            print(f"    ... and {len(pull_failures) - 8} more")

    argocd_issues = check_argocd_init_images(kubeconfig)
    if argocd_issues:
        print("  ArgoCD repo initContainers still reference public registry:")
        for line in argocd_issues:
            print(f"    - {line}")
        print("    → Patch argocd openshift-gitops initContainer images to airgap registry")
        print("    → Update telco-reference addPluginsPolicy.yaml so ACM policy does not revert")

    asc_issues = check_agentserviceconfig_os_images(kubeconfig)
    if asc_issues:
        print("  AgentServiceConfig osImages misconfigured:")
        for line in asc_issues:
            print(f"    - {line}")
        print("    → Point osImages at webcache (http://<host>:8080/rhcos-*.iso)")
        print("    → See acmAgentServiceConfig.yaml / hub-config/operators-config/01_aiConfig.yaml")

    for line in check_assisted_image_service(kubeconfig):
        print(f"  Assisted image service: {line}")

    ignored = collect_ignored_pods(kubeconfig)
    stale_installers = [p for p in ignored if "openshift-kube-" in p and "installer-" in p]
    stale_debug = [p for p in ignored if "assisted-installer" in p and "debug" in p]
    if stale_installers or stale_debug:
        print("  Benign leftover pods (ignored by stability check; safe to delete):")
        for p in (stale_installers + stale_debug)[:6]:
            print(f"    - {p}")
        if stale_installers:
            print("    → oc delete pod -n openshift-kube-controller-manager <installer-* Failed pods>")
        if stale_debug:
            print("    → oc delete pod -n assisted-installer <*-debug-*>")

    ok_deg, msg_deg = check_degraded_cluster_operators(kubeconfig)
    if not ok_deg:
        print(f"  {msg_deg}")

    if not (missing_idms or pull_failures or argocd_issues or asc_issues):
        print("  No known airgap patterns detected; inspect stuck pods with:")
        print("    oc get pods -A | grep -Ev 'Running|Completed'")
        print("    oc describe pod -n <ns> <pod>")


def print_policy_summary(kubeconfig):
    """Print ACM policy status summary for local-cluster only: Compliant vs NonCompliant vs Pending."""
    data, _ = oc_get_json("policies.policy.open-cluster-management.io", None, kubeconfig)
    if not data:
        data, _ = oc_get_json("policies", None, kubeconfig)
    if not data:
        return
    items = data.get("items") or []
    items = [p for p in items if p.get("metadata", {}).get("namespace") == POLICY_NAMESPACE]
    by_status = {}
    for pol in items:
        ns = pol.get("metadata", {}).get("namespace", "?")
        name = pol.get("metadata", {}).get("name", "?")
        if pol.get("spec", {}).get("disabled"):
            by_status.setdefault("Disabled", []).append(f"{ns}/{name}")
            continue
        status = pol.get("status", {}).get("compliant", "Unknown")
        by_status.setdefault(status, []).append(f"{ns}/{name}")
    print_section(f"Policy status (ACM, {POLICY_NAMESPACE})")
    for status in ("Compliant", "NonCompliant", "Pending", "Disabled"):
        if status not in by_status:
            continue
        entries = by_status[status]
        print(f"  {status}: {len(entries)}")
        for item in entries[:12]:
            print(f"    - {item}")
        if len(entries) > 12:
            print(f"    ... and {len(entries) - 12} more")
    other = [s for s in by_status if s not in ("Compliant", "NonCompliant", "Pending", "Disabled")]
    if other:
        print(f"  Other: {', '.join(other)}")
    # For any NonCompliant/Pending policies, show what prevents them from being Compliant
    print_policy_violations(kubeconfig)


def main():
    parser = argparse.ArgumentParser(
        description="Monitor OpenShift/ACM cluster until stable. Uses KUBECONFIG from env or --kubeconfig."
    )
    parser.add_argument(
        "--kubeconfig",
        default=os.environ.get("KUBECONFIG", ""),
        help="Path to kubeconfig (default: KUBECONFIG env)",
    )
    parser.add_argument(
        "--installplan",
        action="store_true",
        help="Auto-approve all pending InstallPlans; otherwise leave to user",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help="Seconds between full status runs (default: 60)",
    )
    parser.add_argument(
        "--stable-for",
        type=int,
        default=0,
        metavar="SECONDS",
        help="Exit with rc 0 only after cluster has been stable for this many seconds (default: 0 = exit as soon as stable once)",
    )
    parser.add_argument(
        "--apiserver-metrics",
        action="store_true",
        help="Collect API server metrics (Prometheus) and store under ./data/release-XXX/; print summary at exit",
    )
    parser.add_argument(
        "--data-dir",
        default="data",
        metavar="DIR",
        help="Base directory for release-specific metrics (default: data); subdirs like release-419 created inside",
    )
    parser.add_argument(
        "--no-troubleshoot",
        action="store_true",
        help="Do not print airgap/day-2 troubleshooting report when stability checks fail",
    )
    parser.add_argument(
        "--diagnose",
        action="store_true",
        help="Run one status cycle plus troubleshooting report and exit (rc 0 if stable, 1 otherwise)",
    )
    args = parser.parse_args()

    if not args.kubeconfig:
        print("Set KUBECONFIG or pass --kubeconfig (e.g. export KUBECONFIG=/path/to/kubeconfig)", file=sys.stderr)
        sys.exit(1)

    kubeconfig = args.kubeconfig
    mcp_updating_since = {}
    stable_since = None  # time when we first saw all checks pass; None if not currently stable
    apiserver_data_dir = None  # set when --apiserver-metrics; used for collection and exit summary

    if args.apiserver_metrics:
        version, release_label = get_cluster_version_for_data_dir(kubeconfig)
        apiserver_data_dir = ensure_release_data_dir(args.data_dir, release_label)
        init_apiserver_csvs(apiserver_data_dir)
        print(f"API server metrics: writing to {apiserver_data_dir} (cluster version {version}, release {release_label})")

    print(f"Using KUBECONFIG={kubeconfig}")
    print(f"Auto-approve InstallPlans: {args.installplan}")
    print(
        f"Stability: no CO Progressing/Degraded, all nodes Ready, MCP not updating > 10 min, "
        f"no pods in transient state > 10 min, no CSV stuck in Installing > 10 min, "
        f"all {POLICY_NAMESPACE} policies Compliant"
    )
    if not args.no_troubleshoot:
        print("Troubleshooting report: enabled on stability failure (IDMS, ImagePullBackOff, ArgoCD, ASC osImages)")
    if args.diagnose:
        print("Diagnose mode: single iteration then exit.")
    elif args.stable_for > 0:
        print(f"Exit rc 0 only after stable for {args.stable_for}s. Ctrl+C to stop.")
    else:
        print("Loop until stable (exit as soon as all checks pass once). Ctrl+C to stop.")

    while True:
        ts = datetime.now().isoformat()
        print_section(f"Cluster status at {ts}")

        run_and_print("oc get cgu -A", ["get", "cgu", "-A"], kubeconfig)
        run_and_print("oc get clusterversion", ["get", "clusterversion"], kubeconfig)
        run_and_print("oc get co", ["get", "co"], kubeconfig)
        run_and_print(f"oc get policies -n {POLICY_NAMESPACE}", ["get", "policies", "-n", POLICY_NAMESPACE], kubeconfig)
        print_policy_summary(kubeconfig)
        run_and_print("oc get nodes", ["get", "nodes"], kubeconfig)
        run_and_print("oc get mcp", ["get", "mcp"], kubeconfig)
        run_and_print("oc get installplan -A", ["get", "installplan", "-A"], kubeconfig)
        run_and_print("oc get csv -A", ["get", "csv", "-A"], kubeconfig)
        print_csv_summary(kubeconfig)

        if apiserver_data_dir:
            ts_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            up_count, total_count = collect_apiserver_metrics_once(apiserver_data_dir, kubeconfig, ts_iso)
            if up_count is not None:
                collect_operator_progress_once(apiserver_data_dir, kubeconfig, ts_iso)
                print(f"  Apiserver metrics: up={up_count}/{total_count} (saved under {apiserver_data_dir})")

        if args.installplan:
            n = approve_pending_installplans(kubeconfig)
            if n:
                print(f"  Auto-approved {n} InstallPlan(s)")

        # Stability checks
        print_section("Stability checks")
        all_ok = True
        ok1, msg1 = check_cluster_operators(kubeconfig)
        print(f"  Cluster operators: {msg1}")
        if not ok1:
            all_ok = False
        ok2, msg2 = check_nodes(kubeconfig)
        print(f"  Nodes: {msg2}")
        if not ok2:
            all_ok = False
        ok3, msg3 = check_mcp(kubeconfig, mcp_updating_since)
        print(f"  MCP: {msg3}")
        if not ok3:
            all_ok = False
        ok4, msg4 = check_pods(kubeconfig)
        print(f"  Pods: {msg4}")
        if not ok4:
            all_ok = False
        ok5, msg5 = check_csv(kubeconfig)
        print(f"  CSVs (operators): {msg5}")
        if not ok5:
            all_ok = False
        ok6, msg6 = check_policies(kubeconfig)
        print(f"  Policies (ACM): {msg6}")
        if not ok6:
            all_ok = False
        ok7, msg7 = check_degraded_cluster_operators(kubeconfig)
        print(f"  Cluster operators (Degraded): {msg7}")
        if not ok7:
            all_ok = False

        if not all_ok and not args.no_troubleshoot:
            print_troubleshooting_report(kubeconfig)

        if all_ok:
            now = time.time()
            if stable_since is None:
                stable_since = now
            if args.stable_for <= 0 or (now - stable_since) >= args.stable_for:
                if apiserver_data_dir:
                    print_upgrade_summary_report(apiserver_data_dir, kubeconfig)
                if args.stable_for > 0:
                    print_section(f"Cluster stable for {int(now - stable_since)}s (required {args.stable_for}s) – exiting")
                else:
                    print_section("Cluster is STABLE – exiting")
                sys.exit(0)
            print(f"  Stable for {int(now - stable_since)}s (need {args.stable_for}s); continuing...")
        else:
            stable_since = None

        if args.diagnose:
            sys.exit(0 if all_ok else 1)

        print(f"\nNext check in {args.interval}s...")
        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\nInterrupted by user – exiting")
            if apiserver_data_dir:
                print_upgrade_summary_report(apiserver_data_dir, kubeconfig)
            sys.exit(130)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted by user – exiting")
        sys.exit(130)
