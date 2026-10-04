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
OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-32768}"

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
  ./ollama-pull.sh --enable-tools <model_name> [model_name2 ...]

説明:
  Kubernetes 上で稼働中の Ollama サービスに指定された LLM モデルをダウンロード (pull)
  または不要になったモデルを削除 (rm / delete) します。
  また、tools (関数呼び出し) に対応していないモデルに対して、tools サポート用 Modelfile を適用して
  再作成・有効化 (--enable-tools) します。
  モデルデータは Ollama 用の永続ボリューム (PersistentVolumeClaim) に保存・管理されます。

オプション:
  -m, --model <name>       対象のモデル名
  pull, download           ダウンロードのサブコマンド構文 (省略可)
  -d, --delete, --rm       指定されたモデルをクラスタから削除
  rm, delete               指定されたモデルを削除するサブコマンド構文
  --enable-tools           指定されたモデルに tools (関数呼び出し) サポートを追加・再作成
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
  # モデルのダウンロード (tools 非対応の場合は自動で追加)
  ./ollama-pull.sh qwen2.5:0.5b
  ./ollama-pull.sh -m llama3.2:1b
  ./ollama-pull.sh --list

  # モデルへの tools (関数呼び出し) サポート追加
  ./ollama-pull.sh --enable-tools FieldMouse-AI/qwen3.8:27B

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
    --enable-tools)
      ACTION="enable_tools"
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
  elif [[ "${ACTION}" == "enable_tools" ]]; then
    err "tools サポートを追加するモデル名が指定されていません。"
  else
    err "ダウンロードするモデル名が指定されていません。"
  fi
  echo ""
  usage
fi

# Ollama Pod の確認
check_ollama_pod

# ==============================================================================
# モデルの tools (関数呼び出し / Function Calling) サポート確認 & 自動追加
# ==============================================================================
check_model_supports_tools() {
  local model="$1"

  # 1. API 経由で確認 (利用可能な場合)
  if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    local caps
    caps=$(curl -k -s --max-time 5 "https://${OLLAMA_HOSTNAME}/api/show" \
      -d "{\"name\": \"${model}\"}" 2>/dev/null | jq -r '.capabilities[]?' 2>/dev/null || true)
    if [[ -n "${caps}" ]]; then
      if echo "${caps}" | grep -qx "tools"; then
        return 0
      else
        return 1
      fi
    fi
  fi

  # 2. kubectl exec 経由で確認 (フォールバック)
  local show_output
  show_output=$(kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama show "${model}" 2>/dev/null || true)
  if echo "${show_output}" | awk '/^[[:space:]]{2}Capabilities/{flag=1; next} /^[[:space:]]{2}[A-Za-z]/{flag=0} flag {print $1}' | grep -qx "tools"; then
    return 0
  fi

  return 1
}

# モデルのコンテキスト長 (num_ctx) が十分か確認する関数
check_model_context_size() {
  local model="$1"
  local target_ctx="${OLLAMA_NUM_CTX:-32768}"

  local show_output
  show_output=$(kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama show --modelfile "${model}" 2>/dev/null || true)
  local current_ctx
  current_ctx=$(echo "${show_output}" | grep -E "^PARAMETER[[:space:]]+num_ctx[[:space:]]+" | awk '{print $3}' | head -n 1 || true)

  if [[ -n "${current_ctx}" && "${current_ctx}" =~ ^[0-9]+$ ]]; then
    if (( current_ctx >= target_ctx )); then
      return 0
    fi
  fi

  return 1
}

