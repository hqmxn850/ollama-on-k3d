#!/usr/bin/env bash
# ==============================================================================
# ollama-pull.sh - Kubernetes 上の Ollama モデル pull / 削除スクリプト
#
# 指定されたパラメータ（モデル名）に基づいて、Kubernetes クラスタ内で稼働する
# Ollama サービスに LLM モデルをダウンロード (pull) または削除 (delete / rm) します。
#
# 使用方法:
#   ./ollama-pull.sh [オプション] <model_name> [model_name2 ...]
#   ./ollama-pull.sh rm <model_name> [model_name2 ...]
#   ./ollama-pull.sh --delete <model_name> [model_name2 ...]
#   ./ollama-pull.sh --list
#   ./ollama-pull.sh --help
#
# オプション:
#   -m, --model <name>       対象のモデル名 (複数指定可)
#   -d, --delete, --rm       指定されたモデルをクラスタから削除
#   rm, delete               指定されたモデルを削除するサブコマンド
#   -l, --list               現在クラスタ内にダウンロード済みのモデル一覧を表示
#   -n, --namespace <ns>     Ollama の名前空間 (デフォルト: config.env の設定値または ollama)
#   --api                    Kubernetes Ingress / HTTPS API 経由で実行
#   --exec                   kubectl exec 経由で直接実行 (デフォルト)
#   -h, --help               このヘルプメッセージを表示
#
# 実行例:
#   ./ollama-pull.sh qwen2.5:0.5b
#   ./ollama-pull.sh rm qwen2.5:0.5b
#   ./ollama-pull.sh --delete llama3.2:1b
#   ./ollama-pull.sh --list
# ==============================================================================
set -euo pipefail

# スクリプト実体パスの解決 (シンボリックリンク追跡)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# プロジェクトルート検索 (config.env があるディレクトリ)
PROJECT_ROOT="${SCRIPT_DIR}"
while [[ ! -f "${PROJECT_ROOT}/config.env" && "${PROJECT_ROOT}" != "/" ]]; do
  PROJECT_ROOT="$(dirname "${PROJECT_ROOT}")"
done

