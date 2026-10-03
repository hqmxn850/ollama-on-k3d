#!/usr/bin/env bash
# ==============================================================================
# trust-ca.sh - K3D クラスタのルート CA 証明書をホスト OS に自動信頼登録 / 削除するスクリプト
#
# 対応 OS:
#   - Fedora / RHEL / CentOS / Rocky Linux / AlmaLinux
#   - Ubuntu / Debian
#   - Arch Linux / openSUSE
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

show_help() {
  cat << EOF
使用方法: $(basename "$0") [オプション]

K3D クラスタのルート CA 証明書をホスト OS のシステム CA トラストストアに自動登録 / 削除するスクリプト

オプション:
  -i, --insert, --add    ルート CA 証明書を抽出してシステムトラストストアに登録 (デフォルト)
  -d, --delete, --remove 登録済みのルート CA 証明書をシステムトラストストアから削除
  -h, --help             このヘルプメッセージを表示
EOF
}

MODE="insert"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      exit 0
      ;;
    -i|--insert|--add)
      MODE="insert"
      ;;
    -d|--delete|--remove)
      MODE="delete"
      ;;
    *)
      err "未知のオプション: $arg"
      show_help
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 削除 (delete) モード
# ------------------------------------------------------------------------------
delete_ca() {
  log "=========================================================="
  log " K3D クラスタ ルート CA 証明書 システム信頼登録解除 (delete)"
  log "=========================================================="

  local deleted=0

  # 1. Fedora / RHEL / CentOS
  if [[ -d "/etc/pki/ca-trust/source/anchors" ]]; then
    log "OS 種別: Fedora / RHEL 系を検出しました。"
    if [[ -f "/etc/pki/ca-trust/source/anchors/k3d-internal-root-ca.crt" ]] || [[ -f "/etc/pki/ca-trust/source/anchors/k3d-rancher-ca.crt" ]]; then
      log "登録済みの K3D ルート CA 証明書を削除中..."
      sudo rm -f /etc/pki/ca-trust/source/anchors/k3d-internal-root-ca.crt /etc/pki/ca-trust/source/anchors/k3d-rancher-ca.crt
      deleted=1
    fi
    if [[ $deleted -eq 1 ]]; then
      log "システム CA トラストストアを更新中 (update-ca-trust)..."
      sudo update-ca-trust
      succ "ルート CA 証明書の登録解除が完了しました。"
    else
      log "登録済みの K3D ルート CA 証明書は見つかりませんでした (削除不要)。"
    fi

  # 2. Ubuntu / Debian
  elif [[ -d "/usr/local/share/ca-certificates" ]]; then
    log "OS 種別: Debian / Ubuntu 系を検出しました。"
    if [[ -f "/usr/local/share/ca-certificates/k3d-internal-root-ca.crt" ]] || [[ -f "/usr/local/share/ca-certificates/k3d-rancher-ca.crt" ]]; then
      log "登録済みの K3D ルート CA 証明書を削除中..."
      sudo rm -f /usr/local/share/ca-certificates/k3d-internal-root-ca.crt /usr/local/share/ca-certificates/k3d-rancher-ca.crt
      deleted=1
    fi
    if [[ $deleted -eq 1 ]]; then
      log "システム CA トラストストアを更新中 (update-ca-certificates)..."
      sudo update-ca-certificates --fresh 2>/dev/null || sudo update-ca-certificates
      succ "ルート CA 証明書の登録解除が完了しました。"
    else
      log "登録済みの K3D ルート CA 証明書は見つかりませんでした (削除不要)。"
    fi

  # 3. Arch Linux
  elif [[ -d "/etc/ca-certificates/trust-source/anchors" ]]; then
    log "OS 種別: Arch Linux 系を検出しました。"
    if [[ -f "/etc/ca-certificates/trust-source/anchors/k3d-internal-root-ca.crt" ]] || [[ -f "/etc/ca-certificates/trust-source/anchors/k3d-rancher-ca.crt" ]]; then
      log "登録済みの K3D ルート CA 証明書を削除中..."
      sudo rm -f /etc/ca-certificates/trust-source/anchors/k3d-internal-root-ca.crt /etc/ca-certificates/trust-source/anchors/k3d-rancher-ca.crt
      deleted=1
    fi
    if [[ $deleted -eq 1 ]]; then
      log "システム CA トラストストアを更新中 (trust extract-compat)..."
      sudo trust extract-compat
      succ "ルート CA 証明書の登録解除が完了しました。"
    else
      log "登録済みの K3D ルート CA 証明書は見つかりませんでした (削除不要)。"
    fi

  else
    warn "対応する CA トラストディレクトリが見つかりませんでした。"
  fi
}

