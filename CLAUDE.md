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
    ├── shutdown.sh           # scale ECS services to 0 + stop RDS instance
    ├── startup.sh            # start RDS instance + scale ECS services back up
    ├── status.sh             # read-only diagnostic: task counts + RDS status
    ├── apply-dns-records.sh  # apply upsert/delete changes to a Route 53 zone
    ├── manage-albs.sh        # create/delete ALBs + emit DNS + service-LB templates
    ├── update-service-alb.sh # replace/clear/append/detach-one loadBalancers on ECS services
    ├── apply-listeners.sh    # create/update ALB listeners (tier-2 scope)
    ├── manage-vpce.sh        # create/delete VPC endpoints (Interface/Gateway) + optional per-endpoint policy
    ├── setup.sh              # one-shot wrapper: provision -> listeners -> services -> DNS
    ├── teardown.sh           # one-shot wrapper: DNS delete -> detach -> delete ALBs
    └── config/               # INI/text configs consumed by the scripts above
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

## DNS records via `apply-dns-records.sh`

The script takes a plain-text records file (`ACTION TYPE NAME TTL VALUE[|VALUE...]`)
and submits one Route 53 `change-resource-record-sets` call. Two design points
worth knowing before extending it:

- **Idempotency strategy is asymmetric.** UPSERT is always safe to re-run
  (Route 53 replaces in place), so the script doesn't pre-diff upserts. DELETE
  is different: Route 53 requires the change to specify the *exact* current
  `ResourceRecordSet` and errors otherwise. The script fetches current state
  via `list-resource-record-sets` + a JMESPath filter and either inlines that
  object into a DELETE change, or skips the line if the record is absent. If
  you add a new action, decide which side of this split it falls on.
- **No `jq`.** Change batches are small, so the script builds the JSON with
  `printf` and uses the AWS CLI's `--query` to *extract* JSON objects from
  Route 53 responses (e.g. `--query "ResourceRecordSets[?Name=='X' && Type=='Y'] | [0]"`
  with `--output json` returns either a record-set object or `null`). Don't
  add `jq` to do this — the existing pattern handles every record type the
  Charity Chest zone uses.

Records file format notes for future edits:

- Tokenized with `read -r action type name ttl values_pipe`, so the *last*
  field absorbs the rest of the line. That's deliberate — it lets TXT values
  contain spaces (e.g. `"v=spf1 include:... -all"`) without quoting tricks.
- Multi-value record sets use `|` as the value separator. Don't switch to
  whitespace — that would collide with the TXT-with-spaces behaviour above.
- The `alias` action reuses the same five-column slot — `ttl` holds the
  target's AWS-managed hosted zone ID and `values_pipe` holds
  `TARGET_DNS_NAME [EVAL_HEALTH]`. That overload is why parsing happens in
  two stages (positional read into the shared variables, then per-action
  re-splitting). Don't introduce a sixth column; keep the layout uniform
  across actions so the parsing stays a single `read`.

Alias records are structurally distinct from value-based records: no `TTL`,
no `ResourceRecords`, instead an `AliasTarget {DNSName, HostedZoneId,
EvaluateTargetHealth}`. The script handles this via a separate
`build_alias_change` builder; only types `A` and `AAAA` are valid for
aliases (Route 53's restriction, enforced in the parser). Deletions of alias
records work without a code path of their own — `fetch_record_set` returns
the existing `ResourceRecordSet` JSON verbatim, including its `AliasTarget`,
and DELETE accepts that.

Target hosted-zone IDs (the value of `AliasTarget.HostedZoneId`) are
**AWS-managed** and resource-specific:
- ALB/NLB: per-region, look up with `aws elbv2 describe-load-balancers
  --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]'`.
- CloudFront: always `Z2FDTNDATAQYW2`.
- Other resources (S3 website, API Gateway, etc.): consult AWS docs.

Don't hard-code an ALB zone ID in this repo — they differ per region, and
the deploy workflow in `../charity-chest` can move services across regions.
Have the operator paste the value into their records file from the lookup
command above.

## ALB lifecycle via `manage-albs.sh`

The script's scope is deliberately narrow: it manages the ALB **shell** (the
LB resource, its scheme/IP type/subnets/security groups/tags) and nothing
else. Listeners, target groups, and listener rules are explicitly excluded
because they belong to the application's deploy pipeline (the workflows in
`../charity-chest`), not the cost-management surface in this repo. Don't
extend `manage-albs.sh` to create listeners — if a listener is needed, add
a separate script.

