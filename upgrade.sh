#!/usr/bin/env bash
# ==============================================================================
# upgrade.sh - K3D on Podman 自動アップグレードスクリプト
#
# 機能:
#   1. Kubernetes (K3s) の最新安定版を検索しアップグレード
#   2. 各種 Helm Chart の最新版を検索しアップグレード
#   3. 主要コンテナイメージの最新版を取得し反映
#   4. 現状バージョンと更新後バージョンのサマリーをコンソールに表示
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
VERSIONS_ENV="${SCRIPT_DIR}/versions.env"
IMAGES_TXT="${SCRIPT_DIR}/images.txt"

# 共通関数 (log/warn/err/ensure_latest_kubectl/ensure_latest_helm) を読み込み
source "${SCRIPT_DIR}/lib/common.sh"

DEFAULT_EMAIL_DOMAIN="philippines.com.ph"

# --- カラー定義 ---
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m" # No Color

title() { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

# 依存コマンドの存在確認
require_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    err "'$cmd' がインストールされていません。手動でインストールしてください。"
    return 1
  fi
}


# --- オプション初期値 ---
CHECK_ONLY=false
AUTO_YES=false
K8S_ONLY=false
CHARTS_ONLY=false
IMAGES_ONLY=false
PRUNE_IMAGES=false

# --- ヘルプ表示 ---
show_help() {
  cat << HELP_MSG
使用法: $0 [OPTIONS]

K3D クラスタ環境の Kubernetes (K3s)、Helm Chart、コンテナイメージの最新版を検索・アップグレードします。

オプション:
  -c, --check, --dry-run  アップグレードを実行せず、最新バージョンの検出と差分確認のみを行う
  -y, --yes               確認プロンプトをスキップし、自動的にアップグレードを実行
  --k8s-only              Kubernetes (K3s) のみアップグレード
  --charts-only           Helm チャートのみアップグレード
  --images-only           コンテナイメージのみアップグレード
  --prune-images          Podman のダンangling/未使用イメージを整理 (コンテナから参照されていないイメージを削除)
  -h, --help              このヘルプメッセージを表示

例:
  $0                      # 対話形式で全コンポーネントを最新版へアップグレード
  $0 --check              # アップグレード可否・バージョンの確認のみ（ドライラン）
  $0 -y                   # 確認なしで全コンポーネントを即時アップグレード
  $0 --charts-only        # Helm チャートのみ最新版へアップグレード
  $0 --prune-images       # Podman イメージを整理 (ダンangling + 未使用削除)
HELP_MSG
}

# --- 引数解析 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--check|--dry-run)
      CHECK_ONLY=true
      shift
      ;;
    -y|--yes)
      AUTO_YES=true
      shift
      ;;
    --k8s-only)
      K8S_ONLY=true
      shift
      ;;
    --charts-only)
      CHARTS_ONLY=true
      shift
      ;;
    --images-only)
      IMAGES_ONLY=true
      shift
      ;;
    --prune-images)
      PRUNE_IMAGES=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      err "未知のオプション: $1"
      show_help
      exit 1
      ;;
  esac
done

# --- 0. 前提条件チェック & CLI ツール最新化 ---
title "前提条件チェック & CLI ツール確認"

ensure_command jq jq || exit 1
ensure_command curl curl || exit 1
ensure_command podman podman || exit 1
ensure_latest_kubectl || exit 1
ensure_latest_helm || exit 1


if ! kubectl cluster-info &>/dev/null; then
  err "Kubernetes クラスタに接続できません。クラスタが起動しているか確認してください。"
  exit 1
fi

if [[ -f "$CONFIG_ENV" ]]; then
  source "$CONFIG_ENV"
fi

log "Kubernetes クラスタ接続確認: OK"

# --- 結果記録用配列 ---
# 各要素: "コンポーネント名|カテゴリ|変更前バージョン|最新/変更後バージョン|ステータス"
SUMMARY_RESULTS=()
declare -A DETECTED_CHART_VERSIONS=()

