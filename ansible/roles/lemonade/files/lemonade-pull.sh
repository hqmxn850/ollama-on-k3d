#!/usr/bin/env bash
# ==============================================================================
# lemonade-pull.sh - Kubernetes 上の Lemonade モデル pull / 削除スクリプト
#
# 指定されたパラメータ (モデル名) に基づいて、Kubernetes クラスタ内で稼働する
# Lemonade Server (Ollama 互換 API) に LLM モデルをダウンロード (pull) または
# 削除 (delete / rm) します。モデルデータは Lemonade 用の永続ボリューム
# (PersistentVolumeClaim) に保存・管理されます。
#
# 使用方法:
#   ./lemonade-pull.sh [オプション] <model_name> [model_name2 ...]
#   ./lemonade-pull.sh rm <model_name> [model_name2 ...]
#   ./lemonade-pull.sh --delete <model_name> [model_name2 ...]
#   ./lemonade-pull.sh --list
#   ./lemonade-pull.sh --help
#
# オプション:
#   -m, --model <name>       対象のモデル名 (複数指定可)
#   pull, download           ダウンロードのサブコマンド構文 (省略可)
#   -d, --delete, --rm       指定されたモデルをクラスタから削除
#   rm, delete               指定されたモデルを削除するサブコマンド
#   -l, --list               現在クラスタ内にダウンロード済みのモデル一覧を表示
#   -n, --namespace <ns>     Lemonade の名前空間 (デフォルト: config.env の LEMONADE_NAMESPACE)
#   --api                    Ingress / HTTPS API 経由で実行 (デフォルト: Pod 内 kubectl exec)
#   -h, --help               このヘルプメッセージを表示
#
# 実行例:
#   ./lemonade-pull.sh Qwen3.8-27B-GGUF
#   ./lemonade-pull.sh rm Qwen3.8-27B-GGUF
#   ./lemonade-pull.sh --list
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

# 一時ファイル (エラー報告用) の自動クリーンアップ
TMP_FILES=()
cleanup_tmp_files() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
    rm -f "${TMP_FILES[@]}" 2>/dev/null || true
  fi
}
trap cleanup_tmp_files EXIT

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
LEMONADE_NAMESPACE="${LEMONADE_NAMESPACE:-lemonade}"
EMAIL_DOMAIN="${EMAIL_DOMAIN:-philippines.com.ph}"
LEMONADE_HOSTNAME="${LEMONADE_HOSTNAME:-lemonade.${EMAIL_DOMAIN}}"
LEMONADE_PORT="${LEMONADE_PORT:-11434}"
LEMONADE_DEPLOYMENT="${LEMONADE_DEPLOYMENT:-lemonade}"

MODE="exec" # "exec" (Pod 内 curl) または "api" (Ingress HTTPS)
ACTION="pull" # "pull" または "delete" または "list"
MODELS=()

# ヘルプ表示関数
usage() {
  cat <<'EOF'
使用方法:
  ./lemonade-pull.sh [オプション] <model_name> [model_name2 ...]
  ./lemonade-pull.sh rm <model_name> [model_name2 ...]
  ./lemonade-pull.sh --delete <model_name> [model_name2 ...]
  ./lemonade-pull.sh --list

説明:
  Kubernetes 上で稼働中の Lemonade Server (Ollama 互換 API) に指定された
  LLM モデルをダウンロード (pull) または不要になったモデルを削除 (rm / delete) します。
  モデルデータは Lemonade 用の永続ボリューム (PersistentVolumeClaim) に保存・管理されます。

オプション:
  -m, --model <name>       対象のモデル名
  pull, download           ダウンロードのサブコマンド構文 (省略可)
  -d, --delete, --rm       指定されたモデルをクラスタから削除
  rm, delete               指定されたモデルを削除するサブコマンド構文
  -l, --list               現在クラスタ内にダウンロード済みのモデル一覧を表示
  -n, --namespace <ns>     Lemonade の名前空間 (デフォルト: lemonade)
  --exec                   kubectl exec 経由で Pod 内 API を直接利用 (デフォルト)
  --api                    Ingress / HTTPS API 経由で実行
  -h, --help               このヘルプメッセージを表示

推奨モデル例 (HuggingFace GGUF リポジトリ):
  Gemma-4-E4B-it-GGUF       標準 LLM モデル (config.env: LEMONADE_DEFAULT_MODEL)
  Qwen3.8-27B-GGUF          高性能 27B チャットモデル (約 16 GB)
  Qwen3-4B-GGUF             軽量・高速 (数 GB)
  Qwen3-0.6B-GGUF           超軽量・テスト用

使用例:
  # モデルのダウンロード
  ./lemonade-pull.sh Gemma-4-E4B-it-GGUF
  ./lemonade-pull.sh -m Qwen3-4B-GGUF
  ./lemonade-pull.sh --list

  # モデルの削除
  ./lemonade-pull.sh rm Gemma-4-E4B-it-GGUF
  ./lemonade-pull.sh --delete Qwen3-4B-GGUF
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
      # pull サブコマンド構文 (省略可): ./lemonade-pull.sh pull <model_name>
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
      LEMONADE_NAMESPACE="$2"
      shift 2
      ;;
    -m|--model)
      MODELS+=("$2")
      shift 2
      ;;
    -*)
      err "未知のオプションです: $1"
      echo "使用法については ./lemonade-pull.sh --help を参照してください。" >&2
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

