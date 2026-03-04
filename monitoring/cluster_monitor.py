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

When all criteria pass for at least --stable-for seconds, the program exits with rc 0.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

# Default stability thresholds (seconds)
MCP_UPDATING_MAX_SECONDS = 10 * 60   # 10 minutes
POD_STUCK_SECONDS = 10 * 60         # 10 minutes
CSV_INSTALLING_MAX_SECONDS = 10 * 60  # 10 minutes (Installing longer = stuck)

# Policy evaluation scope: only policies in this namespace are checked for stability
POLICY_NAMESPACE = "local-cluster"


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
            stuck.append(f"{ns}/{name} ({phase}, {int(age)}s)")
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
    args = parser.parse_args()

    if not args.kubeconfig:
        print("Set KUBECONFIG or pass --kubeconfig (e.g. export KUBECONFIG=/path/to/kubeconfig)", file=sys.stderr)
        sys.exit(1)

    kubeconfig = args.kubeconfig
    mcp_updating_since = {}
    stable_since = None  # time when we first saw all checks pass; None if not currently stable

    print(f"Using KUBECONFIG={kubeconfig}")
    print(f"Auto-approve InstallPlans: {args.installplan}")
    print(f"Stability: no CO Progressing, all nodes Ready, MCP not updating > 10 min, no pods in transient state > 10 min, no CSV stuck in Installing > 10 min, all {POLICY_NAMESPACE} policies Compliant")
    if args.stable_for > 0:
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

        if all_ok:
            now = time.time()
            if stable_since is None:
                stable_since = now
            if args.stable_for <= 0 or (now - stable_since) >= args.stable_for:
                if args.stable_for > 0:
                    print_section(f"Cluster stable for {int(now - stable_since)}s (required {args.stable_for}s) – exiting")
                else:
                    print_section("Cluster is STABLE – exiting")
                sys.exit(0)
            print(f"  Stable for {int(now - stable_since)}s (need {args.stable_for}s); continuing...")
        else:
            stable_since = None

        print(f"\nNext check in {args.interval}s...")
        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\nInterrupted by user – exiting")
            sys.exit(130)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted by user – exiting")
        sys.exit(130)
