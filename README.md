# manage-cluster

Operational scripts for pausing and resuming the Charity Chest AWS infrastructure
to save cost during planned downtime (nights, weekends, holidays).

The repo contains a matching pair of scripts:

| Script                          | Purpose                                                                |
| ------------------------------- | ---------------------------------------------------------------------- |
| `scripts/shutdown.sh`           | Scale every Fargate service in the cluster to 0 and stop the RDS instance. |
| `scripts/startup.sh`            | Start the RDS instance and scale services back up.                     |
| `scripts/status.sh`             | Read-only: print desired/running task counts and RDS status.           |
| `scripts/apply-dns-records.sh`  | Apply a set of upsert/alias/delete changes to a Route 53 hosted zone from a plain-text records file. |
| `scripts/manage-albs.sh`        | Create or delete a set of Application Load Balancers from an INI-style config; on create, emits a DNS records template ready for `apply-dns-records.sh` and a service-LB template ready for `update-service-alb.sh`. |
| `scripts/update-service-alb.sh` | Replace, clear, append, or detach one specific target group from the `loadBalancers` association on a set of ECS Fargate services, from an INI-style config. |
| `scripts/apply-listeners.sh`    | Create or update ALB listeners (HTTP/HTTPS; forward / redirect / fixed-response default actions) from an INI-style config. |
| `scripts/setup.sh`              | One-shot wrapper that runs the LB-layer setup in order (provision ALBs → listeners → wire services → DNS). |
| `scripts/teardown.sh`           | One-shot wrapper that runs the LB-layer teardown in order (DNS delete → detach services → delete ALBs) with a drain wait between steps. |

The pair is intentionally stateless: `shutdown.sh` does not record previous
desired counts and `startup.sh` does not read any persisted state. Target
counts for resumption come from env vars (`DESIRED_COUNT`, `ECS_DESIRED_COUNTS`).

## Requirements