# 共通ライブラリおよび設定変数の読み込み (Single Source of Truth)
if [[ -f "${PROJECT_ROOT}/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/config.env"
fi

if [[ -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/lib/common.sh"
else
  log() { echo -e "\033[36m[INFO]\033[0m $*"; }
  warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
  err() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
  succ() { echo -e "\033[32m[SUCCESS]\033[0m $*"; }
fi

# デフォルト設定値の定義 (リテラルの変数化)
OLLAMA_NAMESPACE="${OLLAMA_NAMESPACE:-ollama}"
EMAIL_DOMAIN="${EMAIL_DOMAIN:-philippines.com.ph}"
OLLAMA_HOSTNAME="${OLLAMA_HOSTNAME:-ollama.${EMAIL_DOMAIN}}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

MODE="exec" # "exec" または "api"
ACTION="pull" # "pull" または "delete" または "list"
MODELS=()

# ヘルプ表示関数
usage() {
  cat <<'EOF'
使用方法:
  ./ollama-pull.sh [オプション] <model_name> [model_name2 ...]
  ./ollama-pull.sh rm <model_name> [model_name2 ...]
  ./ollama-pull.sh --delete <model_name> [model_name2 ...]

説明:
  Kubernetes 上で稼働中の Ollama サービスに指定された LLM モデルをダウンロード (pull)
  または不要になったモデルを削除 (rm / delete) します。
  モデルデータは Ollama 用の永続ボリューム (PersistentVolumeClaim) に保存・管理されます。

オプション:
  -m, --model <name>       対象のモデル名
  pull, download           ダウンロードのサブコマンド構文 (省略可)
  -d, --delete, --rm       指定されたモデルをクラスタから削除
  rm, delete               指定されたモデルを削除するサブコマンド構文
  -l, --list               現在クラスタ内にダウンロード済みのモデル一覧を表示
  -n, --namespace <ns>     Ollama の名前空間 (デフォルト: ollama)
  --exec                   kubectl exec 経由で実行 (デフォルト: 対話的進捗バー表示)
  --api                    HTTPS API 経由で実行 (pull: POST /api/pull, rm: DELETE /api/delete)
  -h, --help               このヘルプメッセージを表示

推奨モデル例:
  qwen2.5:0.5b             超軽量・高速 (約 394 MB)
  llama3.2:1b              Meta 最新軽量モデル (約 1.3 GB)
  llama3.2:3b              Meta 高性能軽量モデル (約 2.0 GB)
  phi3:mini                Microsoft 3.8B パラメータ (約 2.2 GB)
  deepseek-r1:1.5b         推論・思考特化モデル (約 1.1 GB)

使用例:
  # モデルのダウンロード
  ./ollama-pull.sh qwen2.5:0.5b
  ./ollama-pull.sh -m llama3.2:1b
  ./ollama-pull.sh --list

  # モデルの削除
  ./ollama-pull.sh rm qwen2.5:0.5b
  ./ollama-pull.sh --delete qwen2.5:0.5b
  ./ollama-pull.sh -d llama3.2:1b
EOF
  exit 0
}

# 引数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      ;;
    -l|--list)
      ACTION="list"
      shift
      ;;
    -d|--delete|--rm|rm|delete)
      ACTION="delete"
      shift
      ;;
    pull|download)
      # pull サブコマンド構文 (省略可): ./ollama-pull.sh pull <model_name>
      shift
      ;;
    --exec)
      MODE="exec"
      shift
      ;;
    --api)
      MODE="api"
      shift
      ;;
    -n|--namespace)
      OLLAMA_NAMESPACE="$2"
      shift 2
      ;;
    -m|--model)
      MODELS+=("$2")
      shift 2
      ;;
    -*)
      err "未知のオプションです: $1"
      echo "使用法については ./ollama-pull.sh --help を参照してください。" >&2
      exit 1
      ;;
    *)
      MODELS+=("$1")
      shift
      ;;
  esac
done

# 前提コマンドの確認
if ! command -v kubectl &>/dev/null; then
  err "kubectl コマンドが見つかりません。クラスタ接続環境を確認してください。"
  exit 1
fi

# Ollama Pod の稼働確認
check_ollama_pod() {
  log "Kubernetes 上の Ollama Pod 稼働状態を確認中 (namespace: ${OLLAMA_NAMESPACE})..."
  local pod_status
  pod_status=$(kubectl get pods -n "${OLLAMA_NAMESPACE}" -l app.kubernetes.io/name=ollama -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "${pod_status}" != "Running" ]]; then
    err "Ollama Pod が Running 状態ではありません (現在の状態: ${pod_status})。"
    err "クラスタの稼働状況を確認してください: kubectl get pods -n ${OLLAMA_NAMESPACE}"
    exit 1
  fi
  local pod_name
  pod_name=$(kubectl get pods -n "${OLLAMA_NAMESPACE}" -l app.kubernetes.io/name=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log "稼働中 Ollama Pod を検出: ${pod_name}"
}

# モデル一覧の表示
list_models() {
  check_ollama_pod
  log "Ollama にダウンロード済みのモデル一覧を取得中..."
  kubectl exec -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama list
  exit 0
}

if [[ "${ACTION}" == "list" ]]; then
  list_models
fi