Config is INI-style (`[name]` section per ALB) rather than the one-line
columnar format used by `apply-dns-records.sh`. The two formats coexist on
purpose: ALB configs have ~7 fields per row including comma-separated lists,
which is unreadable as one line; DNS records have ~5 fields and are
naturally tabular. Don't unify them.

The create path **always** writes a DNS records header to the output target
even when no ALBs declare `dns_names` — and the script then either flushes
to stdout (and cleans up the tmpfile) if no DNS lines were appended, or
keeps the file in place. The records output uses the new `alias` action and
is intentionally drop-in for `apply-dns-records.sh`. When extending the
records format, change both scripts in lockstep.

Idempotency contract:
- `create`: a name collision is treated as a successful no-op — the existing
  ALB's DNS info is still captured and included in the records output. This
  matters for partial-failure recovery: if a previous run created ALB A but
  errored before ALB B, re-running the same config completes the work and
  produces a *complete* records file.
- `delete`: missing ALBs are silently skipped. Don't add a confirmation
  per-ALB; the single up-front confirm is enough (the config IS the spec).

`describe-load-balancers --names X` errors with non-zero exit when X doesn't
exist. The script intentionally swallows that via `2>/dev/null` and treats
the failure as "absent." Don't switch to listing all LBs and grepping — it
doesn't scale and breaks pagination.

## ECS service ↔ ALB wiring

`update-service-alb.sh` is the third stage in the
`manage-albs.sh` → `apply-dns-records.sh` → `update-service-alb.sh` pipeline.
It mutates the `loadBalancers` field on a running ECS service via
`aws ecs update-service --load-balancers <json>`. Key facts:

- AWS allows changing `loadBalancers` on a live service only since 2022, and
  only when the service is on Fargate platform version **1.4.0+** (default
  since 2020). The CLI surfaces a clear error on older versions; the script
  doesn't pre-check.
- `--load-balancers` **replaces** the entire array. There is no native
  "add one" or "remove one" operation — the script synthesizes both. Four
  section modes encode the user intent:
  - `target_group_arn` set → replace with this single entry.
  - `clear=true` → submit `'[]'`.
  - `add_target_group_arn=<arn>` (+ `container_name`/`container_port`) →
    fetch the current array as JSON, splice the new entry in before the
    closing `]`, submit. The splice (`${current_json%]},${new_entry}]`)
    works because JSON is whitespace-insensitive, and it deliberately
    preserves any fields the API may add in the future that the script
    doesn't model explicitly.
  - `remove_target_group_arn=<arn>` → submit
    `loadBalancers[?targetGroupArn!='<arn>']` (filtered via JMESPath at
    describe-services time and passed straight to update-service). JMESPath
    + `--output json` returns a valid array literal that update-service
    accepts verbatim — no `jq` needed.

  All four modes are mutually exclusive — `validate_service` enforces that
  exactly one is set per section. `add` and `remove` are intentionally
  asymmetric in their implementation: `remove` filters via JMESPath (the
  server does the work), `add` splices client-side (because JMESPath has
  no array-append). Both avoid jq.

  Idempotency for `add` and `remove` keys off `targetGroupArn` alone (each
  target group can only be attached once per service). The `replace` mode
  uses the full `(targetGroupArn, containerName, containerPort)` triplet
  since you can change those independently.
- ECS auto-rolls a new deployment on any LB change, so
  `--force-new-deployment` is opt-in (`FORCE_NEW_DEPLOYMENT=1`) rather than
  default. Don't make it default — it adds churn on idempotent re-runs.

Idempotency is implemented by reading
`services[0].loadBalancers[].[targetGroupArn,containerName,containerPort]`
as tab-separated text and string-comparing to the desired triplet. That
works because each service has at most one LB association in the Charity
Chest setup. If a future service needs multiple associations (rare), this
comparison will need to switch to JSON output and structural diffing.

### Template flow into `update-service-alb.sh`

