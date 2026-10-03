#!/usr/bin/env bash
# ==============================================================================
# 共通シェル関数ライブラリ
# start.sh / stop.sh 等で共有するログ・ユーティリティ
# ==============================================================================

# ログ出力
log() { echo -e "\033[36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
succ() { echo -e "\033[32m[SUCCESS]\033[0m $*"; }

# 依存コマンドが存在しない場合に自動インストールを試みる
ensure_command() {
  local cmd="$1"
  local pkg="${2:-$1}"
  if command -v "$cmd" &>/dev/null; then
    return 0
  fi
  warn "'$cmd' がインストールされていません。自動インストールを試みます..."
  if command -v dnf &>/dev/null; then
    sudo dnf install -y "$pkg" 2>/dev/null && return 0
  elif command -v yum &>/dev/null; then
    sudo yum install -y "$pkg" 2>/dev/null && return 0
  elif command -v apt &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y "$pkg" 2>/dev/null && return 0
  elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm "$pkg" 2>/dev/null && return 0
  elif command -v brew &>/dev/null; then
    brew install "$pkg" 2>/dev/null && return 0
  fi
  err "'$cmd' の自動インストールに失敗しました。手動でインストールしてください。"
  return 1
}

# バージョン比較関数 (バージョン $1 >= $2 なら 0, 未満なら 1)
version_ge() {
  local v1="${1#v}"
  local v2="${2#v}"
  [[ "$v1" == "$v2" ]] && return 0
  local lowest
  lowest=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)
  [[ "$lowest" == "$v2" ]]
}

# システムアーキテクチャ検出関数 (amd64 / arm64)
get_system_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "" ;;
  esac
}

# kubectl の最新バージョン確認および自動ダウンロード・インストール
ensure_latest_kubectl() {
  local arch
  arch=$(get_system_arch)
  if [[ -z "$arch" ]]; then
    warn "未対応の CPU アーキテクチャです ($(uname -m)) - kubectl の自動更新をスキップします"
    return 0
  fi

  local cur_ver=""
  if command -v kubectl &>/dev/null; then
    cur_ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null || true)
    if [[ -z "$cur_ver" ]]; then
      cur_ver=$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
  fi

  log "kubectl の最新安定版バージョンを確認中..."
  local latest_ver
  latest_ver=$(curl -fsSL --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_MAX_TIME:-10}" "${DL_K8S_RELEASE_BASE_URL:-https://dl.k8s.io}/release/stable.txt" 2>/dev/null | tr -d ' \n\r' || true)

  if [[ -z "$latest_ver" ]]; then
    if [[ -n "$cur_ver" ]]; then
      warn "kubectl の最新バージョン取得に失敗しました。現在のバージョン (${cur_ver}) を維持します"
      return 0
    else
      err "kubectl の最新バージョン取得に失敗し、既存のインストールもありません"
      return 1
    fi
  fi

  if [[ -n "$cur_ver" ]] && version_ge "$cur_ver" "$latest_ver"; then
    log "kubectl は既に最新バージョンです (${cur_ver})"
    return 0
  fi

  log "kubectl を最新版 (${latest_ver}) にダウンロード・インストール中 (現在: ${cur_ver:-未インストール})..."
  local tmp_bin
  tmp_bin=$(mktemp /tmp/kubectl-XXXXXX)
  if ! curl -fsSL --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_DOWNLOAD_MAX_TIME:-60}" "${DL_K8S_RELEASE_BASE_URL:-https://dl.k8s.io}/release/${latest_ver}/bin/linux/${arch}/kubectl" -o "$tmp_bin"; then
    rm -f "$tmp_bin"
    if [[ -n "$cur_ver" ]]; then
      warn "kubectl のダウンロードに失敗しました。現在のバージョン (${cur_ver}) を維持します"
      return 0
    fi
    err "kubectl のダウンロードに失敗しました"
    return 1
  fi
  chmod +x "$tmp_bin"

  if ! "$tmp_bin" version --client >/dev/null 2>&1; then
    rm -f "$tmp_bin"
    err "ダウンロードした kubectl バイナリの検証に失敗しました"
    return 1
  fi

  local sudo_cmd=""
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo_cmd="sudo"
  fi

  local install_path
  install_path=$(command -v kubectl 2>/dev/null || echo "/usr/local/bin/kubectl")
  $sudo_cmd install -m 0755 "$tmp_bin" "$install_path"
  rm -f "$tmp_bin"

  succ "kubectl を最新版 (${latest_ver}) に更新しました (${install_path})"
}