- `bash` 4+ and the AWS CLI v2 on `PATH`
- AWS credentials with the IAM permissions listed [below](#iam-permissions)
- An ECS cluster running Fargate services and an RDS Postgres instance in the
  same account/region

## Configuration

The script reads its configuration from environment variables, or from a
`scripts/.env` file sourced automatically at startup.

| Variable          | Required | Description                                                                 |
| ----------------- | -------- | --------------------------------------------------------------------------- |
| `AWS_REGION`      | yes      | Region hosting the ECS cluster and RDS instance (e.g. `eu-west-1`)          |
| `ECS_CLUSTER`     | yes      | ECS cluster name                                                            |
| `RDS_INSTANCE_ID` | yes      | RDS DB instance identifier                                                  |
| `ECS_SERVICES`    | no       | Space-separated service names to scale. When unset, every service in the cluster is scaled to 0 |
| `AWS_PROFILE`     | no       | Passed through to the AWS CLI for named-profile auth                        |
| `ASSUME_YES`      | no       | Set to `1` to skip the interactive confirmation prompt (use in cron)        |

Variables consumed only by `apply-dns-records.sh`:

| Variable          | Description                                                                 |
| ----------------- | --------------------------------------------------------------------------- |
| `HOSTED_ZONE_ID`  | Route 53 hosted zone identifier (e.g. `Z3ABCXYZ`)                            |
| `WAIT_FOR_SYNC`   | Set to `1` to block until the change reaches `INSYNC` (usually under a minute) |

Additional variables consumed only by `startup.sh`:

| Variable             | Description                                                                 |
| -------------------- | --------------------------------------------------------------------------- |
| `DESIRED_COUNT`      | Fallback target task count for services with no override (default `1`)      |
| `ECS_DESIRED_COUNTS` | Space-separated `name=count` overrides, e.g. `"server=2 webapp=1"`          |
| `WAIT_FOR_RDS`       | Set to `1` to block until RDS reports `available` before scaling up         |

Example `scripts/.env`:

```dotenv
AWS_REGION=eu-west-1
ECS_CLUSTER=charity-chest-staging
RDS_INSTANCE_ID=charity-chest-staging-db
# ECS_SERVICES="charity-chest-server charity-chest-webapp"
```

## Usage

Shutdown (interactive):

```sh
./scripts/shutdown.sh
```

Shutdown (unattended, e.g. cron / scheduled CI job):

```sh
ASSUME_YES=1 ./scripts/shutdown.sh
```

Startup (interactive, default 1 task per service):

```sh
./scripts/startup.sh
```

Startup with per-service counts and a synchronous RDS wait:

```sh
ECS_DESIRED_COUNTS="charity-chest-server=2 charity-chest-webapp=1" \
WAIT_FOR_RDS=1 \
ASSUME_YES=1 \
  ./scripts/startup.sh
```

Status (read-only):

```sh
./scripts/status.sh
```

Sample output:

```
ECS cluster: charity-chest-staging  (region: eu-west-1)
  SERVICE                                   DESIRED  RUNNING  PENDING     STATUS
  charity-chest-server                            2        2        0     ACTIVE
  charity-chest-webapp                            1        1        0     ACTIVE

RDS instance: charity-chest-staging-db
  status:   available
  engine:   postgres 16.4
  endpoint: charity-chest-staging-db.xxxx.eu-west-1.rds.amazonaws.com:5432
```

Apply DNS record changes from a records file:

```sh
HOSTED_ZONE_ID=Z3ABCXYZ ./scripts/apply-dns-records.sh ./records.txt
```

The records file is plain text — one record per non-comment line, columns
`ACTION TYPE NAME TTL VALUE[|VALUE...]`. Multi-value record sets use `|` as
the separator; TXT values include their surrounding quotes:

```text
# api swap
upsert  A      api.example.com.       300  192.0.2.1
upsert  A      multi.example.com.     300  192.0.2.1|192.0.2.2
upsert  CNAME  www.example.com.       300  example.com.
upsert  TXT    _acme.example.com.     300  "verification-token"
delete  A      old.example.com.
delete  CNAME  legacy.example.com.
```

To point a record at an **AWS resource** (ALB, NLB, CloudFront, …), use an
alias record. Alias rows have a different column layout — no TTL, no value
list, instead the target's DNS name and its canonical hosted zone ID:

```text
# Columns: alias  TYPE  NAME  TARGET_ZONE_ID  TARGET_DNS_NAME  [EVAL_HEALTH]
alias  A  api.example.com.  Z32O12XQLNTSW2  dualstack.my-alb-1234.eu-west-1.elb.amazonaws.com.
alias  A  www.example.com.  Z2FDTNDATAQYW2  d111111abcdef8.cloudfront.net.                       true
```

`TARGET_ZONE_ID` is the **AWS-managed** hosted zone of the target resource,
not your own `HOSTED_ZONE_ID`. To look up an ALB or NLB's values:

```sh
aws elbv2 describe-load-balancers --names <lb-name> \
  --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text
```

CloudFront distributions always use zone ID `Z2FDTNDATAQYW2`. For an ALB
serving IPv4 + IPv6 clients, prefix the DNS name with `dualstack.`.
`EVAL_HEALTH` defaults to `false`.

`alias` is implicitly UPSERT — there is no separate create variant. To
remove an alias record use `delete` (it reads the current `AliasTarget` from
the zone and inlines it, just like for any other record type).

`upsert` is always safe to re-run (Route 53 replaces in place). `delete` is
pre-checked against the current zone state and skipped when the record is
already absent, so the script is idempotent end-to-end. Pass `WAIT_FOR_SYNC=1`
to block until the change reaches `INSYNC`.

## Managing ALBs

`manage-albs.sh` creates or deletes a set of Application Load Balancers from
an INI-style config file. On create, it also writes a DNS records template
(pre-filled with each new ALB's DNSName and CanonicalHostedZoneId) so the
DNS step can be done in one go with `apply-dns-records.sh`.

Config file format — one `[name]` section per ALB:

```ini
[charity-chest-prod-alb]
scheme=internet-facing
ip_address_type=dualstack
subnets=subnet-aaa,subnet-bbb
security_groups=sg-xxx
dns_names=api.charitychest.com.,www.charitychest.com.
tags=Env=prod,App=charity-chest

[charity-chest-stg-alb]
scheme=internal
ip_address_type=ipv4
subnets=subnet-ccc,subnet-ddd
security_groups=sg-yyy
```

Required keys: `scheme` (`internet-facing` | `internal`), `ip_address_type`
(`ipv4` | `dualstack`), `subnets`, `security_groups`. Optional: `dns_names`
(comma-separated FQDNs used only for the records template), `tags`
(comma-separated `Key=Value` pairs).

Optionally, declare ECS service → target group associations alongside each
ALB to have `manage-albs.sh` also emit a service-LB template:

```ini
[charity-chest-prod-alb]
scheme=internet-facing
ip_address_type=dualstack
subnets=subnet-aaa,subnet-bbb
security_groups=sg-xxx
dns_names=api.charitychest.com.

ecs_service.charity-chest-server.cluster=charity-chest-prod
ecs_service.charity-chest-server.container_name=server
ecs_service.charity-chest-server.container_port=8080
ecs_service.charity-chest-server.target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/server-tg/abc
```

`target_group_arn` must reference an existing target group (created out of
band — Terraform or the deploy workflow in `../charity-chest`).

Create the ALBs and write both templates to files:

```sh
./scripts/manage-albs.sh create ./albs.conf ./alb-records.txt ./service-lbs.conf
```

Then apply each in turn:

```sh
HOSTED_ZONE_ID=Z3ABCXYZ ./scripts/apply-dns-records.sh ./alb-records.txt
./scripts/update-service-alb.sh ./service-lbs.conf
```

Either output path can be omitted (the template prints to stdout instead).
When an output path *is* provided, `manage-albs.sh` always writes the
template's header to that path — even when no ALB declares `dns_names` (or
no `ecs_service.*` block), in which case the file ends up header-only with
no record/section lines. This is deliberate: `setup.sh` detects a
header-only service-LB file (no `[section]` headers) and auto-skips the
service-wiring step rather than feeding `update-service-alb.sh` an empty
config.

### Deleting ALBs

Pass the same config file used for creation; `manage-albs.sh delete` reads
only the section *names* and ignores the rest of each section's keys.
That means the file is reusable as-is, and you can also feed it a
subset config that contains only the ALBs you want to remove:

```sh
# delete every ALB declared in the config
./scripts/manage-albs.sh delete ./scripts/config/albs.conf

# delete just one or two — same script, smaller config file
./scripts/manage-albs.sh delete ./scripts/config/decommission.conf
```

A minimal "delete only" config — just the section headers — is enough:

```ini
[charity-chest-stg-alb]

[old-experimental-alb]
```

What happens on delete:
- The ALB resource is removed via `elbv2 delete-load-balancer`.
- **Listeners cascade** with the ALB (AWS-side) — you don't need to
  delete them first.
- **Target groups survive** — they're independent resources and not
  managed by this repo. The deploy workflow in `../charity-chest` (or
  Terraform) owns them.
- **DNS records survive** — alias records that pointed at the deleted
  ALB are not removed by this script. Run `apply-dns-records.sh` with
  matching `delete` rows beforehand (or use [`teardown.sh`](#teardown--full-removal-of-the-lb-layer)
  for the full sequence).
- **ECS services survive** — but any `loadBalancers` entry on a service
  that referenced one of this ALB's target groups will be pointing at a
  TG whose listeners no longer exist. Detach the service first via
  `update-service-alb.sh` to avoid traffic going to a dead listener.

`delete` is idempotent: ALBs not found in the account are silently
skipped, so it's safe to re-run after a partial failure.

**Removal order matters** if you want zero broken state. The minimum is:

1. detach the affected ECS services (`update-service-alb.sh` with
   `clear=true` or `remove_target_group_arn`),
2. delete the DNS records that point at the ALB (`apply-dns-records.sh`),
3. then run `manage-albs.sh delete`.

For the full sequence in one command, use
[`teardown.sh`](#teardown--full-removal-of-the-lb-layer).

Both subcommands are idempotent. `create` skips ALBs that already exist
by name (and still includes their current DNS info in the records output,
so re-running yields a complete file). `delete` skips ALBs that aren't
present. Pass `WAIT_FOR_ACTIVE=1` (create only) to block until each new
ALB reaches state `active` (typically 2–5 minutes per ALB).

**Out of scope**: listeners, target groups, and listener rules. This script
manages only the ALB shell — target groups must already exist when their
ARNs appear in the config.

## Wiring ECS services to a load balancer

`update-service-alb.sh` calls `aws ecs update-service --load-balancers` to
replace, clear, append, or surgically detach one target group from each ECS
Fargate service listed in its config. ECS automatically rolls out a new
deployment when the LB config changes.

```ini
# Replace the existing LB config (or add one, if there is none).
[charity-chest-server]
cluster=charity-chest-prod
target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/server-tg/abc
container_name=server
container_port=8080

# Remove all LB associations from this service.
[charity-chest-webapp]
cluster=charity-chest-prod
clear=true

# Append a new target group, KEEPING all existing loadBalancers entries.
# Useful for adding a second ALB (or a second listener pointing at a
# different target group) without disturbing the current ones.
[charity-chest-extend]
cluster=charity-chest-prod
add_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/new-tg/uvw
container_name=server
container_port=8080

# Detach ONE target group by ARN, leaving any other loadBalancers entries
# on the service untouched. Useful when a service is attached to multiple
# target groups and only one of them needs to go.
[charity-chest-multi]
cluster=charity-chest-prod
remove_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/old-tg/xyz
```

Each section must set exactly one mode key:
- `target_group_arn` (+ `container_name` / `container_port`) — replace the whole array.
- `clear=true` — empty the array.
- `add_target_group_arn` (+ `container_name` / `container_port`) — append, keeping existing entries.
- `remove_target_group_arn` — surgically detach one specific target group.

Apply:

```sh
./scripts/update-service-alb.sh ./service-lbs.conf
```

Idempotent across all four modes:
- `replace` skips the call when the existing entry already matches.
- `clear` skips when `loadBalancers` is already empty.
- `add_target_group_arn` skips when the named ARN is already attached.
- `remove_target_group_arn` skips when the named ARN is not currently
  attached.

The service must be in a stable state (no in-progress deployment) and on
Fargate platform version 1.4.0+ (the default since 2020). Pass
`FORCE_NEW_DEPLOYMENT=1` to add `--force-new-deployment` to every call —
not normally needed since LB changes already trigger a deployment.

See [Setup and teardown sequences](#setup-and-teardown-sequences) for the
end-to-end pipeline.

## Creating ALB listeners

`apply-listeners.sh` creates or updates ALB listeners from an INI config.
Scope is the tier-2 listener subset (HTTP/HTTPS only; a single default
action of `forward` / `redirect` / `fixed-response`) — listener rules with
conditions, OIDC/Cognito auth, mTLS, weighted forwards, and multi-cert SNI
are intentionally out of scope. Use Terraform for those.

### How a listener "reaches" the ECS service

There is no separate "attach listener to service" step. The wiring is the
**shared target group ARN**:

```text
   listener (alb:port)
      │
      │ default forward ──► target group ARN ◄── update-service-alb.sh
      │                          │
      │                          ▼
      │                       ECS Fargate service
```

Put the same target-group ARN in both:
- `default_target_group_arn` of the `forward` listener in `listeners.conf`,
- `target_group_arn` of the corresponding `[service]` section in `service-lbs.conf`.

Then both `apply-listeners.sh` and `update-service-alb.sh` converge on that
target group — traffic flows from the listener through the TG into the
service. If you generated `service-lbs.conf` from `manage-albs.sh`, the
ARN is already there; use the same value in `listeners.conf`.

### Config

```ini
# HTTPS forward to a target group.
[prod-https]
alb_name=charity-chest-prod-alb
port=443
protocol=HTTPS
certificate_arn=arn:aws:acm:eu-west-1:123:certificate/abc
ssl_policy=ELBSecurityPolicy-TLS13-1-2-2021-06        # optional
default_action_type=forward
default_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/server-tg/xxx

# Plain HTTP listener that redirects to HTTPS.
[prod-http-redirect]
alb_name=charity-chest-prod-alb
port=80
protocol=HTTP
default_action_type=redirect
redirect_protocol=HTTPS
redirect_port=443
redirect_status_code=HTTP_301
# optional: redirect_host, redirect_path, redirect_query
# (default to AWS pass-through #{host}, /#{path}, #{query})

# Static fixed-response (no forward), useful for maintenance pages.
[stg-503-fallback]
alb_name=charity-chest-stg-alb
port=80
protocol=HTTP
default_action_type=fixed-response
fixed_status_code=503
fixed_content_type=text/plain                          # optional, default text/plain
fixed_body=down for maintenance                        # optional
```

Section names are freeform (used only for logging). Listener identity on
AWS is the `(alb_name, port)` tuple.

Apply:

```sh
./scripts/apply-listeners.sh ./listeners.conf
```

Idempotent: the script reads each listener's current state (protocol, cert
ARN, SSL policy, default-action fields) via JMESPath text projection and
string-compares to the desired state. If everything matches, the
modify-listener call is skipped; otherwise the listener is either created
or modified in place. The listener identity on AWS is `(alb, port)`, so
the script will not duplicate listeners on re-run.

Override the env file location by exporting the variables in the shell instead:

```sh
AWS_REGION=eu-west-1 \
ECS_CLUSTER=charity-chest-staging \
RDS_INSTANCE_ID=charity-chest-staging-db \
ASSUME_YES=1 \
  ./scripts/shutdown.sh
```

Both scripts are idempotent. `shutdown.sh` skips services already at
`desiredCount=0` and an RDS instance not in `available`. `startup.sh` skips
services already at the target count and an RDS instance already
`available`/`starting`.

## Setup and teardown sequences

Two end-to-end pipelines. Config files live under `scripts/config/` by
convention.

### Setup — cold start, full pipeline

Either run the four steps by hand:

```sh
# 1. Provision ALBs; emit DNS + service-LB templates.
./scripts/manage-albs.sh create \
    ./scripts/config/albs.conf \
    ./scripts/config/dns-records.txt \
    ./scripts/config/service-lbs.conf

# 2. Create listeners on each ALB (HTTPS forward, HTTP->HTTPS redirect, ...).
./scripts/apply-listeners.sh ./scripts/config/listeners.conf

# 3. Wire ECS services to their target groups (triggers a deployment).
./scripts/update-service-alb.sh ./scripts/config/service-lbs.conf

# 4. Apply DNS records — alias A/AAAA pointing at the new ALBs.
HOSTED_ZONE_ID=Z3ABCXYZ \
    ./scripts/apply-dns-records.sh ./scripts/config/dns-records.txt

# 5. (Optional) bring ECS services online if they were paused.
ASSUME_YES=1 WAIT_FOR_RDS=1 ./scripts/startup.sh
```

…or use the wrapper that does all four in order:

```sh
HOSTED_ZONE_ID=Z3ABCXYZ \
    ./scripts/setup.sh \
        ./scripts/config/albs.conf \
        ./scripts/config/dns-records.txt \
        ./scripts/config/service-lbs.conf \
        ./scripts/config/listeners.conf
```

The four positional args are, in order: ALBs config (input), DNS records
output, service-LB output, listeners config (input). The DNS and
service-LB files are produced by step 1 and consumed by steps 3 and 4 —
the wrapper threads them through. `setup.sh` confirms once up front and
suppresses the per-script prompts via `ASSUME_YES=1`. Set
`WAIT_FOR_ACTIVE=1` to make step 1 block until each new ALB reaches
state `active` (2–5 min per ALB).

If `albs.conf` doesn't declare any `ecs_service.*` blocks, the emitted
service-LB file is header-only and the wrapper automatically **skips**
step 3 (since `update-service-alb.sh` errors on a config with zero
sections).

Order rationale: the ALB must exist before listeners can attach (step 1
before 2). Services need their target group wired before the listener has
healthy targets (step 3 before any user traffic). DNS goes last so
external clients don't reach a half-built ALB.

### Teardown — full removal of the LB layer

Either run the three steps by hand:

```sh
# 1. Delete DNS records pointing at the ALBs (stop new client traffic).
HOSTED_ZONE_ID=Z3ABCXYZ \
    ./scripts/apply-dns-records.sh ./scripts/config/dns-records-delete.txt

# 2. Detach ECS services from their target groups. ECS rolls a new
#    deployment; the LB drains existing connections via its
#    deregistration delay (~30s default).
./scripts/update-service-alb.sh ./scripts/config/remove-albs-from-services.conf

# 3. Delete the ALBs. Listeners attached to each ALB are removed as part
#    of the cascade; target groups survive (they're independent resources
#    and aren't managed by this repo).
./scripts/manage-albs.sh delete ./scripts/config/albs.conf
```

…or use the wrapper that does all three with a drain wait between
steps 2 and 3:

```sh
HOSTED_ZONE_ID=Z3ABCXYZ \
    ./scripts/teardown.sh \
        ./scripts/config/dns-records-delete.txt \
        ./scripts/config/remove-albs-from-services.conf \
        ./scripts/config/albs.conf
```

The wrapper takes three positional args (DNS file, services file, ALBs
file) in the same order as the manual steps. It confirms once up front
and then suppresses the per-script prompts via `ASSUME_YES=1` (set
`ASSUME_YES=1` in the parent env to skip the wrapper's confirm too).
`DRAIN_SECONDS` (default 30) controls the wait between detaching services
and deleting the ALBs — set to 0 to skip if you've already verified the
LB has drained.

Each child script is idempotent, so the wrapper is safe to re-run after
a mid-teardown failure: completed steps silently skip, and execution
continues from where it stopped.

### Supporting config files for teardown

**`dns-records-delete.txt`** — `delete` rows for the records you want gone.
`apply-dns-records.sh` pre-checks deletes against current zone state and
skips ones that are already absent, so this is safe to re-run.

```text
delete  A     api.charitychest.com.
delete  AAAA  api.charitychest.com.
delete  A     www.charitychest.com.
delete  AAAA  www.charitychest.com.
```

**`remove-albs-from-services.conf`** — one `[service]` section per service.
Two flavours depending on intent:

```ini
# Option A: drop ALL LB associations from each service.
[charity-chest-server]
cluster=charity-chest-prod
clear=true

[charity-chest-webapp]
cluster=charity-chest-prod
clear=true

# Option B: detach a SPECIFIC target group only (use when a service has
# multiple LB associations and only one needs to go).
[charity-chest-multi]
cluster=charity-chest-prod
remove_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/old-tg/xyz
```

### Pause vs. teardown — don't confuse them

- `shutdown.sh` / `startup.sh` — **pause/resume.** Scale ECS to 0 and stop
  RDS to save cost during planned downtime. ALB, listeners, and DNS stay in
  place. Use for nightly off-hours.
- The teardown above — **remove the ALB layer entirely.** ECS services and
  RDS persist, but external traffic has no entry point until you re-run
  the setup sequence. Use when actually decommissioning or migrating.

If you want a one-command "go away for a week," that's `shutdown.sh`.
If you want "rip the LB layer out," that's the teardown sequence above.

## What happens during shutdown

1. **ECS services** — the script enumerates services via `aws ecs list-services`
   (or uses the explicit `ECS_SERVICES` list) and issues
   `aws ecs update-service --desired-count 0` for each. Running tasks drain and
   exit; the service definition is preserved, so scaling back up restores the
   previous task definition.
2. **RDS instance** — when status is `available`, `aws rds stop-db-instance`
   is issued. Storage, snapshots, parameter groups, and security groups are all
   preserved; only compute is paused.

## Important: 7-day RDS auto-start

> AWS automatically starts a stopped RDS instance after **7 days**, regardless
> of whether you want it stopped. To keep an instance stopped for longer,
> re-run this script on a schedule (every 5–6 days is safe).

This is a hard AWS limit, not a bug in the script.

## IAM permissions

The script's credentials need at minimum:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecs:ListServices",
        "ecs:DescribeServices",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "rds:StopDBInstance",
        "rds:StartDBInstance"
      ],
      "Resource": "*"
    }
  ]
}
```

Scope the `Resource` ARNs down to the specific cluster/services/instance in
production.

`apply-dns-records.sh` additionally needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:GetHostedZone",
        "route53:ListResourceRecordSets",
        "route53:ChangeResourceRecordSets",
        "route53:GetChange"
      ],
      "Resource": "*"
    }
  ]
}
```