`manage-albs.sh` accepts optional `ecs_service.<name>.{cluster,
container_name, container_port, target_group_arn}` keys under each ALB
section and emits a service-LB template (4th positional arg) ready to feed
into `update-service-alb.sh`. The flow is **declarative throughout**: the
same source-of-truth ALB config drives both ALB provisioning and the
downstream templates. Don't introduce a competing config format for the
service-LB step — extend the ALB config or add new keys here.

`target_group_arn` values are intentionally pass-through: `manage-albs.sh`
does not create target groups (those live in Terraform or the deploy
workflow), it just copies the ARNs into the emitted template. If the user
ever wants the script to *also* create target groups, that's a real scope
expansion — discuss before adding.

## ALB listeners via `apply-listeners.sh`

`apply-listeners.sh` is **tier 2** of the listener model: HTTP/HTTPS only,
a single default action of `forward` / `redirect` / `fixed-response`. The
ELBv2 listener model has a lot more (rules with host/path/header/query/IP
conditions, OIDC and Cognito auth actions, mTLS, weighted forwards, multi-
cert SNI). Don't extend this script into those — it would require a real
config language (JSON/YAML) and the breakage radius is high. If Charity
Chest needs path-based routing, do it in Terraform.

### Wiring to the ECS service

There is no separate "attach listener to service" step in the pipeline.
The wiring is the **shared target group ARN**: the same ARN appears as
`default_target_group_arn` in `listeners.conf` and as `target_group_arn` in
the corresponding `[service]` section of `service-lbs.conf`. Both scripts
converge on that TG, traffic flows. Don't add an explicit "associate"
script — it would be redundant and create another coordination point.

### Idempotency design

Listener identity on AWS is `(alb_arn, port)`. The script:
1. Resolves `alb_name` to an ARN via `describe-load-balancers --names`.
2. Queries `Listeners[?Port==<port>]` on that ALB and selects 14 fields
   (Protocol, Certificate ARN, SSL policy, action type, plus the
   action-type-specific fields) as a tab-separated row via `--output text`.
3. Builds the *same* 14-field row from config, using `None` as the
   sentinel for unset fields — matching AWS CLI's text rendering of JSON
   null. AWS-side defaults for redirect (`#{host}`, `/#{path}`, `#{query}`)
   are mirrored in the desired-state helper so a config that omits those
   keys still compares equal after the first apply.
4. If rows match, skip. If listener exists but differs, `modify-listener`.
   If listener absent, `create-listener`.

The 14-field projection is a deliberate trade. It catches the fields that
typically change (cert rotation, target group swap, redirect rewrites) but
ignores things like `Tags`, `AlpnPolicy`, and `MutualAuthentication`. If
those start mattering, extend the field list — but don't switch to
structural JSON diffing without a real reason; the text approach keeps the
script jq-free and matches the convention used by every other script in
this repo.

### Default-actions JSON

The script builds `--default-actions` JSON inline with `printf`, like
`build_upsert_change` in apply-dns-records.sh. For `redirect` and
`fixed-response`, optional fields default to AWS pass-through placeholders
(`#{host}`, `/#{path}`, `#{query}`) or sensible content types (`text/plain`).
String values go through `json_escape` (backslash + double-quote only) —
control characters in listener bodies are unsupported, and if anyone tries
to use a multi-line `fixed_body`, the script will misbehave. Document
rather than handle.

## Setup and teardown ordering

The five scripts that touch the LB layer form a pipeline with a strict
dependency order, with `manage-vpce.sh` as an opt-in book-end on either
side. README documents the user-facing commands; the invariants worth
remembering when extending:

**Setup order** is `[VPCE →] ALB → listeners → services → DNS`. Each step
unblocks the next:
- new ECS tasks (started in the service-wire step) need ECR / logs /
  secrets endpoints reachable, which is what the VPCE step provides;
- listeners can't attach to an ALB that doesn't exist;
- a listener with `forward` action serves 502 until the target group has
  healthy registered targets (which `update-service-alb.sh` provides);
- pointing DNS at a half-built ALB exposes errors to clients.

VPCE goes first (when the optional 5th positional arg is passed to
`setup.sh`) because it has no dependency on the LB layer and the ECS step
later in the pipeline depends on it. The ALB doesn't need VPCEs, so if
`setup.sh` is being used purely to re-provision the LB shell (services
already paused), skip the VPCE arg.

