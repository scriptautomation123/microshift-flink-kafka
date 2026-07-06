# Script Consolidation Plan: Centralize Everything into lib.sh

## Objective
Eliminate script duplication and maintenance burden by consolidating ALL functionality into a single `scripts/lib.sh` with separate functions. No wrapper scripts - functions are called directly from lib.sh via sourcing.

## Current State

### Scripts by Component
- **Flink scripts**: bootstrap-ci.sh, build-images.sh, create-secrets.sh, deploy.sh, registry-login.sh, render.sh, apply-manifests.sh, submit-sql.sh, smoke-sql-gateway-kafka.sh, test-all-functionality.sh, validate-namespace-identities.sh (11 scripts)
- **Kafka scripts**: build-image.sh, check.sh, create-topic.sh, delete.sh, deploy.sh, generate-kraft-cluster-id.sh, maintenance-guard.sh, render-manifests.sh, apply-manifests.sh, test-all-functionality.sh (10 scripts)
- **Root scripts**: registry-login.sh, lib.sh, regenerate-namespace-identities-umbrella.sh (3 scripts)
- **Runbooks scripts**: cleanup-all, test-all, validate-platform-all.sh (3 scripts)

### Duplication Issues
- Registry login logic duplicated (scripts/registry-login.sh + flink registry-login.sh + bootstrap-ci.sh)
- Test orchestration duplicated (flink + kafka test-all-functionality.sh)
- Namespace validation repeated
- Topic creation has custom logic per component
- Health check scripts not centralized

## Consolidation Strategy

### Phase 1: Backup
Create `docs/.backup/` with:
```
docs/.backup/
├── flink-scripts/      (all flink/openshift/scripts)
├── kafka-scripts/      (all kafka/openshift/scripts)
└── root-scripts/       (scripts/*.sh, runbooks/scripts/*)
```

### Phase 2: Extend lib.sh with Wrapper Functions

Add to `scripts/lib.sh`:

#### Container & Registry Functions
- `registry_login <env-file>` - Login to container registry (podman/docker)
- `build_images_flink <env-file>` - Build Flink base + SQL runtime images
- `build_image_kafka <env-file>` - Build Kafka KRaft image
- `push_image <image>` - Push image to registry

#### CI/Bootstrap Functions
- `bootstrap_ci_flink <env-file>` - Create imagestreams, pull secrets, registry login
- `bootstrap_ci_kafka <env-file>` - Verify namespace access, setup pull secrets

#### Secrets & Configuration Functions
- `create_secrets_flink <env-file>` - Create Kafka/ObjectStore secrets
- `create_secrets_kafka <env-file>` - Create topic-related secrets (if needed)
- `create_generic_secret <namespace> <secret-name> <key=value...>` - Generic secret creation
- `create_file_secret <namespace> <secret-name> <key=filepath...>` - Secret from files

#### Kafka-Specific Functions
- `kafka_delete_resources <namespace>` - Delete all Kafka resources gracefully
- `kafka_health_check <namespace>` - Verify broker health
- `kafka_create_topic <env-file> <topic> [--partitions N] [--replication N] [--retention-ms N]` - Create topic
- `kafka_maintenance_guard <env-file> <topic> --phase pre|post` - HA drill validation
- `kafka_test_all <env-file> [--clean] [--skip-build]` - Full test cycle

#### Flink-Specific Functions
- `flink_bootstrap_ci <env-file>` - Setup Flink CI environment
- `flink_build_images <env-file>` - Build all Flink images
- `flink_create_secrets <env-file>` - Create Kafka/ObjectStore/Config secrets
- `flink_test_all <env-file> [--clean] [--preflight]` - Full test cycle
- `flink_smoke_test <env-file>` - Smoke test via SQL Gateway
- `validate_flink_identities [--json] [namespaces...]` - Validate ServiceAccount RBAC
- `regenerate_namespace_identities_umbrella [--check]` - Update umbrella manifests