# ------------------------------------------------------------------------------
# 登録 (insert) モード
# ------------------------------------------------------------------------------
insert_ca() {
  log "=========================================================="
  log " K3D クラスタ ルート CA 証明書 システム信頼登録 (insert)"
  log "=========================================================="

  if ! kubectl cluster-info &>/dev/null; then
    err "エラー: Kubernetes クラスタに接続できません。クラスタが起動しているか確認してください。"
    exit 1
  fi

  TMP_DIR=$(mktemp -d /tmp/k3d-ca-XXXXXX)
  trap '[[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}"' EXIT

  # 1. cert-manager internal-root-ca の抽出 (Keycloak, pgAdmin, Grafana 等の内部 TLS サービス用)
  log "cert-manager の内部ルート CA 証明書を抽出中..."
  kubectl get secret -n cert-manager internal-root-ca-secret -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "${TMP_DIR}/k3d-internal-root-ca.crt" || true

  # 2. Rancher dynamiclistener CA の抽出 (Rancher 用)
  log "Rancher のルート CA 証明書を抽出中..."
  kubectl get secret -n cattle-system tls-rancher-ingress -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "${TMP_DIR}/k3d-rancher-ca.crt" || true

  if [[ ! -s "${TMP_DIR}/k3d-internal-root-ca.crt" && ! -s "${TMP_DIR}/k3d-rancher-ca.crt" ]]; then
    err "エラー: クラスタからルート CA 証明書を抽出できませんでした。"
    exit 1
  fi

  # 3. OS 判別 & トラストストアへ配置 (差分検知付き)
  local target_dir=""
  local update_cmd=""

  if [[ -d "/etc/pki/ca-trust/source/anchors" ]]; then
    # Fedora / RHEL / CentOS
    log "OS 種別: Fedora / RHEL 系を検出しました。"
    target_dir="/etc/pki/ca-trust/source/anchors"
    update_cmd="sudo update-ca-trust"

  elif [[ -d "/usr/local/share/ca-certificates" ]]; then
    # Ubuntu / Debian
    log "OS 種別: Debian / Ubuntu 系を検出しました。"
    target_dir="/usr/local/share/ca-certificates"
    update_cmd="sudo update-ca-certificates"

  elif [[ -d "/etc/ca-certificates/trust-source/anchors" ]]; then
    # Arch Linux
    log "OS 種別: Arch Linux 系を検出しました。"
    target_dir="/etc/ca-certificates/trust-source/anchors"
    update_cmd="sudo trust extract-compat"

  else
    warn "自動対応している CA トラストディレクトリが見つかりませんでした。"
    log "抽出した証明書をカレントディレクトリに保存しました:"
    [[ -s "${TMP_DIR}/k3d-internal-root-ca.crt" ]] && cp "${TMP_DIR}/k3d-internal-root-ca.crt" ./k3d-internal-root-ca.crt && echo "  - ./k3d-internal-root-ca.crt"
    [[ -s "${TMP_DIR}/k3d-rancher-ca.crt" ]] && cp "${TMP_DIR}/k3d-rancher-ca.crt" ./k3d-rancher-ca.crt && echo "  - ./k3d-rancher-ca.crt"
    log "手動でブラウザまたは OS の証明書ストアにインポートしてください。"
    return 0
  fi

  local need_update=0
  for ca_name in "k3d-internal-root-ca.crt" "k3d-rancher-ca.crt"; do
    local src="${TMP_DIR}/${ca_name}"
    local dst="${target_dir}/${ca_name}"

    if [[ -s "$src" ]]; then
      if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        log "  - ${ca_name}: 既に同一の証明書が登録されています (変更なし)"
      else
        if [[ -f "$dst" ]]; then
          log "  - ${ca_name}: 既存の証明書と差異があるため更新します (上書き)"
        else
          log "  - ${ca_name}: 新規登録します"
        fi
        sudo cp "$src" "$dst"
        need_update=1
      fi
    fi
  done

  echo ""
  log "=========================================================="
  if [[ $need_update -eq 1 ]]; then
    log "システム CA トラストストアを更新中 (${update_cmd})..."
    $update_cmd
    succ " ルート CA 証明書の登録・更新が完了しました！"
    echo "反映のため、起動中の Google Chrome などのブラウザを一度完全に終了・再起動してください。"
  else
    succ " すべてのルート CA 証明書は既に登録済み（最新）です (更新不要)。"
  fi
  log "=========================================================="
  return 0
}

# 実行
if [[ "$MODE" == "delete" ]]; then
  delete_ca
else
  insert_ca
fi
