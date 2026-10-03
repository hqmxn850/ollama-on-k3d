#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
mkdir -p "$DIST_DIR"

RANCHER_NS="${RANCHER_NAMESPACE:-${1:-cattle-system}}"

log() { echo -e "\033[36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

if ! command -v kubectl &>/dev/null; then
  err "kubectl がインストールされていません。"
  exit 1
fi

log "Rancher Pod を取得中..."
PODS=$(kubectl get pods -n "$RANCHER_NS" -l app=rancher --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [[ -z "$PODS" ]]; then
  warn "稼働中の Rancher Pod が見つかりません。スキップします。"
  exit 0
fi

FIRST_POD=$(echo "$PODS" | awk '{print $1}')

INDEX_FILE=$(kubectl exec -n "$RANCHER_NS" "$FIRST_POD" -c rancher -- sh -c 'ls /usr/share/rancher/ui-dashboard/dashboard/js/index.*.js 2>/dev/null | grep -v "ja2026" | head -1' | xargs -r basename || true)
if [[ -z "$INDEX_FILE" ]]; then
  INDEX_FILE=$(kubectl exec -n "$RANCHER_NS" "$FIRST_POD" -c rancher -- sh -c 'ls /usr/share/rancher/ui-dashboard/dashboard/js/index.*.js 2>/dev/null | head -1' | xargs -r basename || true)
fi

log "Rancher Dashboard メインバンドル: ${INDEX_FILE}"
kubectl cp -n "$RANCHER_NS" "${FIRST_POD}:/usr/share/rancher/ui-dashboard/dashboard/js/${INDEX_FILE}" "${DIST_DIR}/index.orig.js" -c rancher

# 1. パッチ済みアセットのビルド
log "日本語アセット (キャッシュバスター対応版) をビルド中..."
python3 "${SCRIPT_DIR}/build-patched-assets.py" "${DIST_DIR}/index.orig.js"

# 2. 各 Pod にアセットを配置し、index.html を更新
for POD in $PODS; do
  log "Pod に日本語化アセットを配置中: ${POD}"
  # チャンク & index.js を配置
  kubectl cp "${DIST_DIR}/zh-hans-yaml.ja2026.js" "${RANCHER_NS}/${POD}:/usr/share/rancher/ui-dashboard/dashboard/js/zh-hans-yaml.ja2026.js" -c rancher
  kubectl cp "${DIST_DIR}/index.ja2026.js" "${RANCHER_NS}/${POD}:/usr/share/rancher/ui-dashboard/dashboard/js/index.ja2026.js" -c rancher

  # index.html の script タグを index.ja2026.js に差し替え & 言語タグ更新 & 日本語固定化スクリプト注入
  kubectl exec -n "$RANCHER_NS" "$POD" -c rancher -- sh -c '
    sed -i "s|src=\"/dashboard/js/index\.[a-zA-Z0-9\.]*\"|src=\"/dashboard/js/index.ja2026.js?v=ja2026\"|g" /usr/share/rancher/ui-dashboard/dashboard/index.html
    sed -i "s|<html lang=\"[^\"]*\"|<html lang=\"ja\"|g" /usr/share/rancher/ui-dashboard/dashboard/index.html
    if ! grep -q "R_LOCALE=zh-hans" /usr/share/rancher/ui-dashboard/dashboard/index.html; then
      sed -i "s|<head>|<head><script>(()=>{try{localStorage.setItem(\"locale\",\"zh-hans\");document.cookie=\"R_LOCALE=zh-hans;path=/;max-age=31536000\";}catch(e){}})();</script>|g" /usr/share/rancher/ui-dashboard/dashboard/index.html
    fi
  '

done

log "Rancher Dashboard の日本語化パッチ適用が完了しました！"
