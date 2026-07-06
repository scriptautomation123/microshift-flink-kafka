-- Render {{...}} placeholders in CI/CD before submission.

CREATE TABLE kafka_orders_source (
  user_id STRING,
  payload STRING,
  event_time TIMESTAMP_LTZ(3),
  kafka_ts TIMESTAMP_LTZ(3) METADATA FROM 'timestamp' VIRTUAL,
  kafka_partition INT METADATA FROM 'partition' VIRTUAL,
  kafka_offset BIGINT METADATA FROM 'offset' VIRTUAL,
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = '{{KAFKA_SOURCE_TOPIC}}',
  'properties.bootstrap.servers' = '{{KAFKA_BOOTSTRAP_SERVERS}}',
  'properties.group.id' = '{{KAFKA_CONSUMER_GROUP}}',
  'properties.security.protocol' = '{{KAFKA_SECURITY_PROTOCOL}}',
  'properties.sasl.mechanism' = '{{KAFKA_SASL_MECHANISM}}',
  'properties.sasl.jaas.config' = '{{KAFKA_SASL_JAAS_CONFIG}}',
  'properties.ssl.truststore.location' = '/opt/flink/secrets/kafka/kafka.truststore.jks',
  'properties.ssl.truststore.password' = '{{KAFKA_TRUSTSTORE_PASSWORD}}',
  'scan.startup.mode' = 'group-offsets',
  'scan.topic-partition-discovery.interval' = '5 min',
  'value.format' = 'json',
  'value.json.fail-on-missing-field' = 'false',
  'value.json.ignore-parse-errors' = 'false'
);