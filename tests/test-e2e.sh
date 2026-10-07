#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 全体テスト (End-to-End Test)
# - クラスタの起動 (./start.sh)
# - ノード・サービスの正常性確認 (Server 8コア / Worker 24コア)
# - AI サービス (Lemonade / Open WebUI) の健全性確認
# - クラスタの停止 (./stop.sh)
# - 停止前の images.txt 自動更新 & Podman キャッシュ保存確認
# - リソースの完全クリーンアップ確認
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo -e "  [${GREEN}PASS${RESET}] $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo -e "  [${RED}FAIL${RESET}] $*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

info() { echo -e "\n${CYAN}=== $* ===${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $*${RESET}"; }

cd "${PROJECT_ROOT}"

# 引数処理 (-y/--yes, --ansible)
FORCE=false
USE_ANSIBLE=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--force)
      FORCE=true
      ;;
    --ansible)
      USE_ANSIBLE=true
      ;;
  esac
done

if [[ "$FORCE" != true ]]; then
  MODE_LABEL="start.sh / stop.sh (Ansible ラッパー)"
  if [[ "$USE_ANSIBLE" == true ]]; then
    MODE_LABEL="ansible-playbook 直接実行 (site.yml / teardown.yml)"
  fi
  echo -e "${YELLOW}${BOLD}【注意】このテストはクラスタの起動と完全停止・クリーンアップを伴う全体テストです。${RESET}"
  echo "実行モード: ${MODE_LABEL}"
  echo "現在のクラスタ環境が再作成されます。"
  read -p "続行しますか？ (y/N): " -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
    echo "全体テストを中止しました。"
    exit 0
  fi
fi

if [[ "$USE_ANSIBLE" == true ]]; then
  # ansible-playbook 直接実行では SSOT (config.env / versions.env) を環境変数に
  # エクスポートする (start.sh と同じ読み込み順)。省略すると group_vars の
  # フォールバック既定値 (例: K3s イメージ) が使われ、config.yaml が
  # versions.env のバージョンと食い違うため。
  set -a
  # shellcheck disable=SC1091
  source config.env 2>/dev/null || true
  # shellcheck disable=SC1091
  source versions.env 2>/dev/null || true
  set +a
  info "E2E Step 1: クラスタ起動テスト (ansible-playbook site.yml 直接実行)"
  echo "Ansible Playbook によるクラスタデプロイを開始します..."
  if ANSIBLE_CONFIG="${PROJECT_ROOT}/ansible/ansible.cfg" \
    ansible-playbook -i "${PROJECT_ROOT}/ansible/inventory.ini" \
    "${PROJECT_ROOT}/ansible/playbooks/site.yml"; then
    pass "ansible-playbook site.yml によるデプロイメント完了"
  else
    fail "ansible-playbook site.yml デプロイメント失敗"
    exit 1
  fi
else
  info "E2E Step 1: クラスタ起動テスト (./start.sh)"
  echo "クラスタデプロイを開始します (数分程度かかります)..."
  if ./start.sh; then
    pass "start.sh によるデプロイメント完了"
  else
    fail "start.sh デプロイメント失敗"
    exit 1
  fi
fi

info "E2E Step 2: クラスタノード & サービス健全性確認"
KUBECONFIG_PATH="${HOME}/.kube/config"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  source config.env 2>/dev/null || true
  EXPECTED_NODES=$(( ${SERVERS:-1} + ${AGENTS:-1} ))
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
  if [[ $READY_NODES -ge $EXPECTED_NODES ]]; then
    pass "クラスタノード確認: 全 ${EXPECTED_NODES} ノード Ready"
  else
    fail "クラスタノード確認: Ready ノード数が不足 (${READY_NODES}/${EXPECTED_NODES})"
  fi
else
  fail "kubeconfig が存在しません: $KUBECONFIG_PATH"
fi

info "E2E Step 3: AI サービス (Lemonade / Open WebUI) 健全性確認"
DEFAULT_EMAIL_DOMAIN="philippines.com.ph"
source config.env 2>/dev/null || true
OPEN_WEBUI_HOST="${OPEN_WEBUI_HOSTNAME:-chat.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}"
LEMONADE_HOST="${LEMONADE_HOSTNAME:-lemonade.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}"

# Lemonade API (Ollama 互換) 疎通確認
# LEMONADE_INGRESS_AUTH_ENABLED=true (既定) のとき、外部アクセスは SSO
# forwardAuth により認証要求 (302/401 等) されるのが正常。クラスタ内
# Service FQDN 呼び出し (Open WebUI 等) には認証は掛からない。
LEMONADE_AUTH="${LEMONADE_INGRESS_AUTH_ENABLED:-true}"
LEMONADE_HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://${LEMONADE_HOST}/api/tags" 2>/dev/null || echo "000")
if [[ "$LEMONADE_AUTH" == "true" ]]; then
  if [[ "$LEMONADE_HTTP" =~ ^(301|302|303|401|403)$ ]]; then
    pass "Lemonade API SSO 認証要求を確認 (HTTP ${LEMONADE_HTTP} / https://${LEMONADE_HOST})"
  elif [[ "$LEMONADE_HTTP" == "200" ]]; then
    fail "Lemonade API が認証なしでアクセス可能 (SSO forwardAuth が未適用 / HTTP 200)"
  else
    warn "Lemonade API 疎通 (HTTP ${LEMONADE_HTTP} / https://${LEMONADE_HOST})"
  fi
elif [[ "$LEMONADE_HTTP" == "200" ]]; then
  pass "Lemonade API 疎通確認 (HTTP 200 / https://${LEMONADE_HOST} / SSO 無効)"