Scope the `Resource` to the specific hosted zone ARN
(`arn:aws:route53:::hostedzone/<id>`) in production.

`manage-albs.sh` additionally needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:AddTags"
      ],
      "Resource": "*"
    }
  ]
}
```

`CreateLoadBalancer` requires `Resource: "*"` because the ARN doesn't exist
yet at call time.

`update-service-alb.sh` uses the existing `ecs:DescribeServices` and
`ecs:UpdateService` permissions from the shutdown/startup block above —
no additional IAM is required.

`apply-listeners.sh` additionally needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:ModifyListener"
      ],
      "Resource": "*"
    }
  ]
}
```

If `default_action_type=forward` references a target group ARN whose
listener-attachment is governed by a policy condition, also grant
`elasticloadbalancing:RegisterTargets` on that target group.

## Scheduling

Shut down nightly at 22:00 and start back up at 07:00 (server local time):

```cron
0 22 * * *   cd /opt/manage-cluster && ASSUME_YES=1 ./scripts/shutdown.sh >> /var/log/manage-cluster.log 2>&1
0  7 * * 1-5 cd /opt/manage-cluster && ASSUME_YES=1 WAIT_FOR_RDS=1 ./scripts/startup.sh  >> /var/log/manage-cluster.log 2>&1
```

For AWS-native scheduling, wrap this in EventBridge Scheduler + a small Lambda
or CodeBuild job that runs the script in a container.