# ==============================================================================
# 1. Kubernetes (K3s) バージョン確認 & アップグレード
# ==============================================================================
if [[ "$CHARTS_ONLY" == false && "$IMAGES_ONLY" == false ]]; then
  title "1. Kubernetes (K3s) バージョン確認"

  CURRENT_K8S=$(kubectl get nodes -o jsonpath="{.items[0].status.nodeInfo.kubeletVersion}" 2>/dev/null || echo "Unknown")
  log "現在の Kubernetes バージョン: ${CURRENT_K8S}"

  log "K3s の最新安定版タグを Docker Hub より検索中 (Rancher 互換性チェック付き)..."
  # Rancher の kubeVersion 制約 (例: "< 1.37.0-0") を取得して適合する K3s バージョンのみを抽出
  RANCHER_KUBE_CONSTRAINT=$(helm show chart rancher-stable/rancher 2>/dev/null | grep -i '^kubeVersion:' | sed -E 's/.*<[[:space:]]*([0-9]+\.[0-9]+).*/\1/' || true)
  if [[ -n "$RANCHER_KUBE_CONSTRAINT" ]]; then
    MAX_MAJOR=$(echo "$RANCHER_KUBE_CONSTRAINT" | cut -d. -f1)
    MAX_MINOR=$(echo "$RANCHER_KUBE_CONSTRAINT" | cut -d. -f2)
    TARGET_MINOR=$((MAX_MINOR - 1))
    K3S_FILTER_REGEX="^v${MAX_MAJOR}\.${TARGET_MINOR}\.[0-9]+-k3s1$"
  else
    K3S_FILTER_REGEX="^v1\.36\.[0-9]+-k3s1$"
  fi

  LATEST_K8S_TAG=$(curl -s --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_MAX_TIME:-10}" "${DOCKER_HUB_API_URL:-https://hub.docker.com/v2}/repositories/rancher/k3s/tags/?page_size=100&ordering=last_updated" 2>/dev/null \
    | jq -r ".results[].name // empty" 2>/dev/null \
    | grep -E "$K3S_FILTER_REGEX" \
    | sort -V \
    | tail -1 || true)

  if [[ -z "$LATEST_K8S_TAG" ]]; then
    warn "K3s 最新版の取得に失敗しました。現在のバージョンを維持します。"
    LATEST_K8S="${CURRENT_K8S}"
    K8S_STATUS="Up to date"
  else
    # タグ形式 (v1.36.4-k3s1) をバージョン形式 (v1.36.4+k3s1) に正規化
    LATEST_K8S="${LATEST_K8S_TAG/-/+}"
    if [[ "${CURRENT_K8S}" == "${LATEST_K8S}" ]]; then
      log "Kubernetes は既に最新版です (${CURRENT_K8S})"
      K8S_STATUS="Up to date"
    else
      log "新しい Kubernetes バージョンが見つかりました: ${CURRENT_K8S} -> ${LATEST_K8S}"
      K8S_STATUS="Upgrade available"
    fi
  fi

  if [[ "$CHECK_ONLY" == false && "$K8S_STATUS" == "Upgrade available" ]]; then
    if [[ "$AUTO_YES" == false ]]; then
      read -rp "Kubernetes (K3s) を ${CURRENT_K8S} から ${LATEST_K8S} へアップグレードしますか? [y/N]: " confirm
      if [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        DO_K8S_UPGRADE=true
      else
        DO_K8S_UPGRADE=false
      fi
    else
      DO_K8S_UPGRADE=true
    fi

    if [[ "$DO_K8S_UPGRADE" == true ]]; then
      # system-upgrade-controller の存在確認 (未インストールの場合は自動導入)
      if ! kubectl get crd plans.upgrade.cattle.io &>/dev/null; then
        log "system-upgrade-controller が未検出のため、自動インストール中..."
        kubectl apply -f "${GITHUB_BASE_URL:-https://github.com}/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml" >/dev/null 2>&1 || true
        kubectl rollout status deployment/system-upgrade-controller -n "${RANCHER_NAMESPACE:-cattle-system}" --timeout="${DEFAULT_ROLLOUT_TIMEOUT:-300s}" >/dev/null 2>&1 || true
      fi

      log "K3s アップグレードプランを適用中 (system-upgrade-controller)..."
      kubectl apply -f - <<PLAN_EOF
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-server-upgrade
  namespace: ${RANCHER_NAMESPACE:-cattle-system}
spec:
  concurrency: 1
  version: ${LATEST_K8S}
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
  serviceAccountName: system-upgrade-controller
  upgrade:
    image: rancher/k3s-upgrade
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-agent-upgrade
  namespace: ${RANCHER_NAMESPACE:-cattle-system}
spec:
  concurrency: 1
  version: ${LATEST_K8S}
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  serviceAccountName: system-upgrade-controller
  upgrade:
    image: rancher/k3s-upgrade
PLAN_EOF
      log "ノードのアップグレード完了を待機中..."
      sleep "${DEFAULT_RETRY_DELAY:-5}"
      wait_ok=false
      for attempt in 1 2 3; do
        if kubectl wait --for=condition=Ready nodes --all --timeout="${NODE_READY_TIMEOUT:-300s}" 2>/dev/null; then
          wait_ok=true
          break
        fi
        warn "  -> 待機タイムアウト (試行 ${attempt}/3)。再試行します..."
        sleep 10
      done
      if [[ "$wait_ok" == false ]]; then
        warn "  -> ノードの Ready 待機がタイムアウトしました。手動で確認してください。"
      fi
      NEW_K8S=$(kubectl get nodes -o jsonpath="{.items[0].status.nodeInfo.kubeletVersion}" 2>/dev/null || echo "$LATEST_K8S")
      K8S_STATUS="Upgraded"
      SUMMARY_RESULTS+=("Kubernetes (K3s)|K8s Cluster|${CURRENT_K8S}|${NEW_K8S}|${K8S_STATUS}")
    else
      SUMMARY_RESULTS+=("Kubernetes (K3s)|K8s Cluster|${CURRENT_K8S}|${CURRENT_K8S}|Skipped")
    fi
  else
    SUMMARY_RESULTS+=("Kubernetes (K3s)|K8s Cluster|${CURRENT_K8S}|${LATEST_K8S}|${K8S_STATUS}")
  fi
fi

# ==============================================================================
# 2. Helm Chart バージョン確認 & アップグレード
# ==============================================================================
if [[ "$K8S_ONLY" == false && "$IMAGES_ONLY" == false ]]; then
  title "2. Helm Chart バージョン確認 & リポジトリ更新"

  # 依存 Helm リポジトリ定義 (group_vars/all.yml と共通化)
  declare -A HELM_REPOS=(
    ["jetstack"]="${HELM_REPO_JETSTACK:-https://charts.jetstack.io}"
    ["bitnami"]="${HELM_REPO_BITNAMI:-https://charts.bitnami.com/bitnami}"
    ["helmforge"]="${HELM_REPO_HELMFORGE:-https://repo.helmforge.dev}"
    ["rancher-stable"]="${HELM_REPO_RANCHER_STABLE:-https://releases.rancher.com/server-charts/stable}"
    ["prometheus-community"]="${HELM_REPO_PROMETHEUS_COMMUNITY:-https://prometheus-community.github.io/helm-charts}"
    ["rancher-charts"]="${HELM_REPO_RANCHER_CHARTS:-https://charts.rancher.io}"
    ["amd-gpu-helm"]="${HELM_REPO_AMD_GPU_HELM:-https://rocm.github.io/k8s-device-plugin/}"
    ["open-webui"]="${HELM_REPO_OPEN_WEBUI:-https://helm.openwebui.com/}"
  )


  # 依存 Helm リポジトリの確認 & 追加・最新インデックス取得
  repos_to_update=()
  for r_name in "${!HELM_REPOS[@]}"; do
    r_url="${HELM_REPOS[$r_name]}"
    if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$r_name"; then
      current=$(helm repo list 2>/dev/null | awk -v n="$r_name" '$1==n {print $2}')
      if [ "$current" != "$r_url" ]; then
        helm repo remove "$r_name" >/dev/null 2>&1 || true
        helm repo add "$r_name" "$r_url" >/dev/null 2>&1 || true
      fi
    else
      helm repo add "$r_name" "$r_url" >/dev/null 2>&1 || true
    fi
    repos_to_update+=("$r_name")
  done

  if [ ${#repos_to_update[@]} -gt 0 ]; then
    log "Helm リポジトリを更新中 (${repos_to_update[*]})..."
    helm repo update "${repos_to_update[@]}" >/dev/null 2>&1 || true
  fi

  # アップグレード対象 Helm リリース定義
  # 形式: "Release名|Namespace|ChartRepo名"
  HELM_TARGETS=(
    "cert-manager|cert-manager|jetstack/cert-manager"
    "keycloak-pg|keycloak|bitnami/postgresql"
    "keycloak|keycloak|helmforge/keycloak"
    "rancher|cattle-system|rancher-stable/rancher"
    "kube-prometheus-stack|cattle-monitoring-system|prometheus-community/kube-prometheus-stack"
    "rancher-monitoring-dashboards|cattle-monitoring-system|rancher-charts/rancher-monitoring-dashboards"
    "amd-gpu|kube-system|amd-gpu-helm/amd-gpu"
    "open-webui|open-webui|open-webui/open-webui"
  )


  # 全 Helm リリース情報を JSON で一括取得
  ALL_RELEASES_JSON=$(helm list -A -o json 2>/dev/null || echo "[]")

  for target in "${HELM_TARGETS[@]}"; do
    IFS="|" read -r r_name r_ns r_chart <<< "$target"

    # 現在のインストール状況を取得
    rel_info=$(echo "$ALL_RELEASES_JSON" | jq -r --arg n "$r_name" --arg ns "$r_ns" ".[] | select(.name == \$n and .namespace == \$ns)")

    if [[ -z "$rel_info" ]]; then
      continue
    fi

    curr_chart=$(echo "$rel_info" | jq -r ".chart")
    curr_app=$(echo "$rel_info" | jq -r ".app_version // empty")
    curr_status=$(echo "$rel_info" | jq -r ".status")

    # リポジトリから最新チャート情報を検索
    latest_info=$(helm search repo "$r_chart" -o json 2>/dev/null | jq -r ".[0] // empty")
    if [[ -z "$latest_info" ]]; then
      latest_chart="$curr_chart"
      chart_status="Up to date"
    else
      latest_ver=$(echo "$latest_info" | jq -r ".version")
      DETECTED_CHART_VERSIONS["$r_name"]="$latest_ver"
      chart_basename="${r_chart##*/}"
      latest_chart="${chart_basename}-${latest_ver}"

      # チャートバージョンの比較
      if [[ "$curr_chart" == "$latest_chart" && "$curr_status" != "pending-upgrade" ]]; then
        chart_status="Up to date"
      else
        chart_status="Upgrade available"
      fi
    fi

    log "[Helm] ${r_name} (${r_ns}): 現在=${curr_chart} -> 最新=${latest_chart} [${chart_status}]"

    # アップグレード実行
    if [[ "$CHECK_ONLY" == false && "$chart_status" == "Upgrade available" ]]; then
      should_upgrade=true
      if [[ "$AUTO_YES" == false ]]; then
        read -rp "  -> ${r_name} を ${curr_chart} から ${latest_chart} へアップグレードしますか? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
          should_upgrade=false
        fi
      fi

      if [[ "$should_upgrade" == true ]]; then
        log "  -> ${r_name} をアップグレード中..."

        # pending-upgrade / failed 解除
        if [[ "$curr_status" == "pending-upgrade" || "$curr_status" == "failed" ]]; then
          last_secret=$(kubectl get secret -n "$r_ns" -l "owner=helm,name=${r_name}" -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
          if [[ -n "$last_secret" ]]; then
            kubectl delete secret -n "$r_ns" "$last_secret" >/dev/null 2>&1 || true
          fi
        fi

        # CRD の更新が必要な場合は適用 (例: cert-manager)
        if [[ "$r_name" == "cert-manager" ]]; then
          kubectl apply -f "${GITHUB_BASE_URL:-https://github.com}/cert-manager/cert-manager/releases/download/${latest_ver}/cert-manager.crds.yaml" >/dev/null 2>&1 || true
        fi

        # アップグレード試行 (新チャートのデフォルト値を反映しつつ既存 values を再利用)
        upgraded_ok=false
        helm_err=$(mktemp)
        upgrade_flags=(--namespace "$r_ns" --reset-then-reuse-values --force-conflicts --wait --timeout="${HELM_TIMEOUT:-15m}")
        if [[ "$r_name" == "keycloak-pg" ]]; then
          upgrade_flags+=(--set "global.defaultFips=restricted")
        fi

        if helm upgrade "$r_name" "$r_chart" "${upgrade_flags[@]}" 2>"$helm_err"; then
          upgraded_ok=true
        else
          warn "  -> 初期アップグレードに失敗: $(tail -1 "$helm_err")"
          # FIPS または必須パラメータ不足エラーの自動修復再試行
          extra_args=(--force-conflicts)
          if grep -qi "defaultFips\|fips" "$helm_err" || [[ "$r_name" == "keycloak-pg" ]]; then
            extra_args+=(--set "global.defaultFips=restricted")
          fi
          tmp_vals=$(mktemp)
          helm get values "$r_name" -n "$r_ns" > "$tmp_vals" 2>/dev/null || true
          if [[ -s "$tmp_vals" ]] && helm upgrade "$r_name" "$r_chart" --namespace "$r_ns" -f "$tmp_vals" "${extra_args[@]}" --wait --timeout="${HELM_TIMEOUT:-15m}" 2>"$helm_err"; then
            upgraded_ok=true
          elif helm upgrade "$r_name" "$r_chart" --namespace "$r_ns" --reuse-values "${extra_args[@]}" --wait --timeout="${HELM_TIMEOUT:-15m}" 2>"$helm_err"; then
            upgraded_ok=true
          else
            warn "  -> 再試行でも失敗: $(tail -1 "$helm_err")"
          fi
          rm -f "$tmp_vals"
        fi
        rm -f "$helm_err"

        if [[ "$upgraded_ok" == true ]]; then
          log "  -> ${r_name} のアップグレードが完了しました。"
          SUMMARY_RESULTS+=("${r_name}|Helm Chart|${curr_chart}|${latest_chart}|Upgraded")
        else
          warn "  -> ${r_name} のアップグレードに失敗しました (設定を確認してください)。"
          SUMMARY_RESULTS+=("${r_name}|Helm Chart|${curr_chart}|${curr_chart}|Failed")
        fi
      else
        SUMMARY_RESULTS+=("${r_name}|Helm Chart|${curr_chart}|${latest_chart}|Skipped")
      fi
    else
      SUMMARY_RESULTS+=("${r_name}|Helm Chart|${curr_chart}|${latest_chart}|${chart_status}")
    fi
  done
fi

# ==============================================================================
# 3. コンテナイメージ確認 & アップグレード
# ==============================================================================

# レジストリから最新イメージタグを検索する
#   - ghcr.io: anonymous token + Registry API v2 / Docker Hub: Tags API
#   - プレリリーズ・moving tag (latest / main / dev 等) を除外
#   - 取得失敗時は空文字を返す (呼び出し側で Skipped 扱い)
get_latest_image_tag() {
  local img="$1" base registry repo tags_json="" token="" tags_raw
  local page_url page_body page=0 last_tag page_count
  base="${img%%:*}"    # タグ除去 (レジストリにポートなし前提)
  registry="${base%%/*}"
  case "$registry" in
    ghcr.io)
      repo="${base#ghcr.io/}"
      token=$(curl -fsS --connect-timeout 10 --max-time 30 \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>/dev/null \
        | jq -r '.token // empty' 2>/dev/null || true)
      if [[ -n "$token" ]]; then
        # GHCR は既定で100件しか返さないため n=1000 とし、
        # 最後のタグ (配列末尾) を起点に last パラメータで全件を逐次取得する
        # (リンク先 URL が ?last=<末尾タグ>&n=1000 形式であることを確認済み。
        #  コミット毎タグを持つリポジトリは 4 万件超・42 ページ等になるため
        #  上限は 100 ページ = 最大 10 万タグまで許容する)
        page_url="https://ghcr.io/v2/${repo}/tags/list?n=1000"
        while [[ -n "$page_url" && $page -lt 100 ]]; do
          page=$((page + 1))
          page_body=$(curl -fsS --connect-timeout 10 --max-time 30 \
            -H "Authorization: Bearer ${token}" "$page_url" 2>/dev/null) || break
          tags_json+="${page_body}"$'\n'
          last_tag=$(printf '%s' "$page_body" | jq -r '.tags[-1] // empty' 2>/dev/null || true)
          page_count=$(printf '%s' "$page_body" | jq -r '(.tags // []) | length' 2>/dev/null || echo 0)
          if [[ -n "$last_tag" && "$page_count" -ge 1000 ]]; then
            page_url="https://ghcr.io/v2/${repo}/tags/list?n=1000&last=${last_tag}"
          else
            page_url=""
          fi
        done
      fi
      ;;
    docker.io|registry-1.docker.io)
      repo="${base#docker.io/}"
      repo="${repo#registry-1.docker.io/}"
      tags_json=$(curl -fsS --connect-timeout 10 --max-time 30 \
        "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&ordering=last_updated" 2>/dev/null || true)
      ;;
    *)
      return 0
      ;;
  esac
  [[ -z "$tags_json" ]] && return 0
  # ghcr: .tags[] / Docker Hub: .results[].name を正規化して取得
  tags_raw=$(printf '%s' "$tags_json" | jq -r '(.tags // [.results[].name])[]?' 2>/dev/null || true)
  # 数値バージョンタグのみに絞り、最大バージョンを返す
  printf '%s\n' "$tags_raw" | grep -E '^v?[0-9]+([.][0-9A-Za-z]+)*$' | sort -Vu | tail -1 || true
}

if [[ "$K8S_ONLY" == false && "$CHARTS_ONLY" == false ]]; then
  title "3. コンテナイメージ & 仮想化スタック確認 & 最新版反映"
  # 管理対象の主要 Deployment イメージ
  # 形式: "Deployment名|Namespace|コンテナ名|versions.env キー|更新方式"
  #   更新方式:
  #     full   - タグ更新時に完全イメージ ref を versions.env に反映
  #     tag    - タグのみ versions.env に反映
  #     latest - latest チャネル (検出せずローリング再起動のみ)
  DEPLOY_TARGETS=(
    "pgadmin|keycloak|pgadmin|PGADMIN_IMAGE|latest"
    "open-webui|open-webui|open-webui|OPEN_WEBUI_IMAGE_TAG|tag"
    "lemonade|lemonade|lemonade|LEMONADE_IMAGE|full"
  )

  for d_target in "${DEPLOY_TARGETS[@]}"; do
    IFS="|" read -r dep_name dep_ns c_name vs_key vs_mode <<< "$d_target"

    # ワークロード種別を自動判別 (永続化 provider=local のチャートは StatefulSet を選択する)
    dep_kind="deployment"
    dep_json=$(kubectl get deployment "$dep_name" -n "$dep_ns" -o json 2>/dev/null || echo "")
    if [[ -z "$dep_json" ]]; then
      dep_kind="statefulset"
      dep_json=$(kubectl get statefulset "$dep_name" -n "$dep_ns" -o json 2>/dev/null || echo "")
    fi
    if [[ -z "$dep_json" ]]; then
      continue
    fi
    img=$(echo "$dep_json" | jq -r --arg c "$c_name" '(.spec.template.spec.containers[]? | select(.name == $c) | .image) // empty' 2>/dev/null || echo "")
    if [[ -z "$img" ]]; then
      continue
    fi

    log "[Image] ${dep_name}/${c_name}: ${img}"

    # latest チャネルは従来どおりローリング再起動で最新化
    if [[ "$vs_mode" == "latest" ]]; then
      if [[ "$CHECK_ONLY" == false ]]; then
        log "  -> ${dep_name} (${dep_ns}) のローリング更新をトリガー中..."
        kubectl rollout restart "${dep_kind}/${dep_name}" -n "$dep_ns" >/dev/null 2>&1 || true
        SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${img}|Refreshed")
      else
        SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${img}|Checked")
      fi
      continue
    fi

    # 最新タグ検出 (失敗時は Skipped)
    curr_tag="${img##*:}"
    latest_tag=$(get_latest_image_tag "$img")
    if [[ -z "$latest_tag" ]]; then
      warn "  -> ${dep_name} の最新タグ検出に失敗しました (レジストリ接続を確認してください)"
      SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${img}|Skipped")
      continue
    fi

    base_img="${img%%:*}"
    new_img="${base_img}:${latest_tag}"

    if [[ "$curr_tag" == "$latest_tag" ]]; then
      SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${new_img}|Up to date")
      continue
    fi

    if [[ "$CHECK_ONLY" == true ]]; then
      log "  -> アップグレード可能: ${curr_tag} -> ${latest_tag}"
      SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${new_img}|Upgrade available")
      continue
    fi

    # versions.env を更新 (次回デプロイの SSOT として反映)
    if [[ "$vs_mode" == "full" ]]; then
      sed -i "s|^${vs_key}=.*|${vs_key}=\"${new_img}\"|" "$VERSIONS_ENV"
    else
      sed -i "s|^${vs_key}=.*|${vs_key}=\"${latest_tag}\"|" "$VERSIONS_ENV"
    fi
    log "  -> versions.env の ${vs_key} を ${latest_tag} に更新しました"

    # クラスタの Deployment へ即時反映 (Ansible 再実行前でもアップグレードを適用)
    log "  -> ${dep_name} (${dep_ns}) のイメージを ${new_img} へ切り替え中..."
    if kubectl set image "${dep_kind}/${dep_name}" -n "$dep_ns" "${c_name}=${new_img}" >/dev/null 2>&1 \
      && kubectl rollout status "${dep_kind}/${dep_name}" -n "$dep_ns" --timeout="${HELM_TIMEOUT:-15m}" >/dev/null 2>&1; then
      log "  -> ${dep_name} のイメージ更新が完了しました。"
      SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${new_img}|Updated")
    else
      warn "  -> ${dep_name} のイメージ更新に失敗しました (次回 start.sh 実行で再適用されます)"
      SUMMARY_RESULTS+=("${dep_name} (${c_name})|Container Image|${img}|${new_img}|Failed")
    fi
  done

  # images.txt が存在する場合の Podman キャッシュ最新化
  if [[ "$CHECK_ONLY" == false && -f "$IMAGES_TXT" ]]; then
    log "images.txt の未キャッシュイメージを Podman ローカルストレージに最新化中..."
    img_count=0
    img_total=$(grep -cE '^[^#]+' "$IMAGES_TXT" 2>/dev/null || echo 0)
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=$(echo "$line" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
      if [[ -z "$line" || "$line" =~ ^# ]]; then
        continue
      fi
      img_count=$((img_count + 1))
      if command -v podman &>/dev/null; then
        # 固定タグで既にローカルキャッシュに存在する場合はスキップして高速化
        if [[ "$line" != *":latest" ]] && sudo podman image exists "$line" 2>/dev/null; then
          log "  [${img_count}/${img_total}] (キャッシュ済・スキップ) ${line}"
        else
          log "  [${img_count}/${img_total}] プル中: ${line}"
          sudo podman pull -q "$line" 2>/dev/null || warn "  -> プル失敗: ${line}"
        fi
      fi
    done < "$IMAGES_TXT"
    log "イメージキャッシュの最新化完了 (${img_count}/${img_total})"
  fi
fi

# ==============================================================================
# 4. Podman イメージ整理 (ダンangling + 未使用)
# ==============================================================================
if [[ "$PRUNE_IMAGES" == true ]]; then
  title "4. Podman イメージ整理"

  if ! command -v podman &>/dev/null; then
    warn "podman が見つかりません。イメージ整理をスキップします。"
  else
    # 整理前のディスク使用量
    log "整理前の Podman ストレージ使用量:"
    BEFORE_SIZE=$(sudo podman system info --format '{{.Store.ImageStore.FreeLayerSize}}' 2>/dev/null || echo "0")
    sudo podman system df 2>/dev/null || true
    echo ""

    # ダンangling イメージ数を取得
    DANGLING_COUNT=$(sudo podman images -f "dangling=true" -q 2>/dev/null | wc -l)
    # 未使用イメージ数を取得 (コンテナから参照されていない)
    UNUSED_COUNT=$(sudo podman images --filter "until=720h" -q 2>/dev/null | wc -l)

    log "ダンangling イメージ: ${DANGLING_COUNT} 個"
    log "720時間 (30日) 以上前のイメージ: ${UNUSED_COUNT} 個"

    if [[ "$DANGLING_COUNT" -eq 0 && "$UNUSED_COUNT" -eq 0 ]]; then
      log "整理対象のイメージはありません。"
      SUMMARY_RESULTS+=("Podman イメージ|Image Prune|${DANGLING_COUNT} dangling, ${UNUSED_COUNT} old|0|No action")
    else
      # 削除対象一覧を表示
      echo ""
      log "=== 削除対象ダンangling イメージ ==="
      sudo podman images -f "dangling=true" --format "  {{.ID}} {{.Repository}}:{{.Tag}} ({{.Size}}, {{.CreatedSince}})" 2>/dev/null || true
      echo ""
      log "=== 720時間以上前のイメージ (最新5件) ==="
      sudo podman images --filter "until=720h" --format "  {{.ID}} {{.Repository}}:{{.Tag}} ({{.Size}}, {{.CreatedSince}})" 2>/dev/null | head -5 || true
      echo ""

      # 確認プロンプト
      do_prune=true
      if [[ "$CHECK_ONLY" == true ]]; then
        log "(ドライラン: 実際の削除は行いません)"
        do_prune=false
        SUMMARY_RESULTS+=("Podman イメージ|Image Prune|${DANGLING_COUNT} dangling, ${UNUSED_COUNT} old|0|Dry run")
      elif [[ "$AUTO_YES" == false ]]; then
        read -rp "ダンangling/未使用イメージを削除しますか? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
          do_prune=false
          SUMMARY_RESULTS+=("Podman イメージ|Image Prune|${DANGLING_COUNT} dangling, ${UNUSED_COUNT} old|0|Skipped")
        fi
      fi

      if [[ "$do_prune" == true ]]; then
        log "ダンangling イメージを削除中..."
        sudo podman image prune -f 2>/dev/null || true

        log "720時間以上前のイメージを削除中..."
        sudo podman image prune -a --filter "until=720h" -f 2>/dev/null || true

        # 整理後のディスク使用量
        echo ""
        log "整理後の Podman ストレージ使用量:"
        sudo podman system df 2>/dev/null || true

        PRUNED_COUNT=$((DANGLING_COUNT + UNUSED_COUNT))
        log "イメージ整理が完了しました。削除対象: ${PRUNED_COUNT} 個"
        SUMMARY_RESULTS+=("Podman イメージ|Image Prune|${DANGLING_COUNT} dangling, ${UNUSED_COUNT} old|0|Pruned")
      fi
    fi
  fi
fi

# ==============================================================================
# 5. バージョン情報ファイルの自動更新 (versions.env)
# ==============================================================================
update_versions_file() {
  if [[ "$CHECK_ONLY" == true ]]; then
    return 0
  fi

  log "バージョン情報ファイル (versions.env) を更新中..."

  if [[ ! -f "$VERSIONS_ENV" ]]; then
    warn "versions.env が見つません。スキップします。"
    return 0
  fi

  # K3s バージョン更新
  if [[ -n "${LATEST_K8S:-}" && "${LATEST_K8S}" != "Unknown" ]]; then
    sed -i "s|^K3S_VERSION=.*|K3S_VERSION=\"${LATEST_K8S}\"|" "$VERSIONS_ENV"
  fi
  if [[ -n "${LATEST_K8S_TAG:-}" ]]; then
    sed -i "s|^IMAGE=.*|IMAGE=\"rancher/k3s:${LATEST_K8S_TAG}\"|" "$VERSIONS_ENV"
  fi

  # Helm Chart バージョン更新
  [[ -n "${DETECTED_CHART_VERSIONS[cert-manager]:-}" ]] && sed -i "s|^CERT_MANAGER_CHART_VERSION=.*|CERT_MANAGER_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[cert-manager]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[keycloak-pg]:-}" ]] && sed -i "s|^KEYCLOAK_PG_CHART_VERSION=.*|KEYCLOAK_PG_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[keycloak-pg]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[keycloak]:-}" ]] && sed -i "s|^KEYCLOAK_CHART_VERSION=.*|KEYCLOAK_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[keycloak]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[rancher]:-}" ]] && sed -i "s|^RANCHER_CHART_VERSION=.*|RANCHER_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[rancher]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[kube-prometheus-stack]:-}" ]] && sed -i "s|^KUBE_PROMETHEUS_STACK_CHART_VERSION=.*|KUBE_PROMETHEUS_STACK_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[kube-prometheus-stack]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[rancher-monitoring-dashboards]:-}" ]] && sed -i "s|^RANCHER_MONITORING_DASHBOARDS_CHART_VERSION=.*|RANCHER_MONITORING_DASHBOARDS_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[rancher-monitoring-dashboards]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[amd-gpu]:-}" ]] && sed -i "s|^AMD_GPU_CHART_VERSION=.*|AMD_GPU_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[amd-gpu]}\"|" "$VERSIONS_ENV"
  [[ -n "${DETECTED_CHART_VERSIONS[open-webui]:-}" ]] && sed -i "s|^OPEN_WEBUI_CHART_VERSION=.*|OPEN_WEBUI_CHART_VERSION=\"${DETECTED_CHART_VERSIONS[open-webui]}\"|" "$VERSIONS_ENV"

  # config.yaml の K3s イメージ同期
  if [[ -n "${LATEST_K8S_TAG:-}" && -f "${SCRIPT_DIR}/config.yaml" ]]; then
    sed -i "s|^image: rancher/k3s:.*|image: rancher/k3s:${LATEST_K8S_TAG}|" "${SCRIPT_DIR}/config.yaml"
  fi

  log "バージョン情報ファイル (versions.env) を更新しました。"
}

