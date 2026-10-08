#!/usr/bin/env bash
# Installs/updates the LGTM stack. Idempotent: re-run after changing anything in k8s/.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

# Chart versions (latest as of 2026-10).
LOKI_CHART=18.15.0       # Loki 3.7.8     grafana-community
TEMPO_CHART=3.1.0        # Tempo 3.1.0    grafana-community
GRAFANA_CHART=13.4.0     # Grafana 13.2.3 grafana-community
PYROSCOPE_CHART=2.3.2    # Pyroscope 2.3.2
ALLOY_CHART=1.13.1       # Alloy 1.20.1
# Mimir monolithic chart from the NGDATA fork (branch release-6.0.6-1-lily), pinned.
NGDATA_REPO=https://github.com/NGDATA/mimir.git
NGDATA_COMMIT=d089f535d717c7f8a7e06dc70f84bb27017b4373

GRAFANA_COMMUNITY=https://grafana-community.github.io/helm-charts
GRAFANA_REPO=https://grafana.github.io/helm-charts

grep -q '^GRAFANA_ADMIN_PASSWORD=' .secrets/cluster.env ||
  echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 12)" >>.secrets/cluster.env
set -a; source .secrets/cluster.env; set +a
export S3_ENDPOINT="${VIP}:3900" # Garage runs on every node; the VIP always points at a live one.

# values file with secrets filled in (written to the gitignored .secrets/)
values() {
  envsubst '${S3_ENDPOINT} ${S3_ACCESS_KEY_ID} ${S3_SECRET_ACCESS_KEY} ${GRAFANA_ADMIN_PASSWORD}' \
    <"k8s/values/$1.yaml" >".secrets/values-$1.yaml"
  echo ".secrets/values-$1.yaml"
}

mimir_chart() {
  local dir=.bin/charts/ngdata-mimir
  if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$NGDATA_COMMIT" ]; then
    rm -rf "$dir"
    git clone -q --filter=blob:none --no-checkout "$NGDATA_REPO" "$dir"
    git -C "$dir" sparse-checkout set operations/helm/charts/mimir-distributed operations/mimir-mixin-compiled
    git -C "$dir" checkout -q "$NGDATA_COMMIT"
  fi
  local chart=$dir/operations/helm/charts/mimir-distributed
  [ -d "$chart/charts" ] || {
    helm repo add minio https://charts.min.io/ >/dev/null
    helm repo add grafana "$GRAFANA_REPO" >/dev/null
    helm dependency build "$chart" >/dev/null 2>&1
  }
  echo "$chart"
}

install() { # release chart-args...
  local rel=$1; shift
  echo ">>> $rel"
  helm upgrade --install "$rel" "$@" -n lgtm --create-namespace --wait --timeout 15m 2>&1 | grep -v "symbolic link"
}

install loki      loki      --repo "$GRAFANA_COMMUNITY" --version "$LOKI_CHART"      -f "$(values loki)"
install mimir     "$(mimir_chart)"                                                   -f "$(values mimir)"
install tempo     tempo     --repo "$GRAFANA_COMMUNITY" --version "$TEMPO_CHART"     -f "$(values tempo)"
install pyroscope pyroscope --repo "$GRAFANA_REPO"      --version "$PYROSCOPE_CHART" -f "$(values pyroscope)"
install alloy     alloy     --repo "$GRAFANA_REPO"      --version "$ALLOY_CHART"     -f "$(values alloy)"
install grafana   grafana   --repo "$GRAFANA_COMMUNITY" --version "$GRAFANA_CHART"   -f "$(values grafana)"
kubectl apply -f k8s/ingress.yaml

echo ">>> done. Grafana: http://grafana.org  (admin / ${GRAFANA_ADMIN_PASSWORD})"
