# Namespaces And Service Identities

This guide shows how to create multiple OpenShift namespaces and multiple service identities for a particular namespace using a principal-engineer operating model.

In OpenShift and Kubernetes, the practical meaning of a service identity is usually a `ServiceAccount` plus the `Role` and `RoleBinding` objects that define what it can do.

## Design Principles

Use these principles before creating anything:

1. Separate environments by namespace.
2. Separate duties by service account.
3. Bind the smallest practical set of permissions.
4. Avoid using the `default` service account for real workloads.
5. Prefer namespace-scoped `Role` and `RoleBinding` over cluster-scoped permissions unless there is a hard requirement.

For this Flink SQL platform, the right pattern is usually:

1. One namespace per environment or platform boundary.
2. One runtime identity for Flink pods.
3. One CI or deployer identity for manifest apply and image workflow.
4. One submitter identity for SQL Gateway submission if you want operational separation.
5. One read-only observer identity for diagnostics and support.

## Recommended Namespace Model

Typical environment layout:

- `flink-dev`
- `flink-stage`
- `flink-prod`

Typical shared-platform layout:

- `flink-platform-dev`
- `flink-platform-stage`
- `flink-platform-prod`

Do not mix unrelated production and non-production workloads in one namespace if you want clean RBAC, quota, and audit boundaries.

## Recommended Service Identity Model For One Namespace

For a namespace such as `flink-prod`, create identities like these:

1. `flink-runner`
   Purpose: runtime identity for JobManager, TaskManagers, and SQL Gateway pods.

2. `flink-deployer`
   Purpose: CI/CD identity for applying manifests, config maps, secrets, services, routes, and rollout operations.

3. `flink-sql-submitter`
   Purpose: submission automation identity for talking to the SQL Gateway and reading job status.

4. `flink-observer`
   Purpose: read-only operational visibility for support, diagnostics, and dashboards.

This is a much stronger operational model than making one identity do everything.

Important nuance:

- If `flink-sql-submitter` only calls the SQL Gateway over a Route or internal Service and does not call the Kubernetes or OpenShift API, it may not need cluster RBAC at all.
- If it also needs to inspect pods, services, or rollout state through `oc`, give it a tightly scoped read-only role instead of reusing the deployer identity.

## Quick Command Path

### 1. Create multiple namespaces

```bash
oc new-project flink-dev
oc new-project flink-stage
oc new-project flink-prod
```

Validate:

```bash
oc get ns | grep '^flink-'
```

### 2. Create multiple service accounts in one namespace

```bash
oc create serviceaccount flink-runner -n flink-prod
oc create serviceaccount flink-deployer -n flink-prod
oc create serviceaccount flink-sql-submitter -n flink-prod
oc create serviceaccount flink-observer -n flink-prod
```

Validate:

```bash
oc get sa -n flink-prod
```

### 3. Create namespace-scoped roles

Runtime role:

```bash
oc create role flink-runner \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=configmaps \
  -n flink-prod

oc create role flink-runner-discovery \
  --verb=get,list,watch \
  --resource=pods,services,endpoints \
  -n flink-prod

oc create role flink-runner-events \
  --verb=create,patch \
  --resource=events \
  -n flink-prod
```

Deployer role:

```bash
oc create role flink-deployer \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=configmaps,secrets,services,routes,persistentvolumeclaims,serviceaccounts \
  -n flink-prod

oc create role flink-deployer-workloads \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=deployments,statefulsets \
  -n flink-prod
```

Observer role:

```bash
oc create role flink-observer \
  --verb=get,list,watch \
  --resource=pods,services,endpoints,events,configmaps \
  -n flink-prod
```

Optional submitter role:

```bash
oc create role flink-sql-submitter \
  --verb=get,list,watch \
  --resource=pods,services,endpoints,events \
  -n flink-prod
```

### 4. Bind the roles to the service accounts

