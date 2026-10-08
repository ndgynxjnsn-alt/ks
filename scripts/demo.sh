#!/usr/bin/env bash
# Builds the demo app image (Jib, no Docker daemon needed), imports it on every node and deploys it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

OTEL_AGENT_VERSION=2.32.0
PYROSCOPE_OTEL_VERSION=2.1.4 # OTel extension that bundles the Pyroscope Java agent + span profiles

(
  cd apps/demo
  ./mvnw -q clean package -DskipTests
  mkdir -p target/agents
  curl -sfL -o target/agents/opentelemetry-javaagent.jar \
    "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar"
  curl -sfL -o target/agents/pyroscope-otel-javaagent-extension.jar \
    "https://github.com/grafana/otel-profiling-java/releases/download/v${PYROSCOPE_OTEL_VERSION}/pyroscope-otel-javaagent-extension.jar"
  ./mvnw -q jib:buildTar
)

for node in lgtm1 lgtm2 lgtm3; do
  echo ">>> importing image on $node"
  vagrant ssh "$node" -c "sudo /var/lib/rancher/rke2/bin/ctr -a /run/k3s/containerd/containerd.sock -n k8s.io images import -" \
    <apps/demo/target/jib-image.tar 2>/dev/null
done

kubectl apply -f k8s/demo.yaml
kubectl -n demo rollout restart deployment
kubectl -n demo rollout status deployment --timeout 5m
