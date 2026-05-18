# manage-cluster

Operational scripts for pausing and resuming the Charity Chest AWS infrastructure
to save cost during planned downtime (nights, weekends, holidays).

The repo contains a matching pair of scripts:

| Script                  | Purpose                                                                |
| ----------------------- | ---------------------------------------------------------------------- |
| `scripts/shutdown.sh`   | Scale every Fargate service in the cluster to 0 and stop the RDS instance. |
| `scripts/startup.sh`    | Start the RDS instance and scale services back up.                     |
| `scripts/status.sh`     | Read-only: print desired/running task counts and RDS status.           |

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

## Scheduling

Shut down nightly at 22:00 and start back up at 07:00 (server local time):

```cron
0 22 * * *   cd /opt/manage-cluster && ASSUME_YES=1 ./scripts/shutdown.sh >> /var/log/manage-cluster.log 2>&1
0  7 * * 1-5 cd /opt/manage-cluster && ASSUME_YES=1 WAIT_FOR_RDS=1 ./scripts/startup.sh  >> /var/log/manage-cluster.log 2>&1
```

For AWS-native scheduling, wrap this in EventBridge Scheduler + a small Lambda
or CodeBuild job that runs the script in a container.