```bash
oc adm policy add-role-to-user flink-runner -z flink-runner -n flink-prod
oc adm policy add-role-to-user flink-runner-discovery -z flink-runner -n flink-prod
oc adm policy add-role-to-user flink-runner-events -z flink-runner -n flink-prod

oc adm policy add-role-to-user flink-deployer -z flink-deployer -n flink-prod
oc adm policy add-role-to-user flink-deployer-workloads -z flink-deployer -n flink-prod

oc adm policy add-role-to-user flink-sql-submitter -z flink-sql-submitter -n flink-prod

oc adm policy add-role-to-user flink-observer -z flink-observer -n flink-prod
```

Validate:

```bash
oc get rolebinding -n flink-prod
```

## Recommended Declarative Path

For real platform operations, prefer declarative manifests in Git over ad hoc command creation.

Below is a production-oriented example for a single namespace with multiple service identities.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: flink-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink-runner
  namespace: flink-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink-deployer
  namespace: flink-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink-sql-submitter
  namespace: flink-prod
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink-observer
  namespace: flink-prod
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: flink-runner
  namespace: flink-prod
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flink-runner
  namespace: flink-prod
subjects:
  - kind: ServiceAccount
    name: flink-runner
    namespace: flink-prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: flink-runner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: flink-deployer
  namespace: flink-prod
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets", "services", "serviceaccounts", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flink-deployer
  namespace: flink-prod
subjects:
  - kind: ServiceAccount
    name: flink-deployer
    namespace: flink-prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: flink-deployer
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: flink-sql-submitter
  namespace: flink-prod
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints", "events"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flink-sql-submitter
  namespace: flink-prod
subjects:
  - kind: ServiceAccount
    name: flink-sql-submitter
    namespace: flink-prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: flink-sql-submitter
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: flink-observer
  namespace: flink-prod
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints", "events", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flink-observer
  namespace: flink-prod
subjects:
  - kind: ServiceAccount
    name: flink-observer
    namespace: flink-prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: flink-observer
```

Apply it with:

```bash
oc apply -f namespace-and-identities.yaml
```

## Multiple Namespaces In One File

If you want to create dev, stage, and prod together, use a file like this:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: flink-dev
---
apiVersion: v1
kind: Namespace
metadata:
  name: flink-stage
---
apiVersion: v1
kind: Namespace
metadata:
  name: flink-prod
```

Then apply environment-specific service identities per namespace rather than reusing one global identity pattern blindly.

## Ready-To-Apply Manifest In This Repository

Use these files for concrete namespace + multi-identity + governance baselines:

- `manifests/07-namespace-identities-governance-example.yaml` for `flink-prod`
- `manifests/08-namespace-identities-governance-dev-example.yaml` for `flink-dev`
- `manifests/09-namespace-identities-governance-stage-example.yaml` for `flink-stage`
- `manifests/10-namespace-identities-governance-all-environments-example.yaml` for `flink-dev` + `flink-stage` + `flink-prod` in one apply

Apply one or more:

```bash
oc apply -f docs/flink/openshift/manifests/07-namespace-identities-governance-example.yaml
oc apply -f docs/flink/openshift/manifests/08-namespace-identities-governance-dev-example.yaml
oc apply -f docs/flink/openshift/manifests/09-namespace-identities-governance-stage-example.yaml
```

Apply all three environments in one operation:

```bash
oc apply -f docs/flink/openshift/manifests/10-namespace-identities-governance-all-environments-example.yaml
```

Each manifest keeps the same identity model but uses environment-specific namespace names and lighter quotas outside prod.

Sizing intent:

1. `flink-dev`: smallest quota and limits for developer iteration.
2. `flink-stage`: medium quota and limits for pre-production integration and soak testing.
3. `flink-prod`: largest quota and limits for production workloads.

If your namespace names differ, copy the file and adjust namespace metadata and all `namespace:` fields before apply.

The umbrella manifest intentionally reuses the existing per-environment definitions as building blocks. Keep the per-env files as the primary editable sources, and regenerate the umbrella file after changes.

