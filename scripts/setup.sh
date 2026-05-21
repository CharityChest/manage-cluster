#!/usr/bin/env bash
#
# setup.sh — orchestrate the LB-layer setup in the right order:
#   1. manage-albs.sh create  <albs-file> <dns-out> <service-lbs-out>
#      Provisions ALBs and emits two templates: DNS records and service-LB.
#   2. apply-listeners.sh     <listeners-file>
#      Creates the listeners on each ALB. Forward actions reference target
#      groups that step 3 will then bind to ECS services.
#   3. update-service-alb.sh  <service-lbs-out>
#      Wires ECS services to their target groups (consumes the file
#      emitted in step 1). Auto-skipped if albs.conf declared no
#      ecs_service.* blocks (the emitted file is header-only).
#   4. apply-dns-records.sh   <dns-out>
#      Points DNS at the new ALBs (consumes the file emitted in step 1).
#      Last so external clients don't reach a half-built ALB.
#
# Like teardown.sh, this script is a **pure sequencer** — it delegates to
# the existing scripts in order and adds only the inter-step glue (one
# up-front confirmation, auto-skip of step 3 on empty service-LB output).
# It does not reimplement any setup logic.
#
# Idempotent: each child script is idempotent, so re-running the wrapper
# after a partial failure picks up where it stopped (ALBs already created
# are reused with their existing DNS info, matching listeners/services/
# DNS records are skipped).
#
# Usage:
#   ./setup.sh <albs-file> <dns-records-out> <service-lbs-out> <listeners-file>
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
#   HOSTED_ZONE_ID   Route 53 hosted zone identifier (for the DNS step)
# Optional:
#   AWS_PROFILE         passed through to the AWS CLI
#   ASSUME_YES=1        skip the up-front confirmation prompt
#   WAIT_FOR_ACTIVE=1   block until each new ALB reaches state 'active'
#                       before proceeding (passed through to manage-albs.sh).
#                       Typically 2-5 minutes per ALB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <albs-file> <dns-records-out> <service-lbs-out> <listeners-file>" >&2
  exit 2
fi

ALBS_FILE="$1"
DNS_FILE="$2"
SERVICE_LBS_FILE="$3"
LISTENERS_FILE="$4"

: "${AWS_REGION:?AWS_REGION is required}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID is required (for the DNS step)}"

# Inputs must exist and be readable.
for f in "${ALBS_FILE}" "${LISTENERS_FILE}"; do
  if [[ ! -r "${f}" ]]; then
    echo "error: input file not readable: ${f}" >&2
    exit 1
  fi
done

# Outputs must be writable. Truncate upfront so the failure surfaces here,
# not 3 minutes into manage-albs.sh.
for f in "${DNS_FILE}" "${SERVICE_LBS_FILE}"; do
  if ! : > "${f}" 2>/dev/null; then
    echo "error: output file not writable: ${f}" >&2
    exit 1
  fi
done

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

log "setup plan in ${AWS_REGION}:"
log "  1. provision ALBs   <- ${ALBS_FILE}"
log "                       -> ${DNS_FILE}, ${SERVICE_LBS_FILE}"
log "  2. apply listeners  <- ${LISTENERS_FILE}"
log "  3. wire services    <- ${SERVICE_LBS_FILE} (auto-skip if empty)"
log "  4. apply DNS        <- ${DNS_FILE}"
if [[ "${WAIT_FOR_ACTIVE:-0}" == "1" ]]; then
  log "wait-for-active: ON (step 1 blocks until each ALB reports 'active')"
fi

if ! confirm "Proceed with full setup?"; then
  echo "aborted." >&2
  exit 1
fi

# Suppress children's per-script confirmations now that we've confirmed once.
export AWS_REGION HOSTED_ZONE_ID
export ASSUME_YES=1

log "=== step 1/4: provisioning ALBs and emitting templates ==="
"${SCRIPT_DIR}/manage-albs.sh" create "${ALBS_FILE}" "${DNS_FILE}" "${SERVICE_LBS_FILE}"

log "=== step 2/4: creating listeners ==="
"${SCRIPT_DIR}/apply-listeners.sh" "${LISTENERS_FILE}"

# update-service-alb.sh errors on a config with zero [section] blocks, which
# is exactly what manage-albs.sh emits when no ecs_service.* keys are present
# anywhere in albs.conf. Detect that here and skip rather than crash.
if grep -q '^\[' "${SERVICE_LBS_FILE}"; then
  log "=== step 3/4: wiring ECS services to target groups ==="
  "${SCRIPT_DIR}/update-service-alb.sh" "${SERVICE_LBS_FILE}"
else
  log "step 3/4: skipping — no ECS service associations declared in ${ALBS_FILE}"
fi

log "=== step 4/4: applying DNS records ==="
"${SCRIPT_DIR}/apply-dns-records.sh" "${DNS_FILE}"

log "setup complete."