**Teardown order is the reverse**, `DNS → services → ALB [→ VPCE]`, for
the same reasons run backwards:
- removing DNS first stops *new* connections at the resolver level;
- detaching services next drains *existing* connections via the LB's
  deregistration delay;
- deleting the ALB last is then a no-op for clients;
- VPCEs go last (when the optional 4th positional arg is passed to
  `teardown.sh`) because their delete is harmless to LB-layer resources
  but **breaks any still-running ECS task** that depends on them. The
  wrapper logs an explicit warning before confirmation, but the caller is
  expected to have stopped ECS tasks (e.g. via `shutdown.sh`) before
  running teardown with the VPCE arg.

Deleting an ALB cascades to its listeners (AWS-side). Target groups are
**not** cascaded — they're independent resources, and this repo
deliberately doesn't manage them (see the `manage-albs.sh` scope note
above). A teardown leaves TGs orphaned, which is fine because Terraform
or the deploy workflow in `../charity-chest` owns them.

`teardown.sh` is the one-shot wrapper for this sequence. It is a **pure
sequencer** — it shells out to the three (or four, with VPCE) child
scripts in order and adds these thin affordances:
1. one up-front confirmation, then `export ASSUME_YES=1` so the children
   don't re-prompt;
2. a `sleep ${DRAIN_SECONDS:-30}` between the service-detach step and the
   ALB-delete step, so existing LB connections finish draining before the
   ALB disappears;
3. an explicit warning when the optional VPCE arg is supplied, reminding
   the operator that VPCE delete will break any still-running ECS task
   that depends on those endpoints.

The wrapper does **not** reimplement any teardown logic. If you find
yourself adding teardown behavior, put it in the relevant child script
(so the manual flow stays at parity) and keep `teardown.sh` as a thin
shim. The biggest risk with a wrapper like this is drift from the
underlying scripts, not the choice to have one — the children are
idempotent and the inter-step delay that actually matters (LB drain) is
modeled explicitly.

`setup.sh` is the symmetric wrapper for the reverse direction. Same shim
discipline: it shells out to `manage-vpce.sh create` (if the optional arg
is supplied), `manage-albs.sh create`, `apply-listeners.sh`,
`update-service-alb.sh`, and `apply-dns-records.sh` in order, with one
up-front confirmation and `ASSUME_YES=1` exported to the children.

The only setup-specific affordance is the **auto-skip of the service-wire
step** when `manage-albs.sh` emitted a header-only `service-lbs.conf` (no
`ecs_service.*` blocks in `albs.conf`). The wrapper detects this by
grepping for any `^\[` section header in the emitted file before
invoking `update-service-alb.sh`. Without that guard the child errors
on a zero-section config and the wrapper crashes mid-pipeline. If
future child scripts grow similar "empty input = error" behavior, add an
equivalent guard here.

Both wrappers expose the VPCE step as an **optional positional arg**
(5th for setup, 4th for teardown). Omitting it preserves the original
4-step / 3-step behaviour byte-for-byte. The opt-in design is deliberate:
many setup invocations (LB-only re-provision, dev iteration on listener
configs) don't want to touch VPCEs, and silently provisioning or deleting
them would be a footgun. When extending, keep the arg optional — don't
promote it to a required input.

Step numbering in log lines reflects the total dynamically: `1/4..4/4`
without VPCE, `1/5..5/5` with VPCE. Variables (`VPCE_STEP`, `ALB_STEP`,
`LISTENER_STEP`, `SERVICE_STEP`, `DNS_STEP`) compute the labels once at
the top and are reinjected into the `log` calls — don't hard-code step
numbers, or you'll drift between the two modes.

What setup deliberately does **not** do:
- No inter-step delay. There is no setup analog of the LB drain wait:
  listeners can attach to a provisioning ALB; services can register with
  a TG whose listener returns 503 (no client traffic yet because DNS is
  step 4). The "wait until ALB active" affordance exists already on
  `manage-albs.sh` as `WAIT_FOR_ACTIVE=1`; the wrapper just lets it pass
  through.
- No `startup.sh` invocation. Pause/resume of ECS+RDS is a separate
  concern from LB provisioning — see "Pause vs. teardown" below.

When extending, both wrappers must stay symmetric: same arg-validation
style, same `log`/`confirm`/`ASSUME_YES` pattern, same "pure sequencer"
boundary (no teardown/setup logic implemented in the wrappers
themselves). Drift between them is the real maintenance risk.