# JSON 解析ツールの選択 (jq 優先、なければ python3)
# 使用法: json_tool tags     -> モデル名を 1 行ずつ出力
#         json_tool status   -> status フィールドを出力
json_tool() {
  local mode="$1"
  if command -v jq &>/dev/null; then
    case "${mode}" in
      tags)   jq -r '.models[]? | [(.name // .model // empty), ((.size // 0) | tostring), (.modified_at // .modified // "-")] | @tsv' ;;
      status) jq -r 'if .status == null then empty
        elif (.completed != null and .total != null and .total > 0)
          then "\(.status) (\((.completed * 100 / .total) | floor)%)"
        else .status end' ;;
      error)  jq -r '.error? // empty | if type == "object" then (.message // tostring) else tostring end' ;;
      *)      return 1 ;;
    esac
  else
    python3 -c "
import json, sys
mode = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if mode == 'tags':
    for m in data.get('models', []):
        name = m.get('name') or m.get('model') or ''
        if not name:
            continue
        print('{}\t{}\t{}'.format(name, m.get('size') or 0, m.get('modified_at') or '-'))
elif mode == 'status':
    s = data.get('status')
    c = data.get('completed')
    t = data.get('total')
    if s and c is not None and t:
        print('{} ({}%)'.format(s, int(c * 100 / t)))
    elif s:
        print(s)
elif mode == 'error':
    e = data.get('error')
    if isinstance(e, dict):
        print(e.get('message') or json.dumps(e, ensure_ascii=False))
    elif e:
        print(e)
" "${mode}"
  fi
}

# Lemonade Pod の稼働確認
check_lemonade_pod() {
  log "Kubernetes 上の Lemonade Pod 稼働状態を確認中 (namespace: ${LEMONADE_NAMESPACE})..."
  local pod_status
  pod_status=$(kubectl get pods -n "${LEMONADE_NAMESPACE}" -l app.kubernetes.io/name=lemonade -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "${pod_status}" != "Running" ]]; then
    err "Lemonade Pod が Running 状態ではありません (現在の状態: ${pod_status})。"
    err "クラスタの稼働状況を確認してください: kubectl get pods -n ${LEMONADE_NAMESPACE}"
    exit 1
  fi
  local pod_name
  pod_name=$(kubectl get pods -n "${LEMONADE_NAMESPACE}" -l app.kubernetes.io/name=lemonade -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log "稼働中 Lemonade Pod を検出: ${pod_name}"
}

# Lemonade API への HTTP リクエスト (transport 抽象化)
# 使用法: lemonade_curl <curl に渡す引数...>
#   exec モード: Pod 内の curl で 127.0.0.1 の API を叩く
#   api  モード: ホストから Ingress (HTTPS) を叩く
lemonade_curl() {
  if [[ "${MODE}" == "api" ]]; then
    if ! command -v curl &>/dev/null; then
      err "curl コマンドが見つかりません (--api モードには必要です)。"
      exit 1
    fi
    curl -sk "$@"
  else
    kubectl exec -i -n "${LEMONADE_NAMESPACE}" "deployment/${LEMONADE_DEPLOYMENT}" -- \
      curl -sS --max-time 43200 "$@"
  fi
}

