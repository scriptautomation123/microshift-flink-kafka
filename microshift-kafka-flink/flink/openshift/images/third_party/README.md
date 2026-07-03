# Third-Party JAR Staging

Stage organization-approved Flink 2.3 compatible connector JARs in this directory before building `Dockerfile.sql-runtime`.

Expected filenames:

- `flink-sql-connector-kafka.jar`
- `flink-json.jar`

Why this is manual:

- Flink 2.3 documentation currently notes that no published Kafka table connector artifact is aligned to 2.3 yet.
- In production, you should pin a connector JAR built and validated by your platform team instead of assuming a Maven coordinate that may not exist or may drift.