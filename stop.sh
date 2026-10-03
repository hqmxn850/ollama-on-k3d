#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory.ini"
PLAYBOOK="${ANSIBLE_DIR}/playbooks/teardown.yml"
export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"
export ANSIBLE_HOME="${ANSIBLE_DIR}/.ansible"

# 共通関数 (log/warn/err/ensure_command) を読み込み
source "${SCRIPT_DIR}/lib/common.sh"

DEFAULT_EMAIL_DOMAIN="philippines.com.ph"

show_help() {
  cat << EOF
使用方法: $(basename "$0") [オプション...] [ansible-playbook オプション...]

Ollama on K3D クラスタ停止・クリーンアップ スクリプト (Ansible 版)

このスクリプトは 'config.env' を読み込み、設定値を Ansible 変数に変換して
Ansible Playbook ('ansible/playbooks/teardown.yml') を実行します。
停止前に実行中イメージの一覧更新 ('images.txt') および Podman へのイメージ保存を実施し、
ホスト OS に信頼登録された K3D ルート CA 証明書の削除 ('./trust-ca.sh --delete') を行い、
その後 K3D クラスタ、関連コンテナ、ボリューム、ネットワーク、dnsmasq 設定を削除します。

主なオプション例:
  --skip-save-images イメージ保存・一覧更新処理をスキップして高速停止
  --check, -C, --dry-run ドライラン (変更を行わずに実行内容を確認、イメージ保存もスキップ)
  -v, -vv, -vvv      Ansible 詳細ログ出力
  -h, --help         このヘルプメッセージを表示
EOF
}

SKIP_SAVE_IMAGES=0
IS_DRY_RUN=0
ANSIBLE_ARGS=()

# オプションの解析
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      exit 0
      ;;
    --skip-save-images)
      SKIP_SAVE_IMAGES=1
      ;;
    --check|-C|--dry-run)
      IS_DRY_RUN=1
      ANSIBLE_ARGS+=("--check")
      ;;
    *)
      ANSIBLE_ARGS+=("$arg")
      ;;
  esac
done

# --- 0. 前提条件チェック ---
ensure_command ansible-playbook ansible || exit 1
ensure_command jq jq || exit 1
ensure_command podman podman || exit 1

if [[ ! -f "$CONFIG_ENV" ]]; then
  err "設定ファイルが見つかりません: $CONFIG_ENV"
  exit 1
fi

# --- 1. config.env の読み込み ---
log "config.env を読み込み中..."
set -a
source "$CONFIG_ENV"
set +a

# --- 2. クラスタイメージの Podman 保存・一覧更新 ---
SAVE_IMAGES_SCRIPT="${ANSIBLE_DIR}/roles/cluster_teardown/files/save-images.sh"
IMAGES_FILE="${SCRIPT_DIR}/images.txt"

if [[ "$IS_DRY_RUN" == "1" ]]; then
  log "ドライラン (--check) のため、イメージ保存処理をスキップします"
  export _SAVED_IMAGES_DONE=1
elif [[ "$SKIP_SAVE_IMAGES" == "1" ]]; then
  log "--skip-save-images が指定されたため、イメージ保存処理をスキップします"
  export _SAVED_IMAGES_DONE=1
elif [[ -x "$SAVE_IMAGES_SCRIPT" ]]; then
  log "クラスタのイメージを podman に保存・一覧更新中..."
  if ! "$SAVE_IMAGES_SCRIPT" "$IMAGES_FILE"; then
    warn "イメージの保存中に警告が発生しましたが、停止処理を継続します"
  fi
  export _SAVED_IMAGES_DONE=1
fi

# --- 3. ホスト OS からの K3D ルート CA 証明書の登録解除 ---
TRUST_CA_SCRIPT="${SCRIPT_DIR}/trust-ca.sh"
if [[ "$IS_DRY_RUN" == "1" ]]; then
  log "ドライラン (--check) のため、ルート CA 証明書の登録解除処理をスキップします"
elif [[ -x "$TRUST_CA_SCRIPT" ]]; then
  log "ホスト OS から K3D ルート CA 証明書の登録を解除中..."
  if ! "$TRUST_CA_SCRIPT" --delete; then
    warn "ルート CA 証明書の登録解除中に警告が発生しましたが、停止処理を継続します"
  fi
fi

# --- 4. Ansible 向け extra-vars (JSON) 生成 ---
# 実ユーザーのホームディレクトリを確実に特定 (sudo 実行時対応)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  ACTUAL_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "/home/${SUDO_USER}")
else
  ACTUAL_USER_HOME="${HOME:-/home/$(whoami)}"
fi

EXTRA_VARS=$(jq -n \
  --arg cluster_name "${CLUSTER_NAME:-ollama-cluster}" \
  --arg podman_network "${NETWORK:-k3d}" \
  --arg rancher_hostname "${RANCHER_HOSTNAME:-rancher.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --arg user_home "${ACTUAL_USER_HOME}" \
  '{
    cluster_name: $cluster_name,
    podman_network: $podman_network,
    rancher_hostname: $rancher_hostname,
    user_home: $user_home
  }')

# --- 5. Ansible Playbook 実行 ---
log "Ansible Playbook を開始します (クラスタ停止): ${PLAYBOOK}"
cd "${ANSIBLE_DIR}"
ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" -e "${EXTRA_VARS}" "${ANSIBLE_ARGS[@]}"
playbook_rc=$?

# --- 6. 未使用ボリュームとキャッシュのクリーンアップ ---
if [[ "$IS_DRY_RUN" == "1" ]]; then
  log "ドライラン (--check) のため、Podman ボリュームのクリーンアップ処理をスキップします"
else
  log "未使用の Podman ボリュームをクリーンアップ中 (podman volume prune -f)..."
  sudo podman volume prune -f 2>/dev/null || podman volume prune -f 2>/dev/null || true
  rm -rf "${ACTUAL_USER_HOME}/.kube/cache/http/"* 2>/dev/null || true
  log "kubectl HTTP キャッシュ (${ACTUAL_USER_HOME}/.kube/cache/http) を削除しました"
fi
exit "${playbook_rc}"