# API ベース URL の解決
api_base_url() {
  if [[ "${MODE}" == "api" ]]; then
    echo "https://${LEMONADE_HOSTNAME}"
  else
    echo "http://127.0.0.1:${LEMONADE_PORT}"
  fi
}

# モデル一覧の表示 (Ollama 互換 GET /api/tags)
list_models() {
  check_lemonade_pod
  log "Lemonade にダウンロード済みのモデル一覧を取得中..."
  local base response
  base="$(api_base_url)"
  response="$(lemonade_curl "${base}/api/tags" || true)"
  if [[ -z "${response}" ]]; then
    err "Lemonade API (/api/tags) に接続できませんでした。"
    exit 1
  fi
  echo "NAME	SIZE(B)	MODIFIED"
  printf '%s' "${response}" | json_tool tags 2>/dev/null || true
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

# Lemonade Pod の確認
check_lemonade_pod
LEMONADE_BASE_URL="$(api_base_url)"

# ==============================================================================
# モデルダウンロード処理 (pull / download)
# ==============================================================================
pull_models() {
  local failed=0
  local max_attempts="${LEMONADE_PULL_RETRIES:-10}"
  local retry_interval="${LEMONADE_PULL_RETRY_INTERVAL:-10}"
  for model in "${MODELS[@]}"; do
    local body last_status="" attempt=1 pulled=0 err_file
    local error_msg status
    err_file="$(mktemp)"
    TMP_FILES+=("${err_file}")
    body="$(printf '{"name": "%s", "model": "%s", "stream": true}' "${model}" "${model}")"
    while (( attempt <= max_attempts )); do
      log "モデル '${model}' を Lemonade にダウンロード中 (進捗は下記の通り) / 試行 ${attempt}/${max_attempts}..."
      if lemonade_curl -N -X POST -H "Content-Type: application/json" \
          -d "${body}" "${LEMONADE_BASE_URL}/api/pull" | \
          while IFS= read -r line || [[ -n "${line}" ]]; do
            error_msg=$(printf '%s' "${line}" | json_tool error 2>/dev/null || true)
            if [[ -n "${error_msg}" ]]; then
              echo "  [ERROR] ${error_msg}" >&2
              printf '%s' "${error_msg}" > "${err_file}"
              exit 1
            fi
            status=$(printf '%s' "${line}" | json_tool status 2>/dev/null || true)
            if [[ -n "${status}" && "${status}" != "${last_status}" ]]; then
              echo "  ${status}"
              last_status="${status}"
            fi
          done; then
        pulled=1
        break
      fi
      if [[ -s "${err_file}" ]]; then
        break
      fi
      warn "ダウンロードが中断しました (${attempt}/${max_attempts})。部分ダウンロードから再開します..."
      (( attempt++ ))
      sleep "${retry_interval}"
    done
    if (( pulled == 1 )); then
      succ "モデル '${model}' のダウンロードが完了しました (--list で確認できます)。"
    elif [[ -s "${err_file}" ]]; then
      err "モデル '${model}' のダウンロードに失敗しました: $(cat "${err_file}")"
      failed=1
    else
      err "モデル '${model}' のダウンロードに失敗しました (リトライ回数 ${max_attempts} 回に達しました)。"
      failed=1
    fi
    rm -f "${err_file}"
  done
  return "${failed}"
}

# ==============================================================================
# モデル削除処理 (delete / rm)
# ==============================================================================
delete_models() {
  local failed=0
  for model in "${MODELS[@]}"; do
    log "モデル '${model}' を Lemonade から削除中..."
    local body
    body="$(printf '{"name": "%s", "model": "%s"}' "${model}" "${model}")"
    local resp
    if resp="$(lemonade_curl -X DELETE -H "Content-Type: application/json" \
        -d "${body}" "${LEMONADE_BASE_URL}/api/delete" 2>/dev/null)" \
        && [[ -z "$(printf '%s' "${resp}" | json_tool error 2>/dev/null || true)" ]]; then
      succ "モデル '${model}' を削除しました。"
    else
      err "モデル '${model}' の削除に失敗しました (未登録の可能性があります)。"
      failed=1
    fi
  done
  return "${failed}"
}

case "${ACTION}" in
  delete)
    if delete_models; then
      exit 0
    fi
    exit 1
    ;;
  *)
    if pull_models; then
      exit 0
    fi
    exit 1
    ;;
esac
