#!/usr/bin/env bash
#
# Monitors ArgoCD Application(s) and prompts for manual InstallPlan approval.
# The ONLY manual cluster interaction this script performs is approving InstallPlans.
# Everything else is read-only observation.
#
# Usage:
#   ./monitor-argoapp-installplans.sh [--app <argo-app-name>] [--interval <seconds>]
#
# Examples:
#   ./monitor-argoapp-installplans.sh --app hub-operators-deployment
#   ./monitor-argoapp-installplans.sh                           # monitors all apps in openshift-gitops
#   ./monitor-argoapp-installplans.sh --interval 15             # poll every 15s

set -euo pipefail

ARGO_APP=""
INTERVAL=30
ARGOCD_NS="openshift-gitops"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  echo "Usage: $0 [--app <argo-app-name>] [--interval <seconds>]"
  echo ""
  echo "  --app        Specific ArgoCD Application name to monitor (default: all in ${ARGOCD_NS})"
  echo "  --interval   Polling interval in seconds (default: 30)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --app)      ARGO_APP="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          echo "Unknown option: $1"; usage ;;
  esac
done

check_prerequisites() {
  for cmd in oc jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}ERROR: '$cmd' is required but not found in PATH.${NC}"
      exit 1
    fi
  done

  if ! oc whoami &>/dev/null; then
    echo -e "${RED}ERROR: Not logged in to an OpenShift cluster. Run 'oc login' first.${NC}"
    exit 1
  fi
}

print_header() {
  echo -e "\n${BOLD}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  ArgoCD App Monitor & InstallPlan Approver${NC}"
  echo -e "${BOLD}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
}

get_argo_apps() {
  if [[ -n "$ARGO_APP" ]]; then
    echo "$ARGO_APP"
  else
    oc get applications.argoproj.io -n "$ARGOCD_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
  fi
}

show_app_status() {
  local app="$1"
  local sync health
  sync=$(oc get applications.argoproj.io "$app" -n "$ARGOCD_NS" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  health=$(oc get applications.argoproj.io "$app" -n "$ARGOCD_NS" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

  local sync_color="$NC"
  case "$sync" in
    Synced)    sync_color="$GREEN" ;;
    OutOfSync) sync_color="$YELLOW" ;;
    *)         sync_color="$RED" ;;
  esac

  local health_color="$NC"
  case "$health" in
    Healthy)    health_color="$GREEN" ;;
    Progressing) health_color="$CYAN" ;;
    Degraded)   health_color="$RED" ;;
    Suspended)  health_color="$YELLOW" ;;
    Missing)    health_color="$RED" ;;
    *)          health_color="$YELLOW" ;;
  esac

  printf "  ${BOLD}%-40s${NC} Sync: ${sync_color}%-12s${NC} Health: ${health_color}%-12s${NC}\n" \
    "$app" "$sync" "$health"
}

show_degraded_resources() {
  local app="$1"
  local degraded
  degraded=$(oc get applications.argoproj.io "$app" -n "$ARGOCD_NS" -o json 2>/dev/null \
    | jq -r '.status.resources[]? | select(.health.status != "Healthy" and .health.status != null) | "\(.kind)/\(.name) [\(.namespace // "cluster")] -> \(.health.status)"' 2>/dev/null)

  if [[ -n "$degraded" ]]; then
    echo -e "  ${YELLOW}Unhealthy resources in $app:${NC}"
    while IFS= read -r line; do
      echo -e "    ${YELLOW}- ${line}${NC}"
    done <<< "$degraded"
  fi
}

find_pending_installplans() {
  oc get installplans -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.approved == false) | "\(.metadata.namespace) \(.metadata.name) \(.spec.clusterServiceVersionNames | join(","))"' 2>/dev/null
}

approve_installplan() {
  local ns="$1" name="$2"
  echo -e "${GREEN}Approving InstallPlan ${BOLD}${name}${NC}${GREEN} in namespace ${BOLD}${ns}${NC}"
  oc patch installplan "$name" -n "$ns" --type merge -p '{"spec":{"approved":true}}'
}

process_pending_installplans() {
  local pending
  pending=$(find_pending_installplans)

  if [[ -z "$pending" ]]; then
    echo -e "\n  ${GREEN}No pending InstallPlans requiring approval.${NC}"
    return
  fi

  echo -e "\n${BOLD}  Pending InstallPlans requiring approval:${NC}"
  echo -e "  ─────────────────────────────────────────"

  local count=0
  declare -a plan_ns=()
  declare -a plan_name=()
  declare -a plan_csvs=()

  while IFS=' ' read -r ns name csvs; do
    count=$((count + 1))
    plan_ns+=("$ns")
    plan_name+=("$name")
    plan_csvs+=("$csvs")
    printf "  ${CYAN}[%d]${NC} %-30s  ns: %-35s  CSVs: %s\n" "$count" "$name" "$ns" "$csvs"
  done <<< "$pending"

  echo ""
  echo -e "  ${BOLD}Options:${NC}"
  echo -e "    ${CYAN}a${NC}   - Approve ALL pending InstallPlans"
  echo -e "    ${CYAN}1-$count${NC} - Approve a specific InstallPlan (space-separated for multiple)"
  echo -e "    ${CYAN}s${NC}   - Skip (do not approve any, continue monitoring)"
  echo -e "    ${CYAN}q${NC}   - Quit"
  echo ""
  read -rp "  Choose action: " choice

  case "$choice" in
    a|A)
      for i in $(seq 0 $((count - 1))); do
        approve_installplan "${plan_ns[$i]}" "${plan_name[$i]}"
      done
      ;;
    s|S)
      echo -e "  ${YELLOW}Skipped. Will check again next cycle.${NC}"
      ;;
    q|Q)
      echo -e "  ${YELLOW}Exiting.${NC}"
      exit 0
      ;;
    *)
      for idx in $choice; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= count )); then
          approve_installplan "${plan_ns[$((idx - 1))]}" "${plan_name[$((idx - 1))]}"
        else
          echo -e "  ${RED}Invalid selection: $idx${NC}"
        fi
      done
      ;;
  esac
}

main() {
  check_prerequisites
  echo -e "${GREEN}Monitoring started. Polling every ${INTERVAL}s. Press Ctrl+C to stop.${NC}"
  if [[ -n "$ARGO_APP" ]]; then
    echo -e "Watching ArgoCD Application: ${BOLD}${ARGO_APP}${NC}"
  else
    echo -e "Watching all ArgoCD Applications in namespace: ${BOLD}${ARGOCD_NS}${NC}"
  fi

  while true; do
    print_header

    echo -e "\n${BOLD}  ArgoCD Application Status:${NC}"
    echo -e "  ─────────────────────────────────────────"
    for app in $(get_argo_apps); do
      show_app_status "$app"
      show_degraded_resources "$app"
    done

    process_pending_installplans

    echo -e "\n${CYAN}  Next check in ${INTERVAL}s... (Ctrl+C to exit)${NC}"
    sleep "$INTERVAL"
  done
}

main