#### Generic Utility Functions
- `wait_for_namespace_delete <namespace>` - Poll until namespace gone
- `generate_uuid` - Generate RFC4122 UUID
- `split_sql_file <file> <output-dir>` - Split multi-statement SQL files
- `json_get <file> <key>` - Already exists, ensure used everywhere
- `sanitize_name <input>` - Sanitize for Kubernetes names
- `timestamp_now` - RFC3339 timestamp

#### Orchestration Functions
- `run_deploy_cycle_flink <env-file> [flags]` - Deploy→check→test cycle
- `run_deploy_cycle_kafka <env-file> [flags]` - Deploy→check→test cycle
- `run_full_platform_test <kafka-env> <flink-env> [flags]` - End-to-end test
- `cleanup_all [--purge-local-data] [--skip-namespaces]` - Clean up all deployments
- `validate_all [--json] [namespaces...]` - Validate all RBAC and identities

#### Quick-Start/Example Functions
These combine common workflows into single functions:
- `example_deploy_flink_only <env-file>` - Deploy Flink cluster only
- `example_deploy_kafka_only <env-file>` - Deploy Kafka cluster only
- `example_deploy_full_platform <kafka-env> <flink-env>` - Deploy both clusters
- `example_test_flink <env-file>` - Run full Flink test cycle
- `example_test_kafka <env-file>` - Run full Kafka test cycle
- `example_test_full_platform <kafka-env> <flink-env>` - Run full end-to-end test
- `example_build_all_images <kafka-env> <flink-env>` - Build all images for both components
- `example_cleanup_and_validate <kafka-env> <flink-env>` - Cleanup and validate all

### Phase 3: All Functionality in lib.sh

All functions (including orchestration) live in `scripts/lib.sh`. No separate wrapper scripts or orchestrator. Usage pattern:

```bash
source scripts/lib.sh
flink_deploy flink/openshift/env/dev.env
```

### Phase 4: Delete ALL Scripts (After Verification)

After all functions are consolidated into lib.sh and verified working:

**Delete all from flink/openshift/scripts/**:
- ~~bootstrap-ci.sh~~ → `flink_bootstrap_ci()` in lib.sh
- ~~build-images.sh~~ → `flink_build_images()` in lib.sh
- ~~create-secrets.sh~~ → `flink_create_secrets()` in lib.sh
- ~~deploy.sh~~ → `flink_deploy()` in lib.sh
- ~~registry-login.sh~~ → `registry_login()` in lib.sh
- ~~render.sh~~ → `render_bundle()` in lib.sh
- ~~apply-manifests.sh~~ → `apply_from_template()` in lib.sh
- ~~submit-sql.sh~~ → `flink_submit_sql()` in lib.sh
- ~~smoke-sql-gateway-kafka.sh~~ → `flink_smoke_test()` in lib.sh
- ~~test-all-functionality.sh~~ → `flink_test_all()` in lib.sh
- ~~validate-namespace-identities.sh~~ → `validate_flink_identities()` in lib.sh

**Delete all from kafka/openshift/scripts/**:
- ~~build-image.sh~~ → `build_image_kafka()` in lib.sh
- ~~check.sh~~ → `kafka_health_check()` in lib.sh
- ~~create-topic.sh~~ → `kafka_create_topic()` in lib.sh
- ~~delete.sh~~ → `kafka_delete_resources()` in lib.sh
- ~~deploy.sh~~ → `kafka_deploy()` in lib.sh
- ~~generate-kraft-cluster-id.sh~~ → `generate_uuid()` in lib.sh
- ~~maintenance-guard.sh~~ → `kafka_maintenance_guard()` in lib.sh
- ~~render-manifests.sh~~ → not needed (templates parameterized)
- ~~apply-manifests.sh~~ → `apply_from_template()` in lib.sh
- ~~test-all-functionality.sh~~ → `kafka_test_all()` in lib.sh

**Delete all from scripts/**:
- ~~registry-login.sh~~ → `registry_login()` in lib.sh
- ~~regenerate-namespace-identities-umbrella.sh~~ → `regenerate_namespace_identities_umbrella()` in lib.sh

**Delete all from runbooks/scripts/**:
- ~~cleanup-all~~ → `cleanup_all()` in lib.sh
- ~~test-all~~ → `run_full_platform_test()` in lib.sh
- ~~validate-platform-all.sh~~ → `validate_all()` in lib.sh

**Keep only:**
- `scripts/lib.sh` (single consolidated library with all functions)

## Result

### File Counts
- **Before**: 26 scripts (Flink: 11, Kafka: 10, Root: 3, Runbooks: 3)
- **After**: 1 file only
  - `scripts/lib.sh` (consolidated 60+ functions, ~1500+ lines)
  - ALL other scripts deleted (no wrapper scripts, no orchestrator script)

### Maintenance Benefits
✓ Single source of truth - ALL functionality in one file (scripts/lib.sh)
✓ ZERO script duplication - no wrapper scripts, no component-level deploy.sh files, no orchestrator
✓ Unified logging, error handling, validation across all operations
✓ Massive reduction in files (26 scripts → 1 file)
✓ Common patterns reused via functions (registry_login, build_image_*, deploy, test, etc.)
✓ Easy to version and distribute (single lib.sh file)
✓ Dramatically simpler directory structure
✓ One consistent entry point: `source scripts/lib.sh && function_name args`
✓ Example functions for quick validation and common workflows
✓ No shell script orchestration complexity (all functions do single job)

### Usage Examples

```bash
# Source lib.sh and call functions directly
source scripts/lib.sh

# Deploy Flink cluster
flink_deploy flink/openshift/env/dev.env

# Deploy Kafka cluster
kafka_deploy kafka/openshift/env/dev.env

# Build Flink images
flink_build_images flink/openshift/env/dev.env

# Build Kafka image
build_image_kafka kafka/openshift/env/dev.env

# Create Kafka topic
kafka_create_topic kafka/openshift/env/dev.env my-topic --partitions 6 --replication 3

# Check Kafka health
kafka_health_check kafka-dev

# Run full Flink test cycle
flink_test_all flink/openshift/env/dev.env --clean

# Run full Kafka test cycle
kafka_test_all kafka/openshift/env/dev.env --clean

# Run end-to-end platform test
run_full_platform_test kafka/openshift/env/dev.env flink/openshift/env/dev.env

# Cleanup everything
cleanup_all --purge-local-data

# Validate RBAC
validate_all --json
```

## Implementation Order
1. Back up all scripts to docs/.backup/
2. Add all functions to lib.sh (60+ functions total):
   - Start with utility functions (registry_login, generate_uuid, wait_for_namespace_delete, etc.)
   - Add Kafka-specific functions (kafka_deploy, kafka_create_topic, kafka_health_check, kafka_delete_resources, kafka_test_all, etc.)
   - Add Flink-specific functions (flink_deploy, flink_build_images, flink_create_secrets, flink_test_all, flink_smoke_test, validate_flink_identities, etc.)
   - Add orchestration functions (run_deploy_cycle_flink, run_deploy_cycle_kafka, run_full_platform_test, cleanup_all, validate_all)
   - Add quick-start example functions (example_deploy_flink_only, example_deploy_full_platform, example_test_kafka, etc.)
3. Test each function group independently
4. Test cross-component orchestration workflows
5. Delete ALL old scripts (26 total) after full verification
6. Update .instructions.md to document all function signatures, parameters, and usage
7. Update README with new lib.sh-based workflow
8. Create quick-start guide for common operations (single source file)

## Risk Mitigation
- Keep backups in docs/.backup/ until all workflows fully verified
- Test each function independently before deleting corresponding old script
- Test cross-component orchestration (Kafka + Flink together)
- Run full end-to-end test cycles before deleting any old scripts
- Create transition guide: map old scripts → new lib.sh functions
- Version bump when consolidation complete
- Document that ALL functionality now accessed via: `source scripts/lib.sh && function_name args` (no wrapper scripts, no separate orchestrator)
- Test example functions (example_deploy_flink_only, example_deploy_full_platform, etc.) as quick validation
- Verify all component-level scripts (flink/, kafka/, runbooks/) can be safely deleted