# モデル名が指定されていない場合のエラーハンドリング
if [[ ${#MODELS[@]} -eq 0 ]]; then
  if [[ "${ACTION}" == "delete" ]]; then
    err "削除するモデル名が指定されていません。"
  else
    err "ダウンロードするモデル名が指定されていません。"
  fi
  echo ""
  usage
fi

# Ollama Pod の確認
check_ollama_pod

# ==============================================================================
# モデル削除処理 (delete / rm)
# ==============================================================================
delete_models() {
  local total_models=${#MODELS[@]}
  local current=0
  local failed_models=()

  log "指定されたモデルの削除 (delete) を開始します (合計: ${total_models} 件)..."

  for model in "${MODELS[@]}"; do
    current=$((current + 1))
    echo ""
    log "[${current}/${total_models}] モデル '${model}' の削除を実行中..."

    if [[ "${MODE}" == "exec" ]]; then
      # kubectl exec 経由
      if kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama rm "${model}"; then
        succ "モデル '${model}' を正常に削除しました。"
      else
        err "モデル '${model}' の削除に失敗しました。"
        failed_models+=("${model}")
      fi
    else
      # HTTPS API 経由 (DELETE /api/delete)
      log "HTTPS API (https://${OLLAMA_HOSTNAME}/api/delete) 経由で削除リクエストを送信中..."
      local http_status
      http_status=$(curl -k -s -o /dev/null -w "%{http_code}" -X DELETE "https://${OLLAMA_HOSTNAME}/api/delete" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${model}\"}")
      if [[ "${http_status}" == "200" || "${http_status}" == "204" ]]; then
        succ "モデル '${model}' を正常に削除しました (HTTP ${http_status})。"
      else
        err "モデル '${model}' の API 削除に失敗しました (HTTP ${http_status})。"
        failed_models+=("${model}")
      fi
    fi
  done

  echo ""
  # 削除後のモデル一覧表示
  log "削除後のダウンロード済みモデル一覧:"
  kubectl exec -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama list

  if [[ ${#failed_models[@]} -gt 0 ]]; then
    echo ""
    err "以下のモデルの削除に失敗しました: ${failed_models[*]}"
    exit 1
  fi

  echo ""
  succ "全指定モデルの削除処理が完了しました。"
  exit 0
}

# 削除アクション実行
if [[ "${ACTION}" == "delete" ]]; then
  delete_models
fi

# ホスト上のローカルキャッシュからモデルをインポートする関数
try_import_from_host_cache() {
  local model="$1"
  local sudo_cmd=""
  if [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null; then
    sudo_cmd="sudo"
  fi

  local name_tag="$model"
  local name tag
  if [[ "$name_tag" == *":"* ]]; then
    tag="${name_tag##*:}"
    name="${name_tag%:*}"
  else
    tag="latest"
    name="$name_tag"
  fi

  local registry="registry.ollama.ai"
  if [[ "$name" == *"/"* ]]; then
    local first_part="${name%%/*}"
    if [[ "$first_part" == *"."* || "$first_part" == *":"* ]]; then
      registry="$first_part"
      name="${name#*/}"
    fi
  else
    name="library/${name}"
  fi

  local rel_manifest="manifests/${registry}/${name}/${tag}"

  local cache_dirs=(
    "/usr/share/ollama/.ollama/models"
    "${HOME}/.ollama/models"
    "/var/lib/ollama/.ollama/models"
  )

  local found_cache_dir=""
  for cdir in "${cache_dirs[@]}"; do
    if ${sudo_cmd} test -f "${cdir}/${rel_manifest}" 2>/dev/null; then
      found_cache_dir="$cdir"
      break
    fi
  done

  if [[ -z "${found_cache_dir}" ]]; then
    return 1
  fi

  log "ホスト上にモデル '${model}' のキャッシュを検出しました: ${found_cache_dir}"
  log "キャッシュファイルの整合性を検証中..."

  local file_list
  if ! file_list=$(${sudo_cmd} python3 - "${found_cache_dir}" "${rel_manifest}" <<'PYEOF' 2>/dev/null
import json, sys, os

cache_dir = sys.argv[1]
rel_manifest = sys.argv[2]
manifest_path = os.path.join(cache_dir, rel_manifest)

try:
    with open(manifest_path, "r") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

files = [rel_manifest]

def to_blob(d):
    return "blobs/" + d.replace(":", "-")

config_digest = data.get("config", {}).get("digest")
if config_digest:
    files.append(to_blob(config_digest))

for layer in data.get("layers", []):
    d = layer.get("digest")
    if d:
        files.append(to_blob(d))

for f in files:
    full = os.path.join(cache_dir, f)
    if not os.path.isfile(full):
        sys.exit(1)

for f in files:
    print(f)
PYEOF
  ); then
    warn "キャッシュファイルの検証に失敗しました。通常ダウンロードに移行します。"
    return 1
  fi

  log "ホストのキャッシュから Ollama Pod へのモデル転送を開始します (高速インポート)..."
  if printf '%s\n' "${file_list}" | ${sudo_cmd} tar -C "${found_cache_dir}" -cf - -T - \
    | kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- tar -xf - -C /root/.ollama/models 2>/dev/null; then
    
    if kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama list 2>/dev/null \
      | awk '{print $1}' | grep -qi "^${model}$"; then
      succ "ホストのキャッシュからモデル '${model}' を正常にインポートしました。"
      return 0
    fi
  fi

  warn "キャッシュのインポート後にモデルが認識されなかったため、通常ダウンロードに移行します。"
  return 1
}

# ==============================================================================
# モデルダウンロード処理 (pull)
# ==============================================================================
TOTAL_MODELS=${#MODELS[@]}
CURRENT=0
FAILED_MODELS=()

log "指定されたモデルのダウンロード (pull) を開始します (合計: ${TOTAL_MODELS} 件)..."

for model in "${MODELS[@]}"; do
  CURRENT=$((CURRENT + 1))
  echo ""
  log "[${CURRENT}/${TOTAL_MODELS}] モデル '${model}' の取得を開始します..."

  # ホスト上のローカルキャッシュからの高速インポートを試行
  if try_import_from_host_cache "${model}"; then
    continue
  fi

  if [[ "${MODE}" == "exec" ]]; then
    # kubectl exec 経由 (標準の対話的進捗バー)
    if [ -t 1 ]; then
      # 端末で実行されている場合は対話的 TTY を付与
      if kubectl exec -it -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama pull "${model}"; then
        succ "モデル '${model}' のダウンロードが正常に完了しました。"
      else
        err "モデル '${model}' のダウンロードに失敗しました。"
        FAILED_MODELS+=("${model}")
      fi
    else
      # 非対話環境
      if kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama pull "${model}"; then
        succ "モデル '${model}' のダウンロードが正常に完了しました。"
      else
        err "モデル '${model}' のダウンロードに失敗しました。"
        FAILED_MODELS+=("${model}")
      fi
    fi
  else
    # HTTPS API 経由 (ストリーミング JSON レスポンス)
    log "HTTPS API (https://${OLLAMA_HOSTNAME}/api/pull) 経由でリクエストを送信中..."
    if curl -k -s -N -X POST "https://${OLLAMA_HOSTNAME}/api/pull" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${model}\"}" | while read -r line; do
        # 簡易ステータス表示
        if echo "${line}" | grep -q '"status"'; then
          status_msg=$(echo "${line}" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
          total=$(echo "${line}" | grep -o '"total":[0-9]*' | cut -d':' -f2 || true)
          completed=$(echo "${line}" | grep -o '"completed":[0-9]*' | cut -d':' -f2 || true)
          if [[ -n "${total}" && -n "${completed}" && "${total}" -gt 0 ]]; then
            percent=$(( completed * 100 / total ))
            echo -ne "\r\033[K[API] ${status_msg}: ${percent}% (${completed}/${total} bytes)"
          else
            echo -ne "\r\033[K[API] ${status_msg}..."
          fi
        fi
      done; echo ""; then
      succ "モデル '${model}' のダウンロードが正常に完了しました。"
    else
      err "モデル '${model}' の API ダウンロードに失敗しました。"
      FAILED_MODELS+=("${model}")
    fi
  fi
done

echo ""
# 完了後のモデル一覧表示
log "現在のダウンロード済みモデル一覧:"
kubectl exec -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama list

if [[ ${#FAILED_MODELS[@]} -gt 0 ]]; then
  echo ""
  err "以下のモデルのダウンロードに失敗しました: ${FAILED_MODELS[*]}"
  exit 1
fi

echo ""
succ "全指定モデルのダウンロード処理が完了しました。"
exit 0
