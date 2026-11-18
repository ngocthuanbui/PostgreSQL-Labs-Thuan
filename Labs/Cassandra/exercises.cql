-- ============================================================================
-- BÀI TẬP THỰC HÀNH CQL - COLUMN-FAMILY DATABASE (CASSANDRA)
-- ============================================================================

CREATE KEYSPACE IF NOT EXISTS shop
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3};

USE shop;

-- ----------------------------------------------------------------------------
-- Bài tập 1:
-- 1a) Bảng trả lời "10 đơn mới nhất của một khách hàng"
-- Partition key: customer_id (gom mọi đơn của cùng 1 khách hàng về cùng partition)
-- Clustering column: order_ts DESC, order_id (sắp xếp đơn mới nhất lên đầu)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orders_by_customer (
    customer_id text,
    order_ts    timestamp,
    order_id    uuid,
    total_price decimal,
    status      text,
    PRIMARY KEY ((customer_id), order_ts, order_id)
) WITH CLUSTERING ORDER BY (order_ts DESC, order_id ASC);

-- 1b) Bảng thứ hai trả lời "đơn theo ngày"
-- Partition key: order_day (gom mọi đơn trong cùng một ngày về 1 partition)
-- Clustering column: order_ts DESC, order_id (sắp xếp theo thời điểm đặt đơn)
CREATE TABLE IF NOT EXISTS orders_by_day (
    order_day   date,
    order_ts    timestamp,
    order_id    uuid,
    customer_id text,
    total_price decimal,
    status      text,
    PRIMARY KEY ((order_day), order_ts, order_id)
) WITH CLUSTERING ORDER BY (order_ts DESC, order_id ASC);

-- Thêm dữ liệu mẫu vào cả 2 bảng (denormalization / query-first modeling)
INSERT INTO orders_by_customer (customer_id, order_ts, order_id, total_price, status)
VALUES ('cust-01', '2026-11-04 08:30:00', 11111111-1111-1111-1111-111111111111, 250000, 'COMPLETED');
INSERT INTO orders_by_customer (customer_id, order_ts, order_id, total_price, status)
VALUES ('cust-01', '2026-11-04 10:15:00', 22222222-2222-2222-2222-222222222222, 480000, 'SHIPPING');

INSERT INTO orders_by_day (order_day, order_ts, order_id, customer_id, total_price, status)
VALUES ('2026-11-04', '2026-11-04 08:30:00', 11111111-1111-1111-1111-111111111111, 'cust-01', 250000, 'COMPLETED');
INSERT INTO orders_by_day (order_day, order_ts, order_id, customer_id, total_price, status)
VALUES ('2026-11-04', '2026-11-04 10:15:00', 22222222-2222-2222-2222-222222222222, 'cust-01', 480000, 'SHIPPING');

-- Truy vấn 10 đơn mới nhất của khách hàng 'cust-01'
SELECT * FROM orders_by_customer WHERE customer_id = 'cust-01' LIMIT 10;

-- Truy vấn các đơn hàng trong ngày '2026-11-04'
SELECT * FROM orders_by_day WHERE order_day = '2026-11-04';


-- ----------------------------------------------------------------------------
-- Bài tập 2:
-- Thêm số đo cho 3 cảm biến và thử truy vấn bỏ qua partition key
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS readings_by_sensor (
    sensor_id   text,
    ts          timestamp,
    temperature double,
    humidity    double,
    PRIMARY KEY ((sensor_id), ts)
) WITH CLUSTERING ORDER BY (ts DESC);

INSERT INTO readings_by_sensor (sensor_id, ts, temperature, humidity)
VALUES ('hn-01', '2026-10-22 08:00:00', 27.5, 71);
INSERT INTO readings_by_sensor (sensor_id, ts, temperature, humidity)
VALUES ('hn-02', '2026-10-22 08:00:00', 25.1, 80);
INSERT INTO readings_by_sensor (sensor_id, ts, temperature, humidity)
VALUES ('hn-03', '2026-10-22 08:00:00', 29.3, 65);

-- Truy vấn đúng (chỉ rõ partition key):
SELECT * FROM readings_by_sensor WHERE sensor_id = 'hn-01' LIMIT 10;

-- Truy vấn bỏ qua partition key (sẽ báo lỗi InvalidRequest):
-- SELECT * FROM readings_by_sensor WHERE temperature > 27;


-- ----------------------------------------------------------------------------
-- Bài tập 3:
-- Đổi schema sang partition theo bucket tháng để tránh Unbounded Partition
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS readings_by_sensor_monthly (
    sensor_id   text,
    month       text,       -- Ví dụ: '2026-10', '2026-11'
    ts          timestamp,
    temperature double,
    humidity    double,
    PRIMARY KEY ((sensor_id, month), ts)
) WITH CLUSTERING ORDER BY (ts DESC);

INSERT INTO readings_by_sensor_monthly (sensor_id, month, ts, temperature, humidity)
VALUES ('hn-01', '2026-10', '2026-10-22 08:00:00', 27.5, 71);
INSERT INTO readings_by_sensor_monthly (sensor_id, month, ts, temperature, humidity)
VALUES ('hn-01', '2026-11', '2026-11-04 08:00:00', 24.0, 68);

SELECT * FROM readings_by_sensor_monthly WHERE sensor_id = 'hn-01' AND month = '2026-10';


-- ----------------------------------------------------------------------------
-- Bảng cho Câu hỏi 3 trong Báo cáo:
-- Trả lời "các số đo trên 31.5°C trong một ngày" mà KHÔNG cần ALLOW FILTERING
-- Partition key: day (date)
-- Clustering columns: temperature DESC, ts DESC, sensor_id ASC
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS readings_by_day_temp (
    day         date,
    temperature double,
    ts          timestamp,
    sensor_id   text,
    humidity    double,
    PRIMARY KEY ((day), temperature, ts, sensor_id)
) WITH CLUSTERING ORDER BY (temperature DESC, ts DESC, sensor_id ASC);

INSERT INTO readings_by_day_temp (day, temperature, ts, sensor_id, humidity)
VALUES ('2026-10-22', 31.8, '2026-10-22 13:00:00', 'hn-01', 62.0);
INSERT INTO readings_by_day_temp (day, temperature, ts, sensor_id, humidity)
VALUES ('2026-10-22', 32.0, '2026-10-22 13:05:00', 'hn-05', 60.5);
INSERT INTO readings_by_day_temp (day, temperature, ts, sensor_id, humidity)
VALUES ('2026-10-22', 28.4, '2026-10-22 13:10:00', 'hn-02', 70.0);

-- Truy vấn lấy mọi số đo > 31.5°C trong ngày 2026-10-22 (chỉ chạm 1 partition, đọc theo thứ tự clustering):
SELECT * FROM readings_by_day_temp WHERE day = '2026-10-22' AND temperature > 31.5;
