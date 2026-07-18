# Flink Application Submission Runbook With `oc`

This runbook documents the image-first application-mode path. The goal is to
make the application pod start the job on its own, without `oc exec`, and
without relying on a ConfigMap-mounted JAR.

## Image-First Approach

This is the preferred implementation because the artifact and runtime are
versioned together:

- Build a dedicated application image that already contains the job JAR.
- Use that image for the JobManager/application pod.
- Start the job from the container command with `standalone-job.sh start-foreground`.
- Use pod status, logs, and events for verification.

This path matches
[../../manifests/template-flink-application.yaml](../../manifests/template-flink-application.yaml)
and avoids `oc exec` entirely.

## Assumptions

- You are logged in to the OpenShift cluster with `oc`.
- The application-mode template exists under
  [../../manifests/template-flink-application.yaml](../../manifests/template-flink-application.yaml).
- The application JAR is available locally as a file before image build.
- The job entrypoint is defined by `APPLICATION_MAIN_CLASS` and optional
  `APPLICATION_ARGS`.

## Environment Setup

```bash
source env/flink.dev.env

export OPENSHIFT_NAMESPACE=flink-dev
export FLINK_CLUSTER_ID=flink-dev
export FLINK_APP_SOURCE_FILE=./target/my-app.jar
export FLINK_APP_MAIN_CLASS=com.example.Main
export FLINK_APP_ARGS="--input topicA --output topicB"
export FLINK_APP_PARALLELISM=4
```

## 1. Create or select the namespace

```bash
oc project "${OPENSHIFT_NAMESPACE}"
oc create namespace "${OPENSHIFT_NAMESPACE}" || true
oc project "${OPENSHIFT_NAMESPACE}"
```

## 2. Build and push the application image

The image should include your JAR at the same path used by
`APPLICATION_JAR_URI`.

```bash
podman build \
  --build-arg BASE_RUNTIME_IMAGE=ghcr.io/owner/flink-sql-runtime:2.3.0 \
  --build-arg APP_JAR="${FLINK_APP_SOURCE_FILE}" \
  -t "${APPLICATION_IMAGE_REF}" \
  -f flink-docker/Dockerfile.application \
  .
podman push "${APPLICATION_IMAGE_REF}"
```

If you use `docker`, replace `podman` with `docker`.

## 3. Apply the base Flink identity and RBAC objects

```bash
oc apply -f manifests/00-serviceaccount-rbac.yaml -n "${OPENSHIFT_NAMESPACE}"
```

## 4. Render and apply the application template

```bash
oc process --local -f manifests/template-flink-application.yaml \
  -p OPENSHIFT_NAMESPACE="${OPENSHIFT_NAMESPACE}" \
  -p FLINK_CLUSTER_ID="${FLINK_CLUSTER_ID}" \
  -p SQL_RUNTIME_IMAGE_REF=ghcr.io/owner/flink-sql-runtime:2.3.0 \
  -p APPLICATION_IMAGE_REF="${APPLICATION_IMAGE_REF}" \
  -p APPLICATION_JAR_URI="${APPLICATION_JAR_URI}" \
  -p HA_STORAGE_URI=s3://bucket/ha \
  -p CHECKPOINT_URI=s3://bucket/checkpoints \
  -p SAVEPOINT_URI=s3://bucket/savepoints \
  -p JOBMANAGER_MEMORY=3 \
  -p JOBMANAGER_STORAGE=20 \
  -p TASKMANAGER_REPLICAS=3 \
  -p TASKMANAGER_MEMORY=12 \
  -p TASKMANAGER_STORAGE=100 \
  -p TASKMANAGER_SLOTS=2 \
  -p PARALLELISM_DEFAULT="${FLINK_APP_PARALLELISM}" \
  -p APPLICATION_MAIN_CLASS="${FLINK_APP_MAIN_CLASS}" \
  -p APPLICATION_ARGS="${FLINK_APP_ARGS}" \
  | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -
```

## 5. Wait for the rollout to complete

```bash
oc rollout status statefulset/flink-jobmanager -n "${OPENSHIFT_NAMESPACE}"
oc rollout status statefulset/flink-taskmanager -n "${OPENSHIFT_NAMESPACE}"
```

## 6. Verify the workload through logs and events

```bash
oc get pods -n "${OPENSHIFT_NAMESPACE}" -o wide -l app.kubernetes.io/name=flink
oc get svc -n "${OPENSHIFT_NAMESPACE}"
oc get all -n "${OPENSHIFT_NAMESPACE}" -l app.kubernetes.io/name=flink
oc logs -f -n "${OPENSHIFT_NAMESPACE}" -l app.kubernetes.io/component=jobmanager
oc describe pod -n "${OPENSHIFT_NAMESPACE}" -l app.kubernetes.io/name=flink
oc get events -n "${OPENSHIFT_NAMESPACE}" --sort-by=.lastTimestamp
```

The application pod should start the job automatically because the container
command is already set to `standalone-job.sh start-foreground` in the template. No
interactive exec step is required.

## Session vs Application Mode Findings

These are the concrete differences between the session template and the
application template, focused on the image-based path:

- The session template creates a SQL Gateway `Service`, `Deployment`, and
  `Route`, while the application template removes those objects entirely.
- The session JobManager container starts `jobmanager.sh start-foreground`,
  while the application JobManager starts `standalone-job.sh start-foreground` and points at
  `APPLICATION_JAR_URI`.
- The application template uses a dedicated application image referenced by
  `APPLICATION_IMAGE_REF` instead of mounting the JAR from a ConfigMap.
- The application template replaces the session-specific `ROUTE_HOST`
  parameter with application-specific inputs such as `APPLICATION_MAIN_CLASS`
  and `APPLICATION_ARGS`.
- Both templates keep the same Flink HA and TaskManager scaffolding, so the
  delta is concentrated in the launch path and the artifact delivery path.

## Alternative Artifact Delivery (Future)

If image-based delivery is not possible in a specific environment, consider one
of these alternatives:

1. Fetch the JAR with an initContainer into `emptyDir` or PVC storage.
2. Mount the JAR from object storage with a CSI driver.