Regenerate manually:

```bash
docs/flink/openshift/scripts/regenerate-namespace-identities-umbrella.sh
```

Validate in CI without modifying files:

```bash
docs/flink/openshift/scripts/regenerate-namespace-identities-umbrella.sh --check
```

Emit a live validation snapshot on demand:

```bash
docs/flink/openshift/scripts/validate-namespace-identities.sh
```

Emit JSON for CI parsing:

```bash
docs/flink/openshift/scripts/validate-namespace-identities.sh --json
```

Validate specific namespaces only:

```bash
docs/flink/openshift/scripts/validate-namespace-identities.sh flink-stage flink-prod
```

Validate specific namespaces with JSON output:

```bash
docs/flink/openshift/scripts/validate-namespace-identities.sh --json flink-stage flink-prod
```

## CI Separation Example: Deployer Vs SQL Submitter

The principal-engineer pattern is two separate automation identities and two separate credentials.

Why:

- `flink-deployer` should own infrastructure changes.
- `flink-sql-submitter` should own SQL submission only.
- Compromise or misuse of one identity should not automatically grant the capabilities of the other.

### CI stage model

1. `deploy-infra` stage
  Runs with `flink-deployer` token.
  Applies manifests, config, secrets, routes, and rollout checks.

2. `submit-sql` stage
  Runs with `flink-sql-submitter` token.
  Calls SQL Gateway API and reads job status.

### Example (generic shell CI)

```bash
# Stage: deploy-infra
export KUBECONFIG=/tmp/kubeconfig-deployer
oc login --token="${FLINK_DEPLOYER_TOKEN}" --server="${OPENSHIFT_API_URL}"
oc project flink-prod

oc apply -f docs/flink/openshift/manifests/00-serviceaccount-rbac.yaml
oc apply -f docs/flink/openshift/manifests/01-configmap.yaml
oc apply -f docs/flink/openshift/manifests/03-jobmanager.yaml
oc apply -f docs/flink/openshift/manifests/04-taskmanager.yaml
oc apply -f docs/flink/openshift/manifests/05-sql-gateway.yaml
oc apply -f docs/flink/openshift/manifests/06-route.yaml

oc rollout status statefulset/flink-jobmanager -n flink-prod --timeout=10m
oc rollout status statefulset/flink-taskmanager -n flink-prod --timeout=10m
oc rollout status deployment/flink-sql-gateway -n flink-prod --timeout=10m
```

```bash
# Stage: submit-sql
export KUBECONFIG=/tmp/kubeconfig-submitter
oc login --token="${FLINK_SQL_SUBMITTER_TOKEN}" --server="${OPENSHIFT_API_URL}"
oc project flink-prod

# Example: submit through SQL Gateway route
SQL_GATEWAY_BASE_URL="https://flink-sql-gateway-flink-prod.apps.example.com"
docs/flink/openshift/scripts/submit-sql.sh docs/flink/openshift/env/prod.env
```

Pipeline hardening notes:

1. Do not reuse one token for both stages.
2. Scope stage secrets to the minimum job that needs them.
3. Rotate tokens and prefer short-lived credentials where your platform supports it.

## Namespace Resource Governance (Quota + LimitRange)

RBAC alone does not prevent noisy-neighbor behavior or accidental overconsumption.

Use these together:

1. `ResourceQuota`:
  sets namespace-wide hard ceilings.

2. `LimitRange`:
  sets default requests/limits and per-object bounds.

The ready-to-apply example manifest in this repository includes both.

### Governance validation

```bash
oc describe resourcequota flink-prod-quota -n flink-prod
oc describe limitrange flink-prod-defaults -n flink-prod
```

What to validate:

1. Quota tracks `Used` versus `Hard` for CPU, memory, PVCs, and object counts.
2. LimitRange defaults are being injected for workloads that do not set requests/limits.
3. Maximum and minimum values match your capacity plan for the namespace.

