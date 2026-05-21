#!/usr/bin/env bash
#
# teardown.sh — orchestrate the LB-layer teardown in the right order. With a
# VPC endpoints config (optional 4th arg), the sequence is:
#   1. apply-dns-records.sh   <dns-file>      — delete the DNS records that
#                                                point at the ALBs (stops new
#                                                client traffic at the resolver).
#   2. update-service-alb.sh  <services-file> — detach ECS services from their
#                                                target groups; ECS rolls a new
#                                                deployment, the LB drains
#                                                existing connections.
#   3. (drain wait)                            — give the LB deregistration
#                                                delay time to finish before
#                                                the ALB disappears.
#   4. manage-albs.sh delete  <albs-file>     — delete the ALBs; their
#                                                listeners cascade. Target
#                                                groups survive (not managed
#                                                by this repo).
#   5. manage-vpce.sh delete  <vpce-file>     — delete the VPC endpoints (if
#                                                provided). DANGEROUS while
#                                                ECS tasks are still running:
#                                                see warning below.
#
# Without the VPCE arg, step 5 is skipped and the remaining four steps run
# as before (numbered 1/3..3/3 since the drain wait is not a step).
#
# **VPCE delete warning**: deleting VPC endpoints breaks any running ECS
# task that depends on them (ECR pulls, CloudWatch logs, Secrets Manager,
# SSM, etc.). teardown.sh does NOT stop ECS tasks — services persist after
# `update-service-alb.sh` detaches their LB association. If you supply
# <vpce-file>, scale services to 0 first (e.g. `shutdown.sh`) or the
# running tasks will start failing as the endpoints disappear.
#
# This script is a thin sequencer — it does not reimplement any of the
# above steps, it just delegates to the existing scripts in the right
# order. Each child's idempotency carries through: a failure mid-teardown
# leaves partial state, and re-running with the same args picks up from
# where it stopped (each child silently skips already-applied actions).
#
# Decision points the operator would otherwise get manually are preserved:
#   - one up-front confirmation (skippable with ASSUME_YES=1);
#   - a drain wait between the service-detach and ALB-delete steps
#     (DRAIN_SECONDS, default 30).
#
# Usage:
#   ./teardown.sh <dns-records-file> <services-file> <albs-file> [<vpce-file>]
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
#   HOSTED_ZONE_ID   Route 53 hosted zone identifier (for the DNS step)
# Optional:
#   AWS_PROFILE      passed through to the AWS CLI
#   ASSUME_YES=1     skip the up-front confirmation prompt
#   DRAIN_SECONDS=N  seconds to wait between detaching services and
#                    deleting the ALBs (default 30; set to 0 to skip)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <dns-records-file> <services-file> <albs-file> [<vpce-file>]" >&2
  exit 2
fi

DNS_FILE="$1"
SERVICES_FILE="$2"
ALBS_FILE="$3"
VPCE_FILE="${4:-}"

: "${AWS_REGION:?AWS_REGION is required}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID is required (for the DNS step)}"

files=("${DNS_FILE}" "${SERVICES_FILE}" "${ALBS_FILE}")
if [[ -n "${VPCE_FILE}" ]]; then
  files+=("${VPCE_FILE}")
fi
for f in "${files[@]}"; do
  if [[ ! -r "${f}" ]]; then
    echo "error: file not readable: ${f}" >&2
    exit 1
  fi
done

DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
if ! [[ "${DRAIN_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "error: DRAIN_SECONDS must be a non-negative integer (got '${DRAIN_SECONDS}')" >&2
  exit 1
fi

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Step labels shift depending on whether the VPCE step runs.
if [[ -n "${VPCE_FILE}" ]]; then
  TOTAL=4
  DNS_STEP="1/4"
  SERVICE_STEP="2/4"
  ALB_STEP="3/4"
  VPCE_STEP="4/4"
else
  TOTAL=3
  DNS_STEP="1/3"
  SERVICE_STEP="2/3"
  ALB_STEP="3/3"
fi

log "teardown plan in ${AWS_REGION} (${TOTAL} steps):"
log "  ${DNS_STEP}. DNS delete       <- ${DNS_FILE}"
log "  ${SERVICE_STEP}. detach services  <- ${SERVICES_FILE}"
log "     drain wait       ${DRAIN_SECONDS}s"
log "  ${ALB_STEP}. delete ALBs      <- ${ALBS_FILE}"
if [[ -n "${VPCE_FILE}" ]]; then
  log "  ${VPCE_STEP}. delete VPCEs     <- ${VPCE_FILE}"
  log "WARNING: VPCE delete breaks running ECS tasks that depend on the"
  log "  endpoints (ECR / logs / secrets / SSM). Make sure services are"
  log "  scaled to 0 before continuing — e.g. run ./scripts/shutdown.sh first."
fi

if ! confirm "Proceed with full teardown of the LB layer?"; then
  echo "aborted." >&2
  exit 1
fi

# Suppress the children's per-script confirmations now that we've confirmed
# once at the wrapper level. AWS_REGION and HOSTED_ZONE_ID are already in the
# environment from above; export them explicitly so child scripts inherit
# them even when they were sourced from .env in this process.
export AWS_REGION HOSTED_ZONE_ID
export ASSUME_YES=1

log "=== step ${DNS_STEP}: deleting DNS records ==="
"${SCRIPT_DIR}/apply-dns-records.sh" "${DNS_FILE}"

log "=== step ${SERVICE_STEP}: detaching ECS services from target groups ==="
"${SCRIPT_DIR}/update-service-alb.sh" "${SERVICES_FILE}"

if (( DRAIN_SECONDS > 0 )); then
  log "waiting ${DRAIN_SECONDS}s for LB deregistration to drain"
  sleep "${DRAIN_SECONDS}"
fi

log "=== step ${ALB_STEP}: deleting ALBs ==="
"${SCRIPT_DIR}/manage-albs.sh" delete "${ALBS_FILE}"

if [[ -n "${VPCE_FILE}" ]]; then
  log "=== step ${VPCE_STEP}: deleting VPC endpoints ==="
  "${SCRIPT_DIR}/manage-vpce.sh" delete "${VPCE_FILE}"
fi

log "teardown complete."
