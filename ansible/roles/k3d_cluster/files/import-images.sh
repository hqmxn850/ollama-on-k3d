#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# ==============================================================================
# ホスト Podman から K3D クラスタ (全ノード containerd) への
# コンテナイメージ一括事前インポート (完全ローカルキャッシュ保証)
# 使用方法: import-images.sh [cluster_name] [images_file] [--force] [--batch-size N]
#
# ホストの Podman ローカルストレージにキャッシュされたコンテナイメージを、
# K3D クラスタ内の全ノード (server / agent) の containerd (k8s.io 名前空間) へ
# 最序盤で一括事前インポート (--mode direct) し、各ノードでの重複ダウンロードを完全に排除します。
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# プロジェクトルートの検出
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
  PROJECT_ROOT="${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/../../../../config.env" ]]; then
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
else
  PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# 共通関数の読み込み
if [[ -f "${PROJECT_ROOT}/lib/common.sh" ]]; then
  source "${PROJECT_ROOT}/lib/common.sh"
fi

# 標準出力が端末 (tty) かどうかを判定
ORIG_STDOUT_IS_TTY=false
if [ -t 1 ]; then
  ORIG_STDOUT_IS_TTY=true
fi

# 端末 (/dev/tty) が存在し、標準出力がリダイレクトされている場合はリアルタイムでコンソールにも複製表示
_print_msg() {
  local prefix="$1"
  shift
  local msg="${prefix} $*"
  echo -e "$msg"
  if [ "$ORIG_STDOUT_IS_TTY" = false ] && [[ -c /dev/tty ]] && [ -w /dev/tty ]; then
    ( echo -e "$msg" > /dev/tty ) 2>/dev/null || true
  fi
}

log() { _print_msg "\033[36m[INFO]\033[0m" "$@"; }
warn() { _print_msg "\033[33m[WARN]\033[0m" "$@"; }
err() { _print_msg "\033[31m[ERROR]\033[0m" "$@"; }
succ() { _print_msg "\033[32m[SUCCESS]\033[0m" "$@"; }
info_prog() { _print_msg "  \033[34m[PROGRESS]\033[0m" "$@"; }

# 引数解析
CLUSTER_NAME=""
IMAGES_FILE=""
FORCE_IMPORT=false
BATCH_SIZE=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)
      FORCE_IMPORT=true
      shift
      ;;
    --batch-size|-b)
      BATCH_SIZE="$2"
      shift 2
      ;;
    *)
      if [[ -z "$CLUSTER_NAME" ]]; then
        CLUSTER_NAME="$1"
      elif [[ -z "$IMAGES_FILE" ]]; then
        IMAGES_FILE="$1"
      fi
      shift
      ;;
  esac
done

