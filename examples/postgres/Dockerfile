# PostgreSQL 18 with TimescaleDB 2.24 (base image), PostGIS and H3, built from source. Same extension versions as
# lnf9s35w2/my-offline-timescale:pg18.
#   builder: compiles PostGIS (with raster, topology, SFCGAL) and h3-pg against the base image's PostgreSQL
#   final:   the base image + the runtime libraries + the built extension files; extensions-init.sql enables them
#            on the first start (template1, so every database created later has them too)
# The base image is Alpine with PostgreSQL in /usr/local; the server runs as user postgres (uid 70),
# PGDATA=/var/lib/postgresql/18/docker.
ARG BASE_IMAGE=timescale/timescaledb:2.24.0-pg18

FROM ${BASE_IMAGE} AS builder
ARG POSTGIS_VERSION=3.6.2
ARG POSTGIS_SHA256=d488089a64ee4060bce7dbba0291fcca358e7f7ac5230e2ee5b344e7485729c4
ARG H3PG_VERSION=4.2.3
ARG H3PG_SHA256=3c420e8ee3324bfeac600cadf3c7a7bc26c3b95e123d48e40459d34dcd714654
# PGXS also compiles LLVM bitcode for JIT (the base PostgreSQL is built --with-llvm): clang19/llvm19
RUN apk add --no-cache build-base clang19 llvm19-dev cmake curl perl \
        geos-dev proj-dev gdal-dev libxml2-dev json-c-dev protobuf-c-dev sfcgal-dev pcre2-dev
WORKDIR /build
RUN curl -fsSL -o postgis.tar.gz "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VERSION}.tar.gz" \
    && echo "${POSTGIS_SHA256}  postgis.tar.gz" | sha256sum -c - \
    && tar -xzf postgis.tar.gz \
    && cd "postgis-${POSTGIS_VERSION}" \
    && ./configure --with-sfcgal --without-gui --without-interrupt-tests \
    && make -j"$(nproc)" \
    && make install
# h3-pg fetches the h3 core library itself (pinned version + SHA256 in its cmake/h3/CMakeLists.txt)
RUN curl -fsSL -o h3-pg.tar.gz "https://github.com/postgis/h3-pg/archive/refs/tags/v${H3PG_VERSION}.tar.gz" \
    && echo "${H3PG_SHA256}  h3-pg.tar.gz" | sha256sum -c - \
    && tar -xzf h3-pg.tar.gz \
    && cd "h3-pg-${H3PG_VERSION}" \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build --component h3-pg

FROM ${BASE_IMAGE}
# runtime libraries of PostGIS (geometry, projections, raster, JSON, MVT, 3D)
RUN apk add --no-cache geos proj gdal libxml2 json-c protobuf-c sfcgal pcre2
COPY --from=builder /usr/local/lib/postgresql/postgis*.so /usr/local/lib/postgresql/h3*.so \
     /usr/local/lib/postgresql/address_standardizer*.so /usr/local/lib/postgresql/
COPY --from=builder /usr/local/share/postgresql/extension/postgis* /usr/local/share/postgresql/extension/h3* \
     /usr/local/share/postgresql/extension/address_standardizer* /usr/local/share/postgresql/extension/
COPY --from=builder /usr/local/share/postgresql/contrib/ /usr/local/share/postgresql/contrib/
COPY --from=builder /usr/local/bin/shp2pgsql /usr/local/bin/pgsql2shp /usr/local/bin/raster2pgsql /usr/local/bin/
# Runs after the base image's 000_install_timescaledb.sh / 001_timescaledb_tune.sh, before the app's own scripts
COPY extensions-init.sql /docker-entrypoint-initdb.d/002_extensions.sql
# Log directory for logging_collector: owned by postgres, readable for a log shipper (e.g. an Alloy sidecar on
# the same volume). A new named volume mounted here takes over this ownership.
RUN install -d -o postgres -g postgres -m 0755 /var/log/postgresql
