INSERT INTO kafka_orders_sink
SELECT
  user_id,
  event_time,
  kafka_ts AS source_kafka_ts,
  CURRENT_TIMESTAMP AS processed_at
FROM kafka_orders_source;