## Pause vs. teardown

These are two distinct flows and the README spells out the difference for
users. The repo invariant for extenders is: **never have the same script
do both.** `shutdown.sh`/`startup.sh` are state-preserving pause/resume —
scale ECS to 0, stop RDS, leave everything else alone. The teardown flow
is destructive — it removes LB-layer resources entirely. Conflating them
would lose the ability to pause without re-provisioning the LB shell on
every resume (which is much slower and changes the ALB DNS name, which
in turn breaks DNS records).

`manage-vpce.sh` participates in the LB-teardown / LB-setup pipeline via
opt-in args on the two wrappers, but it is **not** on the pause/resume
axis — `shutdown.sh`/`startup.sh` deliberately don't touch VPCEs.
Rationale: pause/resume is meant to be fast (~30s to scale down,
~10 minutes if `WAIT_FOR_RDS=1`), and recreating an interface endpoint
adds ~1 minute per endpoint per region on resume. For nightly pauses
that's pure overhead; for week-plus pauses or true teardowns the savings
justify the latency, which is why the VPCE arg lives on `setup.sh` /
`teardown.sh` (intent: full-fidelity provision/teardown) rather than
`shutdown.sh` / `startup.sh` (intent: keep state, minimize cycle time).

## VPC endpoints via `manage-vpce.sh`

The script's scope is the **endpoint resource itself** — its type, target
service, subnet/SG/route-table associations, policy document, and tags.
Everything around it is excluded by design:

- VPCs, subnets, route tables, security groups — created out of band
  (Terraform in `../charity-chest`).
- The private hosted-zone records auto-published by AWS when
  `private_dns_enabled=true` — AWS-managed; they appear and disappear with
  the endpoint and are not a separate thing for this script to manage.
- Modifying a live endpoint — see "Modify is out of scope" below.

Drift caveat worth flagging in the docs and in PRs: VPC endpoints are
often Terraform-owned in the sibling repo. Deleting them with this script
will surface as drift on the next `terraform apply`. The header docstring
and README both call this out — don't silently drop the warning when
extending.

### Idempotency design

Endpoint identity on AWS is the `VpcEndpointId`, but that's an opaque
generated ID — useless as a config primary key. The script uses
`(vpc_id, service_name)` instead: AWS only allows one Interface/Gateway
endpoint per service per VPC, so this is the natural primary key.
`describe-vpc-endpoints` filtered by
`Name=vpc-id,Values=X Name=service-name,Values=Y` resolves the section
back to its endpoint ID for delete.

This is a deliberate departure from `manage-albs.sh`'s "section header IS
the resource name" convention. Reason: VPC endpoints don't have a true
`name` field on the AWS side (unlike ALBs, which `describe-load-balancers
--names X` accepts directly) — only an opaque ID and tags. Looking up by
`Name` tag would force users to pre-tag pre-existing endpoints before
this script could touch them, which is a footgun. Looking up by
`service-name` works regardless of how the endpoint was created (Console,
Terraform, this script).

The section header is still applied as the `Name` tag at create time —
purely for Console readability, not for lookup. The script refuses a
`Name` key inside `tags=` so the section header is the single source of
truth for the user-visible name. Don't relax that — even though Name isn't
load-bearing for identity anymore, having two places to set it leads to
confusing diffs in the Console.

`delete` requires both `vpc_id` and `service_name` in the section
(enforced up front by `validate_for_delete`) since the lookup now needs
the service name. A "section-header-only" delete config (like the one
`manage-albs.sh delete` accepts) is therefore not valid here — that
asymmetry is the cost of having a real primary key.

### Modify is out of scope

Changing `service_name` or `vpc_id` requires a recreate anyway (AWS won't
modify those in place). Subnets, SGs, and the policy document *can* be
modified live via `ec2 modify-vpc-endpoint`, but the cost-management use
case this script addresses doesn't need it — pauses delete and recreates
fresh from config. Adding a modify path would also force a real "diff"
implementation (compare desired vs. current subnets/SGs/policy across the
two endpoint types), which is the kind of complexity the rest of this
repo deliberately avoids. If a real need shows up, discuss before adding
— it's a meaningful scope expansion.

### Policy attachment

