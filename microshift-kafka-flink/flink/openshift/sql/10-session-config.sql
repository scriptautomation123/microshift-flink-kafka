-- Render {{...}} placeholders in CI/CD before submission.
-- Do not commit resolved secrets or environment-specific values.

SET 'pipeline.name' = '{{PIPELINE_NAME}}';
SET 'parallelism.default' = '4';
SET 'execution.runtime-mode' = 'STREAMING';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '60 s';
SET 'execution.checkpointing.min-pause' = '30 s';
SET 'execution.checkpointing.timeout' = '10 min';
SET 'execution.checkpointing.max-concurrent-checkpoints' = '1';
SET 'execution.checkpointing.externalized-checkpoint-retention' = 'RETAIN_ON_CANCELLATION';
SET 'table.local-time-zone' = 'UTC';
SET 'table.exec.source.idle-timeout' = '60 s';
SET 'rest.address' = 'flink-jobmanager';
SET 'rest.port' = '8081';