# helm の最新バージョン確認および自動ダウンロード・インストール
ensure_latest_helm() {
  local arch
  arch=$(get_system_arch)
  if [[ -z "$arch" ]]; then
    warn "未対応の CPU アーキテクチャです ($(uname -m)) - helm の自動更新をスキップします"
    return 0
  fi

  local cur_ver=""
  if command -v helm &>/dev/null; then
    cur_ver=$(helm version --template='{{.Version}}' 2>/dev/null || true)
    if [[ -z "$cur_ver" ]]; then
      cur_ver=$(helm version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
  fi

  log "helm の最新安定版バージョンを確認中..."
  local latest_ver
  latest_ver=$(curl -fsSLI -o /dev/null -w "%{url_effective}" --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_MAX_TIME:-10}" "${GITHUB_BASE_URL:-https://github.com}/helm/helm/releases/latest" 2>/dev/null | sed 's|.*/tag/||' | tr -d ' \n\r' || true)

  if [[ -z "$latest_ver" || "$latest_ver" == "latest" ]]; then
    latest_ver=$(curl -fsSL --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_MAX_TIME:-10}" "${GITHUB_API_URL:-https://api.github.com}/repos/helm/helm/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | tr -d ' \n\r' || true)
  fi

  if [[ -z "$latest_ver" ]]; then
    if [[ -n "$cur_ver" ]]; then
      warn "helm の最新バージョン取得に失敗しました。現在のバージョン (${cur_ver}) を維持します"
      return 0
    else
      err "helm の最新バージョン取得に失敗し、既存のインストールもありません"
      return 1
    fi
  fi

  if [[ -n "$cur_ver" ]] && version_ge "$cur_ver" "$latest_ver"; then
    log "helm は既に最新バージョンです (${cur_ver})"
    return 0
  fi

  log "helm を最新版 (${latest_ver}) にダウンロード・インストール中 (現在: ${cur_ver:-未インストール})..."
  local tmp_dir
  tmp_dir=$(mktemp -d /tmp/helm-XXXXXX)
  if ! curl -fsSL --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_DOWNLOAD_MAX_TIME:-60}" "${HELM_DOWNLOAD_BASE_URL:-https://get.helm.sh}/helm-${latest_ver}-linux-${arch}.tar.gz" | tar -xz -C "$tmp_dir" 2>/dev/null; then
    rm -rf "$tmp_dir"
    if [[ -n "$cur_ver" ]]; then
      warn "helm のダウンロードに失敗しました。現在のバージョン (${cur_ver}) を維持します"
      return 0
    fi
    err "helm のダウンロードに失敗しました"
    return 1
  fi

  if [[ ! -f "${tmp_dir}/linux-${arch}/helm" ]]; then
    rm -rf "$tmp_dir"
    err "展開されたアーカイブ内に helm バイナリが見つかりません"
    return 1
  fi

  local sudo_cmd=""
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo_cmd="sudo"
  fi

  local install_path
  install_path=$(command -v helm 2>/dev/null || echo "/usr/local/bin/helm")
  $sudo_cmd install -m 0755 "${tmp_dir}/linux-${arch}/helm" "$install_path"
  rm -rf "$tmp_dir"

  succ "helm を最新版 (${latest_ver}) に更新しました (${install_path})"
}