# config.env からのフォールバック読み込み
if [[ -f "${PROJECT_ROOT}/config.env" ]]; then
  ENV_CLUSTER_NAME=$(grep -E '^[[:space:]]*CLUSTER_NAME=' "${PROJECT_ROOT}/config.env" | cut -d'=' -f2- | tr -d '"'\'' ' || true)
  if [[ -z "$CLUSTER_NAME" && -n "$ENV_CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$ENV_CLUSTER_NAME"
  fi
  ENV_ARCHIVE_DIR=$(grep -E '^[[:space:]]*IMAGE_ARCHIVE_DIR=' "${PROJECT_ROOT}/config.env" | cut -d'=' -f2- | tr -d '"'\'' ' || true)
  if [[ -n "$ENV_ARCHIVE_DIR" ]]; then
    IMAGE_ARCHIVE_DIR="$ENV_ARCHIVE_DIR"
  fi
fi

CLUSTER_NAME="${CLUSTER_NAME:-mycluster}"
IMAGE_ARCHIVE_DIR="${IMAGE_ARCHIVE_DIR:-/var/tmp/k3d-image-import}"
IMAGES_FILE="${IMAGES_FILE:-${PROJECT_ROOT}/images.txt}"

log "=== K3D コンテナイメージ一括事前インポート (完全ローカルキャッシュ保証) ==="
log "対象クラスタ: ${CLUSTER_NAME}"
log "イメージ一覧: ${IMAGES_FILE}"
log "バッチサイズ: ${BATCH_SIZE}"
log "強制インポート: ${FORCE_IMPORT}"
log "正規化アーカイブ保存先: ${IMAGE_ARCHIVE_DIR}"

# 前提コマンドの確認
for cmd in podman k3d skopeo; do
  if ! command -v "$cmd" &>/dev/null; then
    err "必須コマンド '$cmd' が見つかりません。"
    exit 1
  fi
done

# イメージ一覧ファイルの存在確認
# images.txt は stop.sh / cluster_teardown 時に自動生成されるキャッシュ用ファイル
# (gitignore 対象) のため、初回デプロイ時には存在しない。欠落時は事前インポートを
# スキップし、デプロイを継続する。
if [[ ! -f "$IMAGES_FILE" ]]; then
  warn "イメージ一覧ファイルが見つかりません。事前インポートをスキップします: $IMAGES_FILE"
  exit 0
fi

# 残存する k3d-tools コンテナの安全な事前削除
sudo podman rm -f "k3d-${CLUSTER_NAME}-tools" 2>/dev/null || true

# クラスタノード (server / agent) の検出 (serverlb は containerd を持たないため除外)
NODES=($(sudo podman ps --filter "label=app=k3d" --filter "label=k3d.cluster=${CLUSTER_NAME}" --format "{{.Names}}" | grep -E "server-[0-9]|agent-[0-9]" | sort))
if [[ ${#NODES[@]} -eq 0 ]]; then
  err "K3D クラスタ '${CLUSTER_NAME}' のワーカー/サーバーノードが見つかりません。クラスタが起動しているか確認してください。"
  exit 1
fi

log "検出されたクラスタノード (${#NODES[@]} 台): ${NODES[*]}"

# images.txt から対象イメージを抽出
RAW_IMAGES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  clean_line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -n "$clean_line" ]] && RAW_IMAGES+=("$clean_line")
done < "$IMAGES_FILE"

TOTAL_IMAGES=${#RAW_IMAGES[@]}
if [[ $TOTAL_IMAGES -eq 0 ]]; then
  warn "インポート対象のイメージが images.txt に見つかりませんでした。"
  exit 0
fi

log "インポート対象イメージ総数: ${TOTAL_IMAGES} 件"

# 1. ホスト Podman でのキャッシュ存在確認 & 自動 pull & 完全修飾名解決
log "[1/3] ホスト Podman ローカルストレージのキャッシュ検証 & 完全修飾名解決中..."
RESOLVED_IMAGES=()
PULLED_COUNT=0

for img in "${RAW_IMAGES[@]}"; do
  # ホストに存在するか確認し、未キャッシュなら pull で自己修復
  if ! sudo podman image exists "$img" 2>/dev/null && \
     ! sudo podman image exists "docker.io/$img" 2>/dev/null && \
     ! sudo podman image exists "docker.io/library/$img" 2>/dev/null; then
    # ローカル参照 (localhost/, 127.0.0.1: 等) の場合は外部 pull をスキップ
    first_part="${img%%/*}"
    if [[ "$first_part" == "localhost" || "$first_part" == "127.0.0.1"* || "$first_part" == *":5000"* || "$first_part" == *".local"* ]]; then
      warn "ローカルイメージがホスト Podman に未登録のためスキップします: ${img}"
      continue
    fi
    log "ホストに未キャッシュのイメージを検出: ${img} -> ダウンロード中..."
    if sudo podman pull "$img" 2>/dev/null; then
      PULLED_COUNT=$((PULLED_COUNT + 1))
    else
      warn "イメージのダウンロードに失敗しました (スキップ): ${img}"
      continue
    fi
  fi

  # Podman 上の正確な完全修飾名 (RepoTag) を取得
  fqin=$(sudo podman inspect "$img" -f '{{index .RepoTags 0}}' 2>/dev/null || true)
  if [[ -z "$fqin" || "$fqin" == "<no value>" ]]; then
    fqin=$(sudo podman inspect "docker.io/$img" -f '{{index .RepoTags 0}}' 2>/dev/null || true)
  fi
  if [[ -z "$fqin" || "$fqin" == "<no value>" ]]; then
    fqin=$(sudo podman inspect "docker.io/library/$img" -f '{{index .RepoTags 0}}' 2>/dev/null || true)
  fi
  if [[ -z "$fqin" || "$fqin" == "<no value>" ]]; then
    fqin="$img"
  fi

  RESOLVED_IMAGES+=("$fqin")
done

# 重複の除去
readarray -t UNIQUE_IMAGES < <(printf '%s\n' "${RESOLVED_IMAGES[@]}" | sort -u)

if [[ $PULLED_COUNT -gt 0 ]]; then
  succ "新たに ${PULLED_COUNT} 件のイメージをホスト Podman にキャッシュしました。"
else
  log "全イメージが既にホスト Podman にキャッシュされています。"
fi

# 2. 各ノード (containerd) での既存イメージ判定
log "[2/3] クラスタ内ノード (containerd) のインポート状況を確認中..."

declare -A NODE_IMAGE_MAP
for node in "${NODES[@]}"; do
  existing_names=$(sudo podman exec "$node" crictl images --output json 2>/dev/null | jq -r '.images[].repoTags[]?' 2>/dev/null || true)
  while IFS= read -r name; do
    [[ -n "$name" ]] && NODE_IMAGE_MAP["${node}_${name}"]=1
  done <<< "$existing_names"
done

IMAGES_TO_IMPORT=()
ALREADY_CACHED=0

for img in "${UNIQUE_IMAGES[@]}"; do
  if [[ "$FORCE_IMPORT" == "true" ]]; then
    IMAGES_TO_IMPORT+=("$img")
    continue
  fi

  # 全ノードに存在するか確認
  all_nodes_have_it=true
  for node in "${NODES[@]}"; do
    has_it=false
    # 1. 完全一致
    if [[ -n "${NODE_IMAGE_MAP["${node}_${img}"]:-}" ]]; then
      has_it=true
    else
      # 2. docker.io/ または library/ プレフィックスのバリエーション
      img_strip="${img#docker.io/}"
      img_strip_lib="${img_strip#library/}"
      if [[ -n "${NODE_IMAGE_MAP["${node}_${img_strip}"]:-}" ]] || \
         [[ -n "${NODE_IMAGE_MAP["${node}_${img_strip_lib}"]:-}" ]] || \
         [[ -n "${NODE_IMAGE_MAP["${node}_docker.io/${img_strip_lib}"]:-}" ]]; then
        has_it=true
      fi
    fi

    if [[ "$has_it" == "false" ]]; then
      all_nodes_have_it=false
      break
    fi
  done

  if [[ "$all_nodes_have_it" == "true" ]]; then
    ALREADY_CACHED=$((ALREADY_CACHED + 1))
  else
    IMAGES_TO_IMPORT+=("$img")
  fi
done

log "既存インポート済み: ${ALREADY_CACHED} / ${#UNIQUE_IMAGES[@]} 件"
log "インポート対象: ${#IMAGES_TO_IMPORT[@]} 件"

if [[ ${#IMAGES_TO_IMPORT[@]} -eq 0 ]]; then
  succ "すべてのコンテナイメージがクラスタ全ノードの containerd に既にインポート済みです。スキップします。"
  exit 0
fi

# hybrid manifest 正規化 (OCI manifest + Docker layer mediaType 組み合わせの修復)
# 上流イメージが OCI manifest に Docker の layer mediaType を混ぜた非規格 (hybrid) 配布の場合、
# podman save / skopeo copy が manifest 変換エラーで失敗し、k3d image import が恒久的に失敗する。
# containers-storage 内の manifest のみを正規 OCI layer mediaType へ書き換えることで、
# layer blob (実体) は一切再生成せず (digest 不変)、以降の podman save / k3d import を正常化する。
# 戻り値: 0=正規化実施, 1=エラー, 2=manifest 不在, 3=hybrid でなく正規化不要
normalize_hybrid_manifest() {
  local img="$1"
  local img_id graph_root backup_dir rc

  img_id=$(sudo podman image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)
  if [[ -z "$img_id" ]]; then
    warn "    [NORMALIZE] image ID を取得できません: $img"
    return 2
  fi

  graph_root=$(sudo podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "/var/lib/containers/storage")
  backup_dir="${IMAGE_ARCHIVE_DIR}/manifest-backup-$(date +%Y%m%d-%H%M%S)-${img_id:0:12}"

  sudo env LC_ALL=C.UTF-8 python3 - "$img" "$graph_root" "$img_id" "$backup_dir" <<'PY_NORMALIZE_HYBRID'
import base64, hashlib, json, os, shutil, sys, time

img, graph_root, img_id, backup_dir = sys.argv[1:5]
img_dir = os.path.join(graph_root, "overlay-images", img_id)
manifest_path = os.path.join(img_dir, "manifest")
images_json_path = os.path.join(graph_root, "overlay-images", "images.json")

if not os.path.isfile(manifest_path):
    print("manifest not found: %s" % manifest_path)
    sys.exit(2)

with open(manifest_path, "rb") as fh:
    data = fh.read()

try:
    manifest = json.loads(data)
except Exception as exc:  # noqa: BLE001
    print("manifest parse error: %s" % exc)
    sys.exit(1)

media_type = manifest.get("mediaType", "")
layer_types = {l.get("mediaType", "") for l in manifest.get("layers", [])}
docker_layers = [m for m in layer_types if m.startswith("application/vnd.docker.")]

if not media_type.startswith("application/vnd.oci.image.manifest") or not docker_layers:
    # docker manifest + docker layers (規格準拠) や既に正規 OCI の場合は対象外
    print("not a hybrid manifest (mediaType=%s)" % media_type)
    sys.exit(3)

MAP = {
    b"application/vnd.docker.image.rootfs.diff.tar.gzip": b"application/vnd.oci.image.layer.v1.tar+gzip",
    b"application/vnd.docker.image.rootfs.diff.tar.zstd": b"application/vnd.oci.image.layer.v1.tar+zstd",
    b"application/vnd.docker.image.rootfs.diff.tar": b"application/vnd.oci.image.layer.v1.tar",
    b"application/vnd.docker.image.rootfs.foreign.diff.tar.gzip": b"application/vnd.oci.image.layer.nondistributable.v1.tar+gzip",
}
new = data
for old, oci in MAP.items():
    new = new.replace(old, oci)
if new == data:
    print("no docker layer mediaType mapping applied")
    sys.exit(3)

new_manifest = json.loads(new)
if not all(l.get("mediaType", "").startswith("application/vnd.oci.image.layer") for l in new_manifest.get("layers", [])):
    print("normalization incomplete: docker layer mediaType remains")
    sys.exit(1)
if [l.get("digest") for l in new_manifest.get("layers", [])] != [l.get("digest") for l in manifest.get("layers", [])] \
        or new_manifest.get("config", {}).get("digest") != manifest.get("config", {}).get("digest"):
    print("digest changed unexpectedly: abort")
    sys.exit(1)

old_digest = "sha256:" + hashlib.sha256(data).hexdigest()
new_digest = "sha256:" + hashlib.sha256(new).hexdigest()

os.makedirs(backup_dir, exist_ok=True)
shutil.copy2(manifest_path, os.path.join(backup_dir, "manifest.orig"))
if os.path.isfile(images_json_path):
    shutil.copy2(images_json_path, os.path.join(backup_dir, "images.json.orig"))

with open(manifest_path, "wb") as fh:
    fh.write(new)

# digest キー付き big-data ファイル名の更新 (filename = "=" + base64(key))
old_key = "manifest-sha256:" + old_digest.split(":", 1)[1]
new_key = "manifest-sha256:" + new_digest.split(":", 1)[1]
old_file = os.path.join(img_dir, "=" + base64.b64encode(old_key.encode()).decode())
new_file = os.path.join(img_dir, "=" + base64.b64encode(new_key.encode()).decode())
if os.path.isfile(old_file):
    os.rename(old_file, new_file)
with open(new_file, "wb") as fh:
    fh.write(new)

if os.path.isfile(images_json_path):
    with open(images_json_path) as fh:
        images = json.load(fh)
    for entry in images:
        if entry.get("id") != img_id:
            continue
        if entry.get("digest") == old_digest:
            entry["digest"] = new_digest
        if old_key in (entry.get("big-data-names") or []):
            entry["big-data-names"] = [new_key if n == old_key else n for n in entry["big-data-names"]]
        entry["big-data-sizes"] = {k: (len(new) if k in (old_key, "manifest") else v)
                                   for k, v in (entry.get("big-data-sizes") or {}).items()}
        entry["big-data-digests"] = {new_key if k == old_key else k:
                                     (new_digest if k in (old_key, "manifest") else v)
                                     for k, v in (entry.get("big-data-digests") or {}).items()}
    with open(images_json_path, "w") as fh:
        json.dump(images, fh)

print("normalized: %s layers=%d %s -> %s" % (img, len(new_manifest.get("layers", [])), old_digest[:19], new_digest[:19]))
print("backup: %s" % backup_dir)
PY_NORMALIZE_HYBRID
  rc=$?
  if [[ $rc -eq 0 ]]; then
    succ "    [NORMALIZE] hybrid manifest を正規 OCI に正規化しました: $img"
  elif [[ $rc -eq 3 ]]; then
    log "    [NORMALIZE] 正規化不要 (hybrid manifest ではありません): $img"
  else
    warn "    [NORMALIZE] 正規化に失敗しました (rc=$rc): $img"
  fi
  return $rc
}

# 3. バッチ単位での k3d image import (--mode direct) 実行
log "[3/3] ホスト Podman から全ノード containerd へ一括インポートを開始 (--mode direct)..."

TOTAL_TO_IMPORT=${#IMAGES_TO_IMPORT[@]}
IMPORTED_COUNT=0
BATCH_NUM=0
TOTAL_BATCHES=$(( (TOTAL_TO_IMPORT + BATCH_SIZE - 1) / BATCH_SIZE ))

for ((i = 0; i < TOTAL_TO_IMPORT; i += BATCH_SIZE)); do
  BATCH_NUM=$((BATCH_NUM + 1))
  CURRENT_BATCH=("${IMAGES_TO_IMPORT[@]:i:BATCH_SIZE}")
  BATCH_COUNT=${#CURRENT_BATCH[@]}

  log "--> バッチ [${BATCH_NUM}/${TOTAL_BATCHES}] (${BATCH_COUNT} 件) をクラスタ全ノードへコピー・インポート中..."
  for b_img in "${CURRENT_BATCH[@]}"; do
    info_prog "イメージ: $b_img"
  done

  START_TIME=$(date +%s)
  local_status=0
  sudo k3d image import --cluster "${CLUSTER_NAME}" --mode direct "${CURRENT_BATCH[@]}" 2>&1 | iconv -c -t UTF-8 -f UTF-8 | while IFS= read -r line; do
    echo "$line"
    if [ "$ORIG_STDOUT_IS_TTY" = false ] && [[ -c /dev/tty ]] && [ -w /dev/tty ]; then
      ( echo "    $line" > /dev/tty ) 2>/dev/null || true
    fi
  done || local_status=$?

  if [[ $local_status -eq 0 ]]; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    succ "バッチ [${BATCH_NUM}/${TOTAL_BATCHES}] インポート完了 (${ELAPSED} 秒)"
    IMPORTED_COUNT=$((IMPORTED_COUNT + BATCH_COUNT))
  else
    warn "バッチ [${BATCH_NUM}/${TOTAL_BATCHES}] の一部で警告/失敗が発生しました。個別フォールバック試行します..."
    for single_img in "${CURRENT_BATCH[@]}"; do
      info_prog "個別コピー試行: $single_img"
      single_status=0
      sudo k3d image import --cluster "${CLUSTER_NAME}" --mode direct "$single_img" 2>&1 | iconv -c -t UTF-8 -f UTF-8 | while IFS= read -r line; do
        echo "$line"
        if [ "$ORIG_STDOUT_IS_TTY" = false ] && [[ -c /dev/tty ]] && [ -w /dev/tty ]; then
          ( echo "    $line" > /dev/tty ) 2>/dev/null || true
        fi
      done || single_status=$?

      if [[ $single_status -eq 0 ]]; then
        succ "    [OK] $single_img"
        IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
      elif normalize_hybrid_manifest "$single_img" && \
           sudo k3d image import --cluster "${CLUSTER_NAME}" --mode direct "$single_img" 2>&1 | iconv -c -t UTF-8 -f UTF-8; then
        succ "    [OK] $single_img (hybrid manifest 正規化後に再インポート成功)"
        IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
      else
        warn "    [FAILED] $single_img (スキップ)"
      fi
    done
  fi
done

log "=============================================================================="
succ "コンテナイメージの事前インポートが完了しました！"
succ "インポート実施: ${IMPORTED_COUNT} 件 / 事前キャッシュ済み: ${ALREADY_CACHED} 件 / 合計: ${#UNIQUE_IMAGES[@]} 件"
log "=============================================================================="
