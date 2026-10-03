#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-mycluster}"
EXT_DIR="${2:-$(dirname "$0")/extensions/system_stats}"

echo "==> Installing system_stats extension on PostgreSQL cluster..."

# PostgreSQL Pod が稼働しているノードを自動検出 (なければ k3d サーバーノード一覧)
KEYCLOAK_NS="${KEYCLOAK_NAMESPACE:-keycloak}"
PG_NODES=$(kubectl get pods -n "$KEYCLOAK_NS" -l 'app.kubernetes.io/name in (postgresql,postgresql-ha)' -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null || true)
if [ -n "$PG_NODES" ]; then
  NODES=$(echo "$PG_NODES" | tr ' ' '\n' | sort -u)
else
  NODES=$(sudo podman ps --filter "name=k3d-${CLUSTER_NAME}-" --format "{{ .Names }}")
fi

for node in $NODES; do
  echo "--> Processing node: $node"
  
  # containerd からそのノードで動いている全 postgresql コンテナの ID を取得
  CIDS=$(sudo podman exec "$node" crictl ps --name postgresql -q 2>/dev/null || true)
  if [ -z "$CIDS" ]; then
    echo "    No postgresql container found on $node, skipping."
    continue
  fi

  # ファイルをノード一時領域にコピー (ノード単位で1回)
  sudo podman cp "${EXT_DIR}/system_stats.so" "${node}:/tmp/system_stats.so"
  sudo podman cp "${EXT_DIR}/system_stats.control" "${node}:/tmp/system_stats.control"
  for sql in "${EXT_DIR}"/system_stats--*.sql; do
    sudo podman cp "$sql" "${node}:/tmp/$(basename "$sql")"
  done
  
  for CID in $CIDS; do
    POD_NAME=$(sudo podman exec "$node" crictl inspect "$CID" 2>/dev/null | jq -r '.status.labels["io.kubernetes.pod.name"] // empty' 2>/dev/null || echo "$CID")
    echo "    Processing container $CID (pod: $POD_NAME) on $node"

    # inspect 出力をホスト側で解析してコンテナの PID を取得
    PID=$(sudo podman exec "$node" crictl inspect "$CID" 2>/dev/null | jq -r .info.pid 2>/dev/null || true)
    if [ -z "$PID" ] || [ "$PID" = "null" ]; then
      echo "      Cannot get PID for container $CID on $node, skipping."
      continue
    fi
    
    # mountinfo からルートファイルシステムのスナップショットパスを取得
    RAW_PATH=$(sudo podman exec "$node" grep " / ro," "/proc/$PID/mountinfo" 2>/dev/null | head -1 | awk '{print $4}' || true)
    if [ -z "$RAW_PATH" ]; then
      echo "      Cannot find root snapshot in mountinfo for container $CID on $node, skipping."
      continue
    fi
    
    # ホスト側の Podman ボリュームパス (.../_data) をコンテナ内の k3s パス (/var/lib/rancher/k3s) に変換
    SNAP=$(echo "$RAW_PATH" | sed 's|.*/_data|/var/lib/rancher/k3s|' | sed 's|/root/|/|')
    
    # 置換後のパスが存在しない場合、スナップショット番号で検索
    if ! sudo podman exec "$node" test -d "$SNAP/opt/bitnami/postgresql" 2>/dev/null; then
      SNAP_NUM=$(basename "$RAW_PATH")
      FOUND_PATH=$(sudo podman exec "$node" find /var/lib/rancher/k3s -name "$SNAP_NUM" -type d 2>/dev/null | head -1 || true)
      if [ -n "$FOUND_PATH" ]; then
        SNAP="$FOUND_PATH"
      fi
    fi
    
    if ! sudo podman exec "$node" test -d "$SNAP/opt/bitnami/postgresql" 2>/dev/null; then
      echo "      ERROR: Snapshot path not found on $node: $SNAP"
      continue
    fi
    
    echo "      Found snapshot path: $SNAP for pod $POD_NAME on $node"
    
    # スナップショット内の lib と share/extension に配置
    sudo podman exec "$node" sh -c "
      mkdir -p '${SNAP}/opt/bitnami/postgresql/lib' '${SNAP}/opt/bitnami/postgresql/share/extension'
      cp /tmp/system_stats.so '${SNAP}/opt/bitnami/postgresql/lib/'
      chmod 755 '${SNAP}/opt/bitnami/postgresql/lib/system_stats.so'
      cp /tmp/system_stats.control '${SNAP}/opt/bitnami/postgresql/share/extension/'
      cp /tmp/system_stats--*.sql '${SNAP}/opt/bitnami/postgresql/share/extension/'
      chmod 644 '${SNAP}/opt/bitnami/postgresql/share/extension/system_stats'*
    "
    echo "      Files deployed successfully for pod $POD_NAME on $node."
  done

  # ノード内の一時ファイルをクリーンアップ
  sudo podman exec "$node" sh -c "
    rm -f /tmp/system_stats*
    rm -rf /var/lib/containers 2>/dev/null || true
  "
done

echo "==> Activating system_stats extension in PostgreSQL databases..."
KEYCLOAK_NS="${KEYCLOAK_NAMESPACE:-keycloak}"
for db in postgres template1 keycloak grafana harbor; do
  echo "    Activating system_stats on database: $db"
  kubectl exec -n "$KEYCLOAK_NS" "${PG_PRIMARY_POD:-keycloak-pg-postgresql-ha-postgresql-0}" -c postgresql -- \
    env PGPASSWORD="${PGPASSWORD:-keycloak-pg-2026}" psql -U postgres -d "$db" -c "CREATE EXTENSION IF NOT EXISTS system_stats;" || true
done

echo "==> Granting monitor_system_stats role to application users..."
kubectl exec -n "$KEYCLOAK_NS" "${PG_PRIMARY_POD:-keycloak-pg-postgresql-ha-postgresql-0}" -c postgresql -- \
  env PGPASSWORD="${PGPASSWORD:-keycloak-pg-2026}" psql -U postgres -c "GRANT monitor_system_stats TO grafana, harbor, keycloak;" || true

echo "==> system_stats extension installed and verified successfully!"