# ==============================================================================
# 5. アップグレードサマリー表示 (コンソール出力)
# ==============================================================================
echo ""
echo -e "${BOLD}${CYAN}==============================================================================================================================${NC}"
echo -e "${BOLD}${CYAN}                                K3D on Podman - アップグレード結果サマリー (Upgrade Summary)                                  ${NC}"
echo -e "${BOLD}${CYAN}==============================================================================================================================${NC}"
printf "${BOLD}%-32s %-16s %-28s %-28s %-12s${NC}\n" "コンポーネント" "カテゴリ" "変更前 (Before)" "更新後/最新 (After)" "ステータス"
echo -e "${CYAN}------------------------------------------------------------------------------------------------------------------------------${NC}"

for item in "${SUMMARY_RESULTS[@]}"; do
  IFS="|" read -r name cat before after status <<< "$item"
  
  # ステータス色分け
  case "$status" in
    "Upgraded"|"Refreshed")
      status_color="${GREEN}${BOLD}${status}${NC}"
      ;;
    "Upgrade available")
      status_color="${YELLOW}${BOLD}${status}${NC}"
      ;;
    "Up to date"|"Checked")
      status_color="${BLUE}${status}${NC}"
      ;;
    "Failed")
      status_color="${RED}${BOLD}${status}${NC}"
      ;;
    *)
      status_color="${NC}${status}"
      ;;
  esac

  printf "%-32s %-16s %-28s %-28s %b\n" "$name" "$cat" "$before" "$after" "$status_color"
done

echo -e "${BOLD}${CYAN}==============================================================================================================================${NC}"
if [[ "$CHECK_ONLY" == true ]]; then
  # アップグレード可能なコンポーネントが存在するか集計
  UPGRADE_COUNT=0
  for item in "${SUMMARY_RESULTS[@]}"; do
    IFS="|" read -r _ _ _ _ s_status <<< "$item"
    if [[ "$s_status" == "Upgrade available" ]]; then
      UPGRADE_COUNT=$((UPGRADE_COUNT + 1))
    fi
  done

  if [[ $UPGRADE_COUNT -gt 0 ]]; then
    log "チェック完了: ${UPGRADE_COUNT} 件のコンポーネントでアップグレードが可能です。"
    echo ""
    exit 10
  else
    log "チェック完了: すべてのコンポーネントは最新です (アップグレード不要)。"
    echo ""
    exit 0
  fi
else
  update_versions_file
  log "全コンポーネントのバージョン確認およびアップグレード処理が完了しました。"
fi
echo ""