else
  warn "Lemonade API 疎通 (HTTP ${LEMONADE_HTTP} / https://${LEMONADE_HOST})"
fi

# クラスタ内からの Lemonade バックエンド直接確認 (公開 URL は SSO 保護のため
# 応答が認証要求になる。実 API の 200 は NetworkPolicy 許可 ns の Open WebUI
# Pod から Service FQDN 経由で確認する)
OWUI_POD=$(kubectl get pod -n open-webui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$OWUI_POD" ]]; then
  INCLUSTER_HTTP=""
  for PY_BIN in python3 python; do
    INCLUSTER_HTTP=$(kubectl exec -n open-webui -c open-webui "$OWUI_POD" -- \
      "$PY_BIN" -c "import urllib.request;print(urllib.request.urlopen('http://lemonade.lemonade.svc.cluster.local:${LEMONADE_PORT:-11434}/api/tags',timeout=15).status)" \
      2>/dev/null | tail -1 || true)
    if [[ -n "$INCLUSTER_HTTP" ]]; then
      break
    fi
  done
  if [[ "$INCLUSTER_HTTP" == "200" ]]; then
    pass "Lemonade バックエンド疎通 (クラスタ内 Service FQDN / HTTP 200 / pod: ${OWUI_POD})"
  else
    fail "Lemonade バックエンド疎通失敗 (クラスタ内応答: ${INCLUSTER_HTTP:-なし} / pod: ${OWUI_POD})"
  fi
else
  fail "open-webui Pod が見つからないためクラスタ内 Lemonade 疎通を確認できません"
fi

# Open WebUI 疎通確認
WEBUI_HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://${OPEN_WEBUI_HOST}/" 2>/dev/null || echo "000")
if [[ "$WEBUI_HTTP" =~ ^(200|302|301)$ ]]; then
  pass "Open WebUI 疎通確認 (HTTP ${WEBUI_HTTP} / https://${OPEN_WEBUI_HOST})"
else
  warn "Open WebUI 疎通 (HTTP ${WEBUI_HTTP} / https://${OPEN_WEBUI_HOST})"
fi

info "E2E Step 4: クラスタ停止 & イメージ保存・一覧更新テスト"
BEFORE_STOP_TIME=$(date +%s)

STOP_FAILED=false
if [[ "$USE_ANSIBLE" == true ]]; then
  echo "Ansible Playbook によるクラスタ停止・クリーンアップを開始します..."
  if ANSIBLE_CONFIG="${PROJECT_ROOT}/ansible/ansible.cfg" \
    ansible-playbook -i "${PROJECT_ROOT}/ansible/inventory.ini" \
    "${PROJECT_ROOT}/ansible/playbooks/teardown.yml"; then
    pass "ansible-playbook teardown.yml による停止処理完了"
  else
    fail "ansible-playbook teardown.yml による停止処理失敗"
    STOP_FAILED=true
  fi
else
  if ./stop.sh; then
    pass "stop.sh による停止処理完了"
  else
    fail "stop.sh による停止処理失敗"
    STOP_FAILED=true
  fi
fi

if [[ "$STOP_FAILED" == true ]]; then
  echo ""
  echo -e "${BOLD}======================================================${RESET}"
  echo -e "${BOLD}全体テスト (E2E) 結果: ${GREEN}${PASS_COUNT} PASSED${RESET}, ${RED}${FAIL_COUNT} FAILED${RESET}"
  echo -e "${BOLD}======================================================${RESET}"
  exit 1
fi

info "E2E Step 5: 停止後検証 (images.txt 更新 & Podman キャッシュ & クリーンアップ)"

# 1. images.txt の更新時刻確認
if [[ -f "images.txt" ]]; then
  FILE_MOD_TIME=$(stat -c %Y images.txt 2>/dev/null || stat -f %m images.txt)
  if [[ $FILE_MOD_TIME -ge $BEFORE_STOP_TIME ]]; then
    pass "images.txt: stop.sh 実行時に自動更新されたことを確認"
  else
    fail "images.txt: 更新時刻が停止処理前です"
  fi
else
  fail "images.txt が見つかりません"
fi

# 2. Podman にイメージが保存されているか確認
if command -v podman &>/dev/null; then
  CACHED_COUNT=$(sudo podman images --format "{{.Repository}}:{{.Tag}}" | grep -E "rancher|keycloak|lemonade|open-webui" | wc -l || true)
  if [[ $CACHED_COUNT -gt 0 ]]; then
    pass "Podman キャッシュ保存確認: ${CACHED_COUNT} 個のクラスタ関連イメージを確認"
  else
    fail "Podman キャッシュ保存確認: 関連イメージが見つかりません"
  fi
fi

# 3. K3D クラスタ完全削除確認
CLUSTER_TARGET="${CLUSTER_NAME:-ollama-cluster}"
REMAINING_CLUSTERS=$(sudo k3d cluster list --no-headers 2>/dev/null | grep "$CLUSTER_TARGET" | wc -l || true)
if [[ $REMAINING_CLUSTERS -eq 0 ]]; then
  pass "K3D クラスタ完全クリーンアップ確認"
else
  fail "K3D クラスタが残存しています (${REMAINING_CLUSTERS} 個)"
fi

echo ""
echo -e "${BOLD}======================================================${RESET}"
echo -e "${BOLD}全体テスト (E2E) 結果: ${GREEN}${PASS_COUNT} PASSED${RESET}, ${RED}${FAIL_COUNT} FAILED${RESET}"
echo -e "${BOLD}======================================================${RESET}"
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
