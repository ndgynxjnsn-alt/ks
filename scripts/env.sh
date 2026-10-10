# Use the downloaded kubectl/helm and the cluster kubeconfig in your shell:  source scripts/env.sh
LGTM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$LGTM_ROOT/artifacts/bin:$PATH"
export KUBECONFIG="$LGTM_ROOT/kubeconfig"
