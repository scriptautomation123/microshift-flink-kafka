-- Render {{...}} placeholders in CI/CD before submission.

CREATE TABLE kafka_orders_sink (
  user_id STRING,
  event_time TIMESTAMP_LTZ(3),
  source_kafka_ts TIMESTAMP_LTZ(3),
  processed_at TIMESTAMP_LTZ(3)
) WITH (
  'connector' = 'kafka',
  'topic' = '{{KAFKA_SINK_TOPIC}}',
  'properties.bootstrap.servers' = '{{KAFKA_BOOTSTRAP_SERVERS}}',
  'properties.security.protocol' = '{{KAFKA_SECURITY_PROTOCOL}}',
  'properties.sasl.mechanism' = '{{KAFKA_SASL_MECHANISM}}',
  'properties.sasl.jaas.config' = '{{KAFKA_SASL_JAAS_CONFIG}}',
  'properties.ssl.truststore.location' = '/opt/flink/secrets/kafka/kafka.truststore.jks',
  'properties.ssl.truststore.password' = '{{KAFKA_TRUSTSTORE_PASSWORD}}',
  'key.format' = 'json',
  'key.fields' = 'user_id',
  'value.format' = 'json',
  'value.fields-include' = 'EXCEPT_KEY',
  'value.json.fail-on-missing-field' = 'false',
  'sink.delivery-guarantee' = 'exactly-once',
  'sink.transactional-id-prefix' = '{{KAFKA_TRANSACTIONAL_ID_PREFIX}}',
  'sink.partitioner' = 'default'
);