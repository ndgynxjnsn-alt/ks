# Shared environment for the scripts: local kubectl/helm and the cluster kubeconfig.
# Use it in your shell too:  source scripts/env.sh
LGTM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$LGTM_ROOT/.bin:$PATH"
export KUBECONFIG="$LGTM_ROOT/kubeconfig"
export HELM_CACHE_HOME="$LGTM_ROOT/.bin/helm-cache" HELM_CONFIG_HOME="$LGTM_ROOT/.bin/helm-config"
VIP=192.168.56.10
