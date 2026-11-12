-- Enables the image's extensions on the first start (empty data directory). template1: every database created
-- later (e.g. by the app's own init scripts) has them as well. TimescaleDB is created by the base image's
-- 000_install_timescaledb.sh; it needs shared_preload_libraries = 'timescaledb' in the server's configuration.
\connect template1
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;     -- needed by h3_postgis
CREATE EXTENSION IF NOT EXISTS h3;
CREATE EXTENSION IF NOT EXISTS h3_postgis;
\connect postgres
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS h3;
CREATE EXTENSION IF NOT EXISTS h3_postgis;
