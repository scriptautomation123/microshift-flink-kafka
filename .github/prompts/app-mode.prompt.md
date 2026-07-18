# Prompt: Implement Flink Application Mode Alongside Existing Session SQL Mode

You are a principal engineer working in this repository. Implement Flink
Application Mode as a first-class deployment path while preserving current
Session SQL behavior as the default.

## Ground Truth Sources

- Current deploy orchestration: [lib.sh](lib.sh#L924), [lib.sh](lib.sh#L979), [lib.sh](lib.sh#L999)
- Current Flink runtime commands: [manifests/flink-template.yaml](manifests/flink-template.yaml#L281), [manifests/flink-template.yaml](manifests/flink-template.yaml#L396), [manifests/flink-template.yaml](manifests/flink-template.yaml#L488)
- Current SQL runtime image default command: [flink-docker/Dockerfile.sql-runtime](flink-docker/Dockerfile.sql-runtime#L21)
- Current session SQL assumptions: [flink-sql/10-session-config.sql](flink-sql/10-session-config.sql#L4), [flink-sql/10-session-config.sql](flink-sql/10-session-config.sql#L15)
- Current RBAC scope: [manifests/00-serviceaccount-rbac.yaml](manifests/00-serviceaccount-rbac.yaml#L12)
- Current docs architecture and operations: [README.md](README.md#L740)

## Baseline Code Evidence

### Deployment path always applies session SQL template and submits SQL

```bash
if [[ "${apply_template}" == true ]]; then
	apply_from_template "${BUNDLE_DIR}/manifests/template-flink-sql-gateway.yaml" "${OPENSHIFT_NAMESPACE}"
fi

if [[ "${submit_sql}" == true ]]; then
	flink_submit_sql "${env_file}"
fi
```

Source: [lib.sh](lib.sh#L979)

### Runtime startup commands are session-cluster daemons

```yaml
- exec /opt/flink/bin/jobmanager.sh start-foreground
...
- exec /opt/flink/bin/taskmanager.sh start-foreground
...
- exec /opt/flink/bin/sql-gateway.sh start-foreground
```

Source: [manifests/flink-template.yaml](manifests/flink-template.yaml#L281)

### SQL runtime image defaults to SQL Gateway

```dockerfile
ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["exec /opt/flink/bin/sql-gateway.sh start-foreground ..."]
```

Source: [flink-docker/Dockerfile.sql-runtime](flink-docker/Dockerfile.sql-runtime#L20)

### Session SQL file targets REST endpoint on jobmanager

```sql
SET 'pipeline.name' = '{{PIPELINE_NAME}}';
SET 'execution.runtime-mode' = 'STREAMING';
SET 'rest.address' = 'flink-jobmanager';
SET 'rest.port' = '8081';
```

Source: [flink-sql/10-session-config.sql](flink-sql/10-session-config.sql#L4)

## Implementation Requirements

1. Add deployment mode switch in shell orchestration
- Add env variable `FLINK_DEPLOYMENT_MODE` with allowed values `session` and `application`.
- Default to `session` to avoid breaking existing users.
- Add application-specific envs, at minimum:
	`FLINK_APP_JAR_URI`, `FLINK_APP_MAIN_CLASS`, `FLINK_APP_ARGS`,
	`FLINK_APP_PARALLELISM`.
- Update `flink_deploy()` flow to branch on mode.

2. Add a dedicated application-mode template
- Create a new template under `manifests/` for application mode.
- Keep existing `template-flink-sql-gateway.yaml` unchanged for session mode.
- In application mode, remove SQL Gateway dependency unless explicitly required.

3. Create a separate oc runbook for application submission
- Add a standalone README at `docs/flink-submit-application-oc/README.md` that shows the exact `oc` commands for the future `flink_submit_application()` workflow.
- Document the command sequence for applying the application-mode manifest, waiting for readiness, and verifying the running job.
- Keep the runbook separate from the main README so the submission workflow is easy to follow and can be referenced directly from implementation work.

################STOP here for now#########################

## Constraints

- Maintain backward compatibility for current session SQL workflows.
- Do not remove or rename existing session entry points.
- Preserve current deployment safety patterns and namespace-scoped behavior.
- Keep changes minimal and composable; avoid broad refactors unrelated to mode split.

## Deliverables

1. Code changes in shell orchestration for mode selection and app submission.
2. New application-mode template in `manifests/`.
3. Environment variable documentation/examples for application mode.
4. README updates with dual-mode runbook.
5. Validation commands and expected outcomes.

## Validation Checklist

- [ ] Session mode deploy path still applies `template-flink-sql-gateway.yaml` and can submit SQL.
- [ ] Application mode deploy path does not require SQL Gateway to run an app JAR.
- [ ] Application job can be launched with configured jar/main class/args.
- [ ] Existing non-root and OpenShift-compatible security settings are preserved.
- [ ] Documentation clearly separates session and application workflows.

## Suggested Verification Commands

```bash
# Session mode regression
source lib.sh
flink_deploy env/flink.dev.env --skip-build

# Application mode test
export FLINK_DEPLOYMENT_MODE=application
export FLINK_APP_JAR_URI=s3://example-bucket/flink/apps/my-app.jar
export FLINK_APP_MAIN_CLASS=com.example.Main
export FLINK_APP_ARGS="--input topicA --output topicB"
source lib.sh
flink_deploy env/flink.dev.env --skip-build
```

## Output Format Required from Implementer

Provide:

1. A concise design summary.
2. File-by-file diff summary.
3. Commands run for validation.
4. Residual risks and follow-up recommendations.