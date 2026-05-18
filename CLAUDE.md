# CLAUDE.md

Guidance for Claude Code when working in this repository.

---

## Purpose

This repo contains operational scripts for pausing and resuming the Charity
Chest AWS infrastructure (ECS Fargate services + RDS Postgres) for cost
savings during planned downtime. It is **not** a deployment tool — deployments
live in the sibling `charity-chest` repo under `.github/workflows/`.

## Repository layout

```
manage-cluster/
├── README.md
├── CLAUDE.md
└── scripts/
    ├── shutdown.sh    # scale ECS services to 0 + stop RDS instance
    ├── startup.sh     # start RDS instance + scale ECS services back up
    └── status.sh      # read-only diagnostic: task counts + RDS status
```

There is no build system, package manager, or test suite. Everything is plain
bash + AWS CLI.

## Conventions

- **Shell**: bash 4+, `set -euo pipefail` at the top of every script.
- **Config loading**: scripts source `scripts/.env` if present, then validate
  required variables with `: "${VAR:?msg}"`. Required env vars must fail fast
  with a clear error.
- **AWS CLI invocation**: build a shared `AWS=(aws --region "${AWS_REGION}")`
  array and call it as `"${AWS[@]}" <service> <verb>`. Always pass
  `--no-cli-pager` on mutating calls so they don't block in a TTY.
- **Idempotency**: every action must be safe to re-run. Check current state
  (`describe-services`, `describe-db-instances`) and skip the call when
  already in the target state.
- **Logging**: use the `log()` helper — `[HH:MM:SS] message`. One line per
  action. No emoji.
- **Confirmation**: destructive/operational scripts must prompt before acting,
  with an `ASSUME_YES=1` escape hatch for cron.

## Sibling project context

The infrastructure this repo manages is provisioned and deployed from
`../charity-chest`. Key facts pulled from its README/workflows:

- ECS cluster runs **two Fargate services**: server (Go API) and webapp
  (Next.js). The deploy workflow uses variables `ECS_CLUSTER`,
  `ECS_SERVICE_SERVER`, `ECS_SERVICE_WEBAPP`, `AWS_REGION`.
- Task definitions pin `runtimePlatform.cpuArchitecture` (X86_64 or ARM64);
  Fargate selects the matching variant from a multi-arch ECR manifest. This
  does not affect shutdown logic but matters for any future "restart" or
  "redeploy" script.
- RDS is a single Postgres instance, not Aurora — `stop-db-instance` works.

If you add a script that needs to know which services exist, prefer
`aws ecs list-services` over hardcoding names: it keeps this repo decoupled
from the sibling's naming.

## Hard AWS constraint to remember

> **RDS auto-starts a stopped instance after 7 days.** This is not
> configurable. Any "keep it off" strategy must re-run `stop-db-instance` on
> a cadence shorter than 7 days. If a user asks for a longer pause without
> re-running, push back — the alternatives are snapshot + delete, or
> migrating to Aurora Serverless v2 with auto-pause.

## Stateless pair: shutdown ↔ startup

The two scripts are intentionally **stateless**. `shutdown.sh` does not record
previous desired counts, and `startup.sh` does not read any persisted state.
Target counts on resumption come from env vars:

- `DESIRED_COUNT` (default `1`) — fallback applied to any service without an
  override.
- `ECS_DESIRED_COUNTS="server=2 webapp=1"` — per-service overrides.

If a future caller needs exact restoration to pre-shutdown counts, add a
snapshot file (e.g. `scripts/.state/desired-counts.tsv`), have `shutdown.sh`
write it before scaling, and have `startup.sh` consume + delete it. Don't
introduce that file unless there's a real need — it adds coupling between the
two scripts and creates a new failure mode (stale state).

`startup.sh` starts RDS asynchronously by default; pass `WAIT_FOR_RDS=1` to
block on `aws rds wait db-instance-available` (5–10 minutes typical) before
scaling services up. Without the wait, ECS tasks may restart-loop for a few
minutes until the database is reachable — usually fine, occasionally not.

## When extending this repo

When you add a new script:

1. Mirror the structure of `shutdown.sh` for **mutating** scripts (env
   loading, validation, `AWS=` array, `log` helper, `confirm` helper,
   idempotent action functions, `main` at the bottom). For **read-only**
   scripts, follow `status.sh` instead: skip the `log`/`confirm`/`ASSUME_YES`
   patterns and emit tabular output rather than timestamped log lines.
2. Add a row to README.md's table of scripts.
3. `chmod +x` the file and verify `bash -n` parses cleanly.

## Common pitfalls

- `aws ecs list-services` paginates by default — the existing script uses
  `--output text --query 'serviceArns[]'` then `awk -F/` to extract names.
  Don't switch to JSON parsing without adding `jq` as a dependency, which
  this repo currently avoids.
- `aws ecs update-service --desired-count 0` does **not** delete the service
  or its task definition; it only stops running tasks. This is intentional.
- An RDS instance in `modifying`, `backing-up`, `rebooting`, etc. cannot be
  stopped — the script logs and skips rather than retrying. Don't add a
  retry loop without thinking about how long such states can last (minutes
  to hours).
- Do not assume `AWS_PROFILE` or default credentials are configured. The
  AWS CLI will surface its own error; don't pre-validate.