`policy_file` per section, resolved relative to the **config file's
directory** (not CWD, not `SCRIPT_DIR`). That gives a "policies live next
to the config that references them" layout, and means a config can be
checked into the repo and run from anywhere without breaking path
resolution. Readability is validated up front so the whole batch fails
fast before any AWS calls.

The policy is embedded into the endpoint resource via
`--policy-document file://...` — there is no separate "policy attach"
step, and therefore no extra IAM permission needed. Don't refactor to
upload the policy somewhere else first; the inline file:// form is the
ELBv2/EC2 idiom.

If `policy_file` is omitted, AWS applies its default full-access policy.
That's deliberately the same default as the AWS Console — surprise the
operator only when they explicitly ask for restriction.

### Interface vs. Gateway

The two endpoint types take **disjoint** key sets — subnets/SGs/private
DNS for Interface; route tables for Gateway. The script validates this up
front and refuses configs that mix them, rather than letting the AWS CLI
reject the call with a less helpful error. When extending, keep the same
shape: declare which type a key belongs to and validate in `validate_endpoint`.

### Optional in the LB pipeline

`manage-vpce.sh` is wired into both `setup.sh` (optional 5th positional
arg) and `teardown.sh` (optional 4th). It runs **first** on setup (VPCEs
before ALBs, so ECS tasks that come up in the service-wire step have
ECR/logs/secrets reachable) and **last** on teardown (after ALB delete,
since neither resource depends on the other).

Setup-side ordering rationale is straightforward — network endpoints
before compute. Teardown-side has the footgun: deleting VPCEs while ECS
tasks are still running causes those tasks to start failing (ECR pulls
time out, log shipping fails, secret lookups error). `teardown.sh` does
**not** stop ECS tasks — it only detaches services from LB target groups.
So when the VPCE arg is supplied, the wrapper logs an explicit warning
before the confirmation prompt; the caller is expected to have already
scaled services to 0 (typically via `shutdown.sh`). Don't try to enforce
this in the wrapper by, say, refusing to proceed if any task is running —
the false-positive rate is too high (a long-running migration container,
a sidecar that doesn't use VPCEs) and `teardown.sh` is meant to be a
pure sequencer.

The VPCE arg is intentionally optional on both wrappers, not required:
many setup invocations only re-provision the LB shell (services already
paused), and many teardowns only remove the LB layer because VPCEs are
managed elsewhere (Terraform in `../charity-chest`). Keep it that way —
don't promote to a required arg.

## `scripts/config/` directory convention

Hand-authored INI/text configs and the templates emitted by
`manage-albs.sh` both live under `scripts/config/`. Suggested filenames
(consumed by the matching scripts):

- `albs.conf` — input to `manage-albs.sh create|delete`
- `dns-records.txt` — output of `manage-albs.sh create`, input to
  `apply-dns-records.sh` (for the setup path)
- `dns-records-delete.txt` — hand-authored `delete` rows, input to
  `apply-dns-records.sh` (for the teardown path)
- `service-lbs.conf` — output of `manage-albs.sh create`, input to
  `update-service-alb.sh` (for the setup path)
- `remove-albs-from-services.conf` — hand-authored `clear=true` or
  `remove_target_group_arn` sections, input to `update-service-alb.sh`
  (for the teardown path)
- `listeners.conf` — hand-authored, input to `apply-listeners.sh`
- `vpce.conf` — hand-authored, input to `manage-vpce.sh create|delete`.
  Per-endpoint policy JSON files live alongside it (e.g. under
  `scripts/config/policies/`) since `manage-vpce.sh` resolves
  `policy_file` paths relative to the config file's directory.

The directory is not a hard contract — every script accepts its config
path as a CLI argument and can read from anywhere — but README uses these
names in the documented sequences, so future scripts should default to
them when emitting templates.

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
- `aws route53 list-resource-record-sets --start-record-name X --start-record-type Y`
  returns records starting at X in alphabetical order — if X doesn't exist,
  the first result is the *next* record in the zone, not an empty list. Always
  filter with a JMESPath `?Name=='X' && Type=='Y'` predicate before using the
  result; never trust positional `[0]` alone.
- Route 53 is a global service, but `apply-dns-records.sh` still requires
  `AWS_REGION` for consistency with the other scripts (and so a shared `.env`
  works unmodified). Don't "fix" that by making it optional — it would split
  the env-loading contract between scripts.