## Token And Access Guidance

If an automation system needs a token for a service account, prefer short-lived tokens when possible:

```bash
oc create token flink-deployer -n flink-prod
oc create token flink-observer -n flink-prod
```

Why this is preferred:

- Short-lived tokens reduce credential sprawl.
- They are better aligned with modern cluster security practice than assuming static long-lived service-account secrets.

## Validation Checklist

After creation, validate all of the following:

### 1. Namespace existence

```bash
oc get ns | grep '^flink-'
```

### 2. Service accounts exist in the target namespace

```bash
oc get sa -n flink-prod
```

### 3. Role bindings exist and map to the intended identities

```bash
oc get rolebinding -n flink-prod
oc describe rolebinding flink-runner -n flink-prod
oc describe rolebinding flink-deployer -n flink-prod
oc describe rolebinding flink-observer -n flink-prod
```

### 4. Effective permissions are correct

Examples:

```bash
oc auth can-i get pods --as=system:serviceaccount:flink-prod:flink-observer -n flink-prod
oc auth can-i create deployments.apps --as=system:serviceaccount:flink-prod:flink-observer -n flink-prod
oc auth can-i create deployments.apps --as=system:serviceaccount:flink-prod:flink-deployer -n flink-prod
oc auth can-i create events --as=system:serviceaccount:flink-prod:flink-runner -n flink-prod
oc auth can-i get pods --as=system:serviceaccount:flink-prod:flink-sql-submitter -n flink-prod
```

What good looks like:

- Observer can read but not deploy.
- Deployer can apply workloads and supporting objects.
- Runner can perform runtime discovery and required HA interactions.
- Submitter can inspect what it is allowed to see without becoming a deployer.

## Verification Snapshot (Dev And Stage)

Validation timestamp (UTC): `2026-07-03T10:39:25Z`

### flink-dev

- Namespace status: `Active`
- Service accounts present: `flink-deployer`, `flink-observer`, `flink-runner`, `flink-sql-submitter`
- RoleBindings present: `flink-deployer`, `flink-observer`, `flink-runner`, `flink-sql-submitter`
- RBAC checks:
  - `flink-deployer` create deployments: `yes` (`rc=0`)
  - `flink-observer` create deployments: `no` (`rc=1`, expected deny)
  - `flink-sql-submitter` get pods: `yes` (`rc=0`)

### flink-stage

- Namespace status: `Active`
- Service accounts present: `flink-deployer`, `flink-observer`, `flink-runner`, `flink-sql-submitter`
- RoleBindings present: `flink-deployer`, `flink-observer`, `flink-runner`, `flink-sql-submitter`
- RBAC checks:
  - `flink-deployer` create deployments: `yes` (`rc=0`)
  - `flink-observer` create deployments: `no` (`rc=1`, expected deny)
  - `flink-sql-submitter` get pods: `yes` (`rc=0`)

These snapshots confirm identity separation and least-privilege behavior are consistent in both non-prod environments.

For current-state verification at any time, prefer running `scripts/validate-namespace-identities.sh` instead of manually reconstructing the checks.

## What I Would Standardize For This Repository

For the Flink bundle in this repository, I would standardize:

1. `flink-runner` as the pod runtime identity.
2. `flink-deployer` as the CI/CD identity.
3. `flink-observer` as the read-only operational identity.
4. One namespace per environment.
5. No use of the `default` service account for Flink workloads.
6. ResourceQuota and LimitRange in every environment namespace.

That keeps the existing bundle simple while making the surrounding platform model production-worthy.

## What I Would Avoid

1. Reusing one service account for runtime, deployment, and observation.
2. Granting `edit` or `admin` broadly when a focused `Role` is enough.
3. Creating cluster-scoped bindings for namespace-local workloads.
4. Hand-managing static long-lived tokens unless there is no better integration path.
5. Letting namespace design drift from environment boundaries.

That is how namespace and identity sprawl turns into an operations and audit problem.