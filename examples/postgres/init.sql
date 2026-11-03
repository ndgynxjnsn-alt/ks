-- Runs once, on an empty data directory (docker-entrypoint-initdb.d).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE USER shop PASSWORD 'shop';
CREATE DATABASE shop OWNER shop;
\connect shop
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- in the database the exporter connects to

-- 10 000 fake catalog items for the catalog backend
CREATE TABLE items (
  id    integer PRIMARY KEY,
  name  text    NOT NULL,
  stock integer NOT NULL,
  price numeric(10, 2) NOT NULL
);
INSERT INTO items
SELECT i, 'item ' || i, (random() * 50)::int, round((5 + random() * 495)::numeric, 2)
FROM generate_series(1, 10000) AS i;
ALTER TABLE items OWNER TO shop;

-- the monitoring user of the Alloy sidecar
CREATE USER alloy PASSWORD 'alloy';
GRANT pg_monitor TO alloy;
