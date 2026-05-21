#!/usr/bin/env bash
#
# teardown.sh — orchestrate the LB-layer teardown in the right order:
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
#
# This script is a thin sequencer — it does not reimplement any of the
# above steps, it just delegates to the existing scripts in the right
# order. Each child's idempotency carries through: a failure mid-teardown
# leaves partial state, and re-running with the same args picks up from
# where it stopped (each child silently skips already-applied actions).
#
# Decision points the operator would otherwise get manually are preserved:
#   - one up-front confirmation (skippable with ASSUME_YES=1);
#   - a drain wait between steps 2 and 4 (DRAIN_SECONDS, default 30).
#
# Usage:
#   ./teardown.sh <dns-records-file> <services-file> <albs-file>
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

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <dns-records-file> <services-file> <albs-file>" >&2
  exit 2
fi

DNS_FILE="$1"
SERVICES_FILE="$2"
ALBS_FILE="$3"

: "${AWS_REGION:?AWS_REGION is required}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID is required (for the DNS step)}"

for f in "${DNS_FILE}" "${SERVICES_FILE}" "${ALBS_FILE}"; do
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

log "teardown plan in ${AWS_REGION}:"
log "  1. DNS delete       <- ${DNS_FILE}"
log "  2. detach services  <- ${SERVICES_FILE}"
log "     drain wait       ${DRAIN_SECONDS}s"
log "  3. delete ALBs      <- ${ALBS_FILE}"

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

log "=== step 1/3: deleting DNS records ==="
"${SCRIPT_DIR}/apply-dns-records.sh" "${DNS_FILE}"

log "=== step 2/3: detaching ECS services from target groups ==="
"${SCRIPT_DIR}/update-service-alb.sh" "${SERVICES_FILE}"

if (( DRAIN_SECONDS > 0 )); then
  log "waiting ${DRAIN_SECONDS}s for LB deregistration to drain"
  sleep "${DRAIN_SECONDS}"
fi

log "=== step 3/3: deleting ALBs ==="
"${SCRIPT_DIR}/manage-albs.sh" delete "${ALBS_FILE}"

log "teardown complete."