# tools のサポートおよび十分なコンテキスト長 (OLLAMA_NUM_CTX) を保証・再作成する関数
ensure_tools_support() {
  local model="$1"
  local target_ctx="${OLLAMA_NUM_CTX:-32768}"

  local tools_ok=false
  local ctx_ok=false

  log "モデル '${model}' の tools 対応およびコンテキスト長 (目標: ${target_ctx}) を確認中..."
  if check_model_supports_tools "${model}"; then
    tools_ok=true
  fi
  if check_model_context_size "${model}"; then
    ctx_ok=true
  fi

  if [[ "${tools_ok}" == true && "${ctx_ok}" == true ]]; then
    succ "モデル '${model}' は既に tools 対応かつ十分なコンテキスト長 (>= ${target_ctx}) を備えています。"
    return 0
  fi

  local reasons=()
  [[ "${tools_ok}" == false ]] && reasons+=("tools未対応")
  [[ "${ctx_ok}" == false ]] && reasons+=("コンテキスト長不足")
  local reason_str="${reasons[*]}"

  warn "モデル '${model}' は最適化が必要です (${reason_str// /, })。"
  log "最適化用 Modelfile (tools サポート + num_ctx ${target_ctx}) を適用し、モデル '${model}' を再作成します..."

  local tmp_modelfile="/tmp/Modelfile.tools.$$"
  local local_tmp
  local_tmp=$(mktemp)

  cat << EOF > "${local_tmp}"
FROM ${model}

PARAMETER num_ctx ${target_ctx}
PARAMETER stop <|im_start|>
PARAMETER stop <|im_end|>

EOF
  cat << 'EOF' >> "${local_tmp}"
TEMPLATE """{{- if .Messages }}
{{- if or .System .Tools }}<|im_start|>system
{{- if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}

# Tools

You may call one or more functions to assist with the user query.

You are provided with function signatures within <tools></tools> XML tags:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call>
{{- end }}<|im_end|>
{{ end }}
{{- range $i, $_ := .Messages }}
{{- $last := eq (len (slice $.Messages $i)) 1 -}}
{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ else if eq .Role "assistant" }}<|im_start|>assistant
{{ if .Content }}{{ .Content }}
{{- else if .ToolCalls }}<tool_call>
{{ range .ToolCalls }}{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
{{ end }}</tool_call>
{{- end }}{{ if not $last }}<|im_end|>
{{ end }}
{{- else if eq .Role "tool" }}<|im_start|>user
<tool_response>
{{ .Content }}
</tool_response><|im_end|>
{{ end }}
{{- if and (ne .Role "assistant") $last }}<|im_start|>assistant
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
{{ end }}{{ .Response }}{{ if .Response }}<|im_end|>{{ end }}"""
EOF

  # Pod 内へ Modelfile を転送
  if kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- sh -c "cat > ${tmp_modelfile}" < "${local_tmp}"; then
    rm -f "${local_tmp}"
    log "Pod 内で 'ollama create ${model} -f Modelfile' を実行中..."
    if kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama create "${model}" -f "${tmp_modelfile}"; then
      kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- rm -f "${tmp_modelfile}" 2>/dev/null || true
      succ "モデル '${model}' に tools サポートおよびコンテキスト長 ${target_ctx} を正常に適用しました。"
      return 0
    else
      kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- rm -f "${tmp_modelfile}" 2>/dev/null || true
      err "モデル '${model}' への最適化適用 (ollama create) に失敗しました。"
      return 1
    fi
  else
    rm -f "${local_tmp}"
    err "Pod 内への Modelfile 配置に失敗しました。"
    return 1
  fi
}

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

# ==============================================================================
# tools サポート追加アクション実行 (--enable-tools)
# ==============================================================================
if [[ "${ACTION}" == "enable_tools" ]]; then
  total_models=${#MODELS[@]}
  current=0
  failed_models=()

  log "指定されたモデルへの tools サポート追加を開始します (合計: ${total_models} 件)..."

  for model in "${MODELS[@]}"; do
    current=$((current + 1))
    echo ""
    log "[${current}/${total_models}] モデル '${model}' の tools サポート適用中..."
    if ! ensure_tools_support "${model}"; then
      failed_models+=("${model}")
    fi
  done

  if [[ ${#failed_models[@]} -gt 0 ]]; then
    echo ""
    err "以下のモデルへの tools 追加に失敗しました: ${failed_models[*]}"
    exit 1
  fi

  echo ""
  succ "全指定モデルの tools サポート適用処理が完了しました。"
  exit 0
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

  pull_success=false

  # ホスト上のローカルキャッシュからの高速インポートを試行
  if try_import_from_host_cache "${model}"; then
    pull_success=true
  elif [[ "${MODE}" == "exec" ]]; then
    # kubectl exec 経由 (標準の対話的進捗バー)
    if [ -t 1 ]; then
      # 端末で実行されている場合は対話的 TTY を付与
      if kubectl exec -it -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama pull "${model}"; then
        pull_success=true
      fi
    else
      # 非対話環境
      if kubectl exec -i -n "${OLLAMA_NAMESPACE}" deployment/ollama -- ollama pull "${model}"; then
        pull_success=true
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
      pull_success=true
    fi
  fi

  if [[ "${pull_success}" == true ]]; then
    succ "モデル '${model}' の取得が正常に完了しました。"
    # tools (関数呼び出し) サポートの確認 & 未対応時の自動 Modelfile 適用
    ensure_tools_support "${model}" || true
  else
    err "モデル '${model}' の取得に失敗しました。"
    FAILED_MODELS+=("${model}")
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
