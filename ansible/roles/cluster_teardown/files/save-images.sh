#!/usr/bin/env bash
set -euo pipefail

# K3D クラスタイメージの Podman 保存・一覧更新スクリプト
# 使用方法: save-images.sh [images_file]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_FILE="${1:-${SCRIPT_DIR}/../../../../images.txt}"

log() { echo -e "\033[36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# 二重実行防止チェック
if [[ "${_SAVED_IMAGES_DONE:-0}" == "1" ]]; then
  log "イメージ保存は既に実行済みのためスキップします"
  exit 0
fi

# クラスタが稼働しており kubectl で接続可能かチェック
if ! kubectl cluster-info &>/dev/null; then
  log "Kubernetes クラスタに接続できないため、イメージ保存をスキップします"
  exit 0
fi

log "クラスタのイメージ一覧を取得中..."

# クラスタで使用中のイメージを取得
RUNNING_IMAGES=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | sort -u || true)

if [[ -z "$RUNNING_IMAGES" ]]; then
  warn "実行中のイメージが見つかりません"
  exit 0
fi

# Docker Hub エイリアス正規化キー (registry-1 / 短縮名 → docker.io)
# 異なるレジストリ (quay.io 等) は潰さない
normalize_image_key() {
  local img="$1"
  local first="${img%%/*}"
  if [[ "$first" == "registry-1.docker.io" ]]; then
    img="docker.io/${img#*/}"
    first="docker.io"
  fi
  if [[ "$first" != *"."* && "$first" != *":"* && "$first" != "localhost" ]]; then
    if [[ "$img" == */* ]]; then
      img="docker.io/${img}"
    else
      img="docker.io/library/${img}"
    fi
  fi
  # docker.io/library/X と docker.io/X を同一視
  if [[ "$img" == docker.io/library/* ]]; then
    img="docker.io/${img#docker.io/library/}"
  fi
  printf '%s' "$img"
}

# 既存の images.txt があれば読み込んでマージ (未起動コンポーネントのイメージ欠落を防止)
EXISTING_IMAGES=""
if [[ -f "$IMAGES_FILE" ]]; then
  EXISTING_IMAGES=$(grep -v '^#' "$IMAGES_FILE" | grep -v '^[[:space:]]*$' || true)
fi

# 正規化キーで重複排除 (初出の表記を保持: RUNNING 優先 → EXISTING)
declare -A SEEN_IMAGE_KEYS
NORMALIZED_IMAGES=""
while IFS= read -r _img; do
  [[ -z "$_img" ]] && continue
  _key=$(normalize_image_key "$_img")
  if [[ -z "${SEEN_IMAGE_KEYS[$_key]:-}" ]]; then
    SEEN_IMAGE_KEYS["$_key"]=1
    NORMALIZED_IMAGES+="${_img}"$'\n'
  fi
done < <(printf "%s\n%s\n" "$RUNNING_IMAGES" "$EXISTING_IMAGES")

ALL_IMAGES=$(printf '%s' "$NORMALIZED_IMAGES" | grep -v '^[[:space:]]*$' | sort -u || true)

log "イメージ一覧ファイルを更新中: $IMAGES_FILE"

# カテゴリ別に出力
{
  echo "# K3D クラスタ用イメージ一覧"
  echo "# stop.sh で自動更新 ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "# 各行にイメージ名を記述 (タグなしで latest が使われる)"
  echo "# 空行と # で始まる行は無視される"
  echo ""

  echo "# 基本イメージ"
  echo "$ALL_IMAGES" | grep -E "^(busybox|.*mc|.*oauth2-proxy|.*curl|.*os-shell)" || true
  echo ""

  echo "# K3s / K3D コンポーネント"
  echo "$ALL_IMAGES" | grep -E "^rancher/(klipper-|local-path|mirrored-)" || true
  echo ""

  echo "# Rancher"
  echo "$ALL_IMAGES" | grep -E "^rancher/(rancher|fleet|shell|turtles|cluster-api|system-upgrade|kuberlr)" || true
  echo ""

  echo "# cert-manager"
  echo "$ALL_IMAGES" | grep -E "(cert-manager)" || true
  echo ""

  echo "# Keycloak & PostgreSQL / pgAdmin"
  echo "$ALL_IMAGES" | grep -E "(keycloak|postgresql|postgres-exporter|pgadmin)" || true
  echo ""

  echo "# Ceph (Rook-Ceph & CSI)"
  echo "$ALL_IMAGES" | grep -E "(rook-ceph|rook/ceph|ceph/ceph|cephcsi|sig-storage/csi-)" || true
  echo ""

  echo "# Harbor (Enterprise Registry)"
  echo "$ALL_IMAGES" | grep -E "(goharbor|harbor)" || true
  echo ""

  echo "# KubeVirt & CDI"
  echo "$ALL_IMAGES" | grep -E "(kubevirt|cdi-)" || true
  echo ""

  echo "# モニタリング (Prometheus / Grafana)"
  echo "$ALL_IMAGES" | grep -E "(prometheus|grafana|alertmanager|node-exporter|kube-state-metrics|k8s-sidecar)" || true
  echo ""

  # 上記のいずれにも分類されなかったイメージ
  OTHER_IMAGES=$(echo "$ALL_IMAGES" | grep -v -E "(busybox|.*mc|.*oauth2-proxy|.*curl|.*os-shell)|^rancher/(klipper-|local-path|mirrored-)|^rancher/(rancher|fleet|shell|turtles|cluster-api|system-upgrade|kuberlr)|(cert-manager)|(keycloak|postgresql|postgres-exporter|pgadmin)|(rook-ceph|rook/ceph|ceph/ceph|cephcsi|sig-storage/csi-)|(goharbor|harbor)|(kubevirt|cdi-)|(prometheus|grafana|alertmanager|node-exporter|kube-state-metrics|k8s-sidecar)" || true)
  if [[ -n "$OTHER_IMAGES" ]]; then
    echo "# その他"
    echo "$OTHER_IMAGES"
    echo ""
  fi
} > "$IMAGES_FILE"

log "イメージ一覧を更新しました: $IMAGES_FILE"

# 各イメージを podman に保存 (未登録イメージのみ)
log "Podman ローカルストレージにイメージを保存中..."
SAVED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

while IFS= read -r IMAGE; do
  [[ -z "$IMAGE" ]] && continue

  # 短縮名 (レジストリホストがない場合) を docker.io に正規化
  IMAGE_FQDN="$IMAGE"
  FIRST_PART="${IMAGE%%/*}"
  if [[ "$FIRST_PART" != *"."* && "$FIRST_PART" != *":"* && "$FIRST_PART" != "localhost" ]]; then
    if [[ "$IMAGE" != *"/"* ]]; then
      IMAGE_FQDN="docker.io/library/$IMAGE"
    else
      IMAGE_FQDN="docker.io/$IMAGE"
    fi
  fi

  # podman に存在するかチェック (元名または FQDN でチェック)
  if sudo podman image exists "$IMAGE" 2>/dev/null || sudo podman image exists "$IMAGE_FQDN" 2>/dev/null; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # 1. クラスタノード (containerd) から直接イメージ抽出・保存を試行
  saved_from_node=false
  for node in $(sudo podman ps --filter "label=app=k3d" --format "{{.Names}}" 2>/dev/null | grep -E "server-[0-9]|agent-[0-9]" || true); do
    for target in "$IMAGE" "$IMAGE_FQDN"; do
      if sudo podman exec "$node" ctr --namespace k8s.io images check "name==$target" 2>/dev/null | grep -q "$target" || \
         sudo podman exec "$node" ctr --namespace k8s.io images ls -q 2>/dev/null | grep -q "^${target}$"; then
        log "  クラスタノード ($node) から保存中: $IMAGE"
        if sudo podman exec "$node" ctr --namespace k8s.io images export - "$target" 2>/dev/null | sudo podman load 2>/dev/null; then
          saved_from_node=true
          SAVED_COUNT=$((SAVED_COUNT + 1))
          break 2
        fi
      fi
    done
  done

  if [[ "$saved_from_node" == "true" ]]; then
    continue
  fi

  # 2. ローカル参照 (localhost, 127.0.0.1 等) の判定
  # 外部レジストリが存在しないため、クラスタノード未検出時は外部 pull を試行せずスキップ
  if [[ "$FIRST_PART" == "localhost" || "$FIRST_PART" == "127.0.0.1"* || "$FIRST_PART" == *":5000"* || "$FIRST_PART" == *".local"* ]]; then
    warn "  ローカル参照イメージが見つからないためスキップします (ノード内未検出): $IMAGE"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # 3. 外部レジストリからの pull 試行
  log "  podman に保存中 (新規): $IMAGE"
  PULL_OUTPUT=""
  if PULL_OUTPUT=$(sudo podman pull --quiet "$IMAGE_FQDN" 2>&1); then
    SAVED_COUNT=$((SAVED_COUNT + 1))
  else
    warn "  podman 保存失敗: $IMAGE (${PULL_OUTPUT})"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done <<< "$ALL_IMAGES"

log "イメージ保存完了 (新規保存: ${SAVED_COUNT} 件, 既存スキップ: ${SKIPPED_COUNT} 件, 失敗: ${FAILED_COUNT} 件)"
export _SAVED_IMAGES_DONE=1

