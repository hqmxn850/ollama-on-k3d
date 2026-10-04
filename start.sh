#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
VERSIONS_ENV="${SCRIPT_DIR}/versions.env"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory.ini"
PLAYBOOK="${ANSIBLE_DIR}/playbooks/site.yml"
export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"
export ANSIBLE_HOME="${ANSIBLE_DIR}/.ansible"

# 共通関数 (log/warn/err/ensure_command) を読み込み
source "${SCRIPT_DIR}/lib/common.sh"

DEFAULT_EMAIL_DOMAIN="philippines.com.ph"

show_help() {
  cat << EOF
使用方法: $(basename "$0") [オプション...] [ansible-playbook オプション...]

Ollama on K3D クラスタ自動デプロイメント スクリプト (Ansible 版)

このスクリプトは 'config.env' を読み込み、設定値を Ansible 変数に変換して
Ansible Playbook ('ansible/playbooks/site.yml') を実行します。
Server 1ノード (8コア: CORE/SSO/監視基盤) と Worker 1ノード (24コア: AI/LLM基盤) の
2ノード構成で、Ollama, OGA, Open WebUI, Keycloak, Rancher, Grafana を自動デプロイします。
デプロイ完了後、各コンポーネントの最新バージョン確認を行い、アップグレード可能な場合は対話形式で問い合わせます。

主なオプション例:
  --tags <TAG>          特定のロール/フェーズのみ実行 (例: --tags ollama, --tags open_webui)
  --skip-tags <TAG>     特定のタスクをスキップ
  --check               ドライラン (変更を行わずに実行内容を確認)
  --skip-upgrade-check  デプロイ完了後のアップグレード判定・問い合わせをスキップ
  -y, --yes             アップグレード可能な場合、問い合わせずに自動アップグレードを実行
  -v, -vv, -vvv         Ansible 詳細ログ出力
  -h, --help            このヘルプメッセージを表示
EOF
}

# オプションの解析
CHECK_MODE=false
SKIP_UPGRADE_CHECK=false
AUTO_UPGRADE=false
ANSIBLE_ARGS=()

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      exit 0
      ;;
    --check)
      CHECK_MODE=true
      ANSIBLE_ARGS+=("$arg")
      ;;
    --skip-upgrade-check)
      SKIP_UPGRADE_CHECK=true
      ;;
    -y|--yes)
      AUTO_UPGRADE=true
      ;;
    *)
      ANSIBLE_ARGS+=("$arg")
      ;;
  esac
done

# --- 0. 前提条件チェック & CLI ツール最新化 ---
ensure_command ansible-playbook ansible || exit 1
ensure_command jq jq || exit 1
ensure_command curl curl || exit 1
ensure_command podman podman || exit 1
ensure_latest_kubectl || exit 1
ensure_latest_helm || exit 1

if [[ ! -f "$CONFIG_ENV" ]]; then
  err "設定ファイルが見つかりません: $CONFIG_ENV"
  exit 1
fi

# --- 1. config.env および versions.env の読み込み ---
log "設定ファイルを読み込み中..."
set -a
source "$CONFIG_ENV"

if [[ -f "$VERSIONS_ENV" ]]; then
  log "バージョン情報ファイル (versions.env) を読み込み、最新バージョンを適用中..."
  source "$VERSIONS_ENV"
fi
set +a

# --- 2. K3s 最新安定版の取得 (未指定時) ---
if [[ -z "${IMAGE:-}" ]]; then
  log "K3s の最新安定版を取得中 (Rancher 互換性チェック付き)..."
  RANCHER_KUBE_CONSTRAINT=$(helm show chart rancher-stable/rancher 2>/dev/null | grep -i '^kubeVersion:' | sed -E 's/.*<[[:space:]]*([0-9]+\.[0-9]+).*/\1/' || true)
  if [[ -n "$RANCHER_KUBE_CONSTRAINT" ]]; then
    MAX_MAJOR=$(echo "$RANCHER_KUBE_CONSTRAINT" | cut -d. -f1)
    MAX_MINOR=$(echo "$RANCHER_KUBE_CONSTRAINT" | cut -d. -f2)
    TARGET_MINOR=$((MAX_MINOR - 1))
    K3S_FILTER_REGEX="^v${MAX_MAJOR}\.${TARGET_MINOR}\.[0-9]+-k3s1$"
  else
    K3S_FILTER_REGEX="^v1\.36\.[0-9]+-k3s1$"
  fi

  LATEST_IMAGE=$(curl -s --connect-timeout "${CURL_CONNECT_TIMEOUT:-5}" --max-time "${CURL_MAX_TIME:-10}" "${DOCKER_HUB_API_URL:-https://hub.docker.com/v2}/repositories/rancher/k3s/tags/?page_size=100&ordering=last_updated" 2>/dev/null \
    | jq -r '.results[].name // empty' 2>/dev/null \
    | grep -E "$K3S_FILTER_REGEX" \
    | sort -V \
    | tail -1 || true)

  if [[ -n "$LATEST_IMAGE" ]]; then
    IMAGE="rancher/k3s:${LATEST_IMAGE}"
    log "最新安定版を取得しました: $IMAGE"
    if [[ -f "$VERSIONS_ENV" ]]; then
      sed -i "s|^IMAGE=.*|IMAGE=\"${IMAGE}\"|" "$VERSIONS_ENV" 2>/dev/null || true
    fi
  else
    warn "最新版の取得に失敗しました。デフォルトを使用します"
    IMAGE="rancher/k3s:v1.36.4-k3s1"
  fi
fi

# --- 3. Ansible 向け extra-vars (JSON) 生成 ---
log "config.env から Ansible 変数を構築中..."

EXTRA_VARS=$(jq -n \
  --arg cluster_name "${CLUSTER_NAME:-ollama-cluster}" \
  --argjson servers "${SERVERS:-1}" \
  --argjson agents "${AGENTS:-1}" \
  --argjson server_cpus "${SERVER_CPUS:-8}" \
  --argjson agent_cpus "${AGENT_CPUS:-24}" \
  --arg server_cpuset "${SERVER_CPUSET:-0-7}" \
  --arg agent_cpuset "${AGENT_CPUSET:-8-31}" \
  --arg default_rollout_timeout "${DEFAULT_ROLLOUT_TIMEOUT:-300s}" \
  --arg extended_rollout_timeout "${EXTENDED_ROLLOUT_TIMEOUT:-600s}" \
  --arg long_rollout_timeout "${LONG_ROLLOUT_TIMEOUT:-1200s}" \
  --arg helm_timeout "${HELM_TIMEOUT:-15m}" \
  --arg node_ready_timeout "${NODE_READY_TIMEOUT:-300s}" \
  --arg k3d_create_timeout "${K3D_CREATE_TIMEOUT:-300s}" \
  --arg k3d_gpus "${K3D_GPUS:-all}" \
  --arg pod_delete_timeout "${POD_DELETE_TIMEOUT:-30s}" \
  --argjson default_retry_count "${DEFAULT_RETRY_COUNT:-60}" \
  --argjson default_retry_delay "${DEFAULT_RETRY_DELAY:-5}" \
  --argjson quick_retry_count "${QUICK_RETRY_COUNT:-3}" \
  --argjson quick_retry_delay "${QUICK_RETRY_DELAY:-10}" \
  --argjson steady_retry_count "${STEADY_RETRY_COUNT:-5}" \
  --argjson steady_retry_delay "${STEADY_RETRY_DELAY:-15}" \
  --argjson standard_retry_count "${STANDARD_RETRY_COUNT:-20}" \
  --argjson standard_retry_delay "${STANDARD_RETRY_DELAY:-5}" \
  --argjson once_retry_count "${ONCE_RETRY_COUNT:-1}" \
  --argjson curl_connect_timeout "${CURL_CONNECT_TIMEOUT:-5}" \
  --argjson curl_max_time "${CURL_MAX_TIME:-10}" \
  --argjson curl_retry_count "${CURL_RETRY_COUNT:-3}" \
  --argjson curl_retry_delay "${CURL_RETRY_DELAY:-2}" \
  --argjson curl_download_max_time "${CURL_DOWNLOAD_MAX_TIME:-60}" \
  --arg k3s_image "${IMAGE}" \
  --arg podman_network "${NETWORK:-k3d}" \
  --argjson enable_network_policy "${ENABLE_NETWORK_POLICY:-true}" \
  --argjson disable_traefik "${DISABLE_TRAEFIK:-false}" \
  --argjson kubelet_user_namespace "${KUBELET_USER_NAMESPACE:-true}" \
  --argjson pre_import_images "${PRE_IMPORT_IMAGES:-true}" \
  --arg image_archive_dir "${IMAGE_ARCHIVE_DIR:-/var/tmp/k3d-image-import}" \
  --argjson traefik_replicas "${TRAEFIK_REPLICAS:-1}" \
  --argjson cert_manager_replicas "${CERT_MANAGER_REPLICAS:-1}" \
  --argjson webhook_replicas "${WEBHOOK_REPLICAS:-1}" \
  --argjson fleet_replicas "${FLEET_REPLICAS:-1}" \
  --argjson capi_replicas "${CAPI_REPLICAS:-1}" \
  --argjson turtles_replicas "${TURTLES_REPLICAS:-1}" \
  --arg traefik_hostname "${TRAEFIK_HOSTNAME:-traefik.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --arg traefik_admin_user "${TRAEFIK_ADMIN_USER:-admin}" \
  --arg traefik_admin_password "${TRAEFIK_ADMIN_PASSWORD:-admin}" \
  --arg traefik_client_secret "${TRAEFIK_CLIENT_SECRET:-traefik-secret}" \
  --arg oauth2_proxy_image "${OAUTH2_PROXY_IMAGE:-quay.io/oauth2-proxy/oauth2-proxy:v7.8.1}" \
  --arg oauth2_proxy_cookie_secret "${OAUTH2_PROXY_COOKIE_SECRET:-k3d-traefik-sso-cookie-secret-32}" \
  --arg email_domain "${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}" \
  --arg admin_group_name "${ADMIN_GROUP_NAME:-rancher-admins}" \
  --arg rancher_hostname "${RANCHER_HOSTNAME:-rancher.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --argjson rancher_replicas "${RANCHER_REPLICAS:-1}" \
  --arg rancher_admin_password "${RANCHER_ADMIN_PASSWORD:-admin12345}" \
  --arg rancher_client_secret "${RANCHER_CLIENT_SECRET:-rancher-secret}" \
  --arg keycloak_hostname "${KEYCLOAK_HOSTNAME:-keycloak.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --arg keycloak_admin_user "${KEYCLOAK_ADMIN_USER:-admin}" \
  --arg keycloak_admin_password "${KEYCLOAK_ADMIN_PASSWORD:-admin}" \
  --argjson keycloak_replicas "${KEYCLOAK_REPLICAS:-1}" \
  --arg keycloak_pg_password "${KEYCLOAK_PG_PASSWORD:-keycloak-pg-2026}" \
  --arg keycloak_db_password "${KEYCLOAK_DB_PASSWORD:-keycloak-db-2026}" \
  --arg keycloak_pg_shared_buffers "${KEYCLOAK_PG_SHARED_BUFFERS:-512MB}" \
  --argjson keycloak_pg_metrics_enabled "${KEYCLOAK_PG_METRICS_ENABLED:-true}" \
  --arg keycloak_pg_memory_limit "${KEYCLOAK_PG_MEMORY_LIMIT:-1536Mi}" \
  --arg keycloak_pg_memory_request "${KEYCLOAK_PG_MEMORY_REQUEST:-768Mi}" \
  --arg keycloak_pg_cpu_limit "${KEYCLOAK_PG_CPU_LIMIT:-1000m}" \
  --arg keycloak_pg_cpu_request "${KEYCLOAK_PG_CPU_REQUEST:-250m}" \
  --argjson keycloak_pg_replica_count "${KEYCLOAK_PG_REPLICA_COUNT:-1}" \
  --argjson keycloak_pg_max_connections "${KEYCLOAK_PG_MAX_CONNECTIONS:-200}" \
  --arg keycloak_pg_primary_pod "${KEYCLOAK_PG_PRIMARY_POD:-keycloak-pg-postgresql-0}" \
  --argjson keycloak_events_enabled "${KEYCLOAK_EVENTS_ENABLED:-true}" \
  --argjson keycloak_events_expiration "${KEYCLOAK_EVENTS_EXPIRATION:-2592000}" \
  --argjson keycloak_admin_events_enabled "${KEYCLOAK_ADMIN_EVENTS_ENABLED:-true}" \
  --argjson keycloak_admin_events_details_enabled "${KEYCLOAK_ADMIN_EVENTS_DETAILS:-true}" \
  --arg grafana_hostname "${GRAFANA_HOSTNAME:-grafana.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --arg grafana_admin_password "${GRAFANA_ADMIN_PASSWORD:-admin}" \
  --arg grafana_client_secret "${GRAFANA_CLIENT_SECRET:-grafana-secret}" \
  --argjson grafana_replicas "${GRAFANA_REPLICAS:-1}" \
  --argjson prometheus_replicas "${PROMETHEUS_REPLICAS:-1}" \
  --argjson alertmanager_replicas "${ALERTMANAGER_REPLICAS:-1}" \
  --argjson monitoring_proxy_replicas "${MONITORING_PROXY_REPLICAS:-1}" \
  --arg grafana_db_password "${GRAFANA_DB_PASSWORD:-grafana-db-2026}" \
  --arg pgadmin_hostname "${PGADMIN_HOSTNAME:-pgadmin.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --arg pgadmin_admin_email "${PGADMIN_ADMIN_EMAIL:-admin@${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}" \
  --arg pgadmin_admin_password "${PGADMIN_ADMIN_PASSWORD:-admin}" \
  --argjson pgadmin_replicas "${PGADMIN_REPLICAS:-1}" \
  --arg pgadmin_client_secret "${PGADMIN_CLIENT_SECRET:-pgadmin-secret}" \
  --arg pgadmin_log_level "${PGADMIN_LOG_LEVEL:-DEBUG}" \
  --arg cert_manager_chart_version "${CERT_MANAGER_CHART_VERSION:-v1.21.2}" \
  --arg keycloak_pg_chart_version "${KEYCLOAK_PG_CHART_VERSION:-16.7.27}" \
  --arg keycloak_chart_version "${KEYCLOAK_CHART_VERSION:-3.0.12}" \
  --arg rancher_chart_version "${RANCHER_CHART_VERSION:-2.15.2}" \
  --arg kube_prometheus_stack_chart_version "${KUBE_PROMETHEUS_STACK_CHART_VERSION:-91.9.0}" \
  --arg rancher_monitoring_dashboards_chart_version "${RANCHER_MONITORING_DASHBOARDS_CHART_VERSION:-110.0.1+up0.1.4}" \
  --arg pgadmin_image "${PGADMIN_IMAGE:-docker.io/dpage/pgadmin4:latest}" \
  --argjson amd_gpu_plugin_enabled "${AMD_GPU_PLUGIN_ENABLED:-true}" \
  --arg amd_gpu_chart_version "${AMD_GPU_CHART_VERSION:-0.22.0}" \
  --arg amd_gpu_device_plugin_tag "${AMD_GPU_DEVICE_PLUGIN_TAG:-1.31.0.9}" \
  --arg kfd_device_path "${KFD_DEVICE_PATH:-/dev/kfd}" \
  --arg dri_device_path "${DRI_DEVICE_PATH:-/dev/dri}" \
  --argjson amd_npu_plugin_enabled "${AMD_NPU_PLUGIN_ENABLED:-true}" \
  --arg accel_device_path "${ACCEL_DEVICE_PATH:-/dev/accel}" \
  --arg amd_npu_device_plugin_image "${AMD_NPU_DEVICE_PLUGIN_IMAGE:-docker.io/squat/generic-device-plugin:latest}" \
  --arg amd_npu_resource_domain "${AMD_NPU_RESOURCE_DOMAIN:-amd.com}" \
  --arg amd_npu_device_name "${AMD_NPU_DEVICE_NAME:-npu}" \
  --argjson amd_npu_device_count "${AMD_NPU_DEVICE_COUNT:-1}" \
  --argjson ollama_enabled "${OLLAMA_ENABLED:-true}" \
  --arg ollama_chart_version "${OLLAMA_CHART_VERSION:-1.84.0}" \
  --arg ollama_hostname "${OLLAMA_HOSTNAME:-ollama.${EMAIL_DOMAIN}}" \
  --argjson ollama_port "${OLLAMA_PORT:-11434}" \
  --argjson ollama_replicas "${OLLAMA_REPLICAS:-1}" \
  --argjson ollama_gpu_enabled "${OLLAMA_GPU_ENABLED:-true}" \
  --arg ollama_gpu_type "${OLLAMA_GPU_TYPE:-amd}" \
  --argjson ollama_gpu_number "${OLLAMA_GPU_NUMBER:-1}" \
  --arg ollama_storage_size "${OLLAMA_STORAGE_SIZE:-30Gi}" \
  --argjson ollama_exporter_port "${OLLAMA_EXPORTER_PORT:-9115}" \
  --arg ollama_probe_path "${OLLAMA_PROBE_PATH:-/api/tags}" \
  --argjson ollama_liveness_delay_seconds "${OLLAMA_LIVENESS_DELAY_SECONDS:-60}" \
  --argjson ollama_liveness_timeout_seconds "${OLLAMA_LIVENESS_TIMEOUT_SECONDS:-5}" \
  --argjson ollama_liveness_failure_threshold "${OLLAMA_LIVENESS_FAILURE_THRESHOLD:-6}" \
  --argjson ollama_liveness_period_seconds "${OLLAMA_LIVENESS_PERIOD_SECONDS:-15}" \
  --argjson ollama_readiness_delay_seconds "${OLLAMA_READINESS_DELAY_SECONDS:-30}" \
  --argjson ollama_readiness_timeout_seconds "${OLLAMA_READINESS_TIMEOUT_SECONDS:-5}" \
  --argjson ollama_readiness_failure_threshold "${OLLAMA_READINESS_FAILURE_THRESHOLD:-3}" \
  --argjson ollama_readiness_period_seconds "${OLLAMA_READINESS_PERIOD_SECONDS:-10}" \
  --argjson oga_enabled "${OGA_ENABLED:-true}" \
  --arg oga_version "${OGA_VERSION:-0.17.1}" \
  --arg oga_image "${OGA_IMAGE:-docker.io/library/python:3.12-slim}" \
  --arg oga_hostname "${OGA_HOSTNAME:-oga.${EMAIL_DOMAIN}}" \
  --argjson oga_port "${OGA_PORT:-8000}" \
  --argjson oga_replicas "${OGA_REPLICAS:-1}" \
  --argjson oga_gpu_enabled "${OGA_GPU_ENABLED:-true}" \
  --arg oga_gpu_type "${OGA_GPU_TYPE:-amd}" \
  --argjson oga_gpu_number "${OGA_GPU_NUMBER:-1}" \
  --arg oga_storage_size "${OGA_STORAGE_SIZE:-30Gi}" \
  --argjson oga_startup_delay_seconds "${OGA_STARTUP_DELAY_SECONDS:-10}" \
  --argjson oga_startup_timeout_seconds "${OGA_STARTUP_TIMEOUT_SECONDS:-5}" \
  --argjson oga_startup_failure_threshold "${OGA_STARTUP_FAILURE_THRESHOLD:-30}" \
  --argjson oga_startup_period_seconds "${OGA_STARTUP_PERIOD_SECONDS:-10}" \
  --argjson npu_flm_enabled "${NPU_FLM_ENABLED:-true}" \
  --argjson npu_flm_port "${NPU_FLM_PORT:-52625}" \
  --arg npu_flm_default_model "${NPU_FLM_DEFAULT_MODEL:-qwen3:0.6b}" \
  --arg npu_flm_host_ip "${NPU_FLM_HOST_IP:-10.89.0.1}" \
  --arg npu_flm_bind_host "${NPU_FLM_BIND_HOST:-0.0.0.0}" \
  --arg npu_flm_probe_host "${NPU_FLM_PROBE_HOST:-127.0.0.1}" \
  --arg npu_flm_probe_path "${NPU_FLM_PROBE_PATH:-/v1/models}" \
  --argjson npu_flm_startup_retries "${NPU_FLM_STARTUP_RETRIES:-15}" \
  --argjson npu_flm_startup_retry_interval "${NPU_FLM_STARTUP_RETRY_INTERVAL:-1}" \
  --arg npu_flm_kernel_dir "${NPU_FLM_KERNEL_DIR:-/opt/fastflowlm/lib}" \
  --argjson npu_flm_client_timeout "${NPU_FLM_CLIENT_TIMEOUT:-120.0}" \
  --argjson npu_flm_health_timeout "${NPU_FLM_HEALTH_TIMEOUT:-3.0}" \
  --argjson open_webui_enabled "${OPEN_WEBUI_ENABLED:-true}" \
  --arg open_webui_chart_version "${OPEN_WEBUI_CHART_VERSION:-16.6.0}" \
  --arg open_webui_image_tag "${OPEN_WEBUI_IMAGE_TAG:-v0.11.4}" \
  --arg open_webui_hostname "${OPEN_WEBUI_HOSTNAME:-chat.${EMAIL_DOMAIN}}" \
  --argjson open_webui_port "${OPEN_WEBUI_PORT:-8080}" \
  --argjson open_webui_replicas "${OPEN_WEBUI_REPLICAS:-1}" \
  --arg open_webui_client_id "${OPEN_WEBUI_CLIENT_ID:-open-webui}" \
  --arg open_webui_client_secret "${OPEN_WEBUI_CLIENT_SECRET:-open-webui-secret}" \
  --arg open_webui_default_locale "${OPEN_WEBUI_DEFAULT_LOCALE:-ja-JP}" \
  --arg open_webui_storage_size "${OPEN_WEBUI_STORAGE_SIZE:-30Gi}" \
  --arg open_webui_storage_class "${OPEN_WEBUI_STORAGE_CLASS:-local-path}" \
  --arg open_webui_cpu_request "${OPEN_WEBUI_CPU_REQUEST:-250m}" \
  --arg open_webui_memory_request "${OPEN_WEBUI_MEMORY_REQUEST:-512Mi}" \
  --arg open_webui_memory_limit "${OPEN_WEBUI_MEMORY_LIMIT:-4Gi}" \
  --arg open_webui_rollout_timeout "${OPEN_WEBUI_ROLLOUT_TIMEOUT:-300s}" \
  --argjson open_webui_web_search_enabled "${OPEN_WEBUI_WEB_SEARCH_ENABLED:-true}" \
  --arg open_webui_web_search_engine "${OPEN_WEBUI_WEB_SEARCH_ENGINE:-duckduckgo}" \
  --argjson open_webui_web_search_result_count "${OPEN_WEBUI_WEB_SEARCH_RESULT_COUNT:-3}" \
  --argjson open_webui_web_search_concurrent_requests "${OPEN_WEBUI_WEB_SEARCH_CONCURRENT_REQUESTS:-10}" \
  --argjson sysctl_somaxconn "${SYSCTL_SOMAXCONN:-65535}" \
  --argjson sysctl_tcp_max_syn_backlog "${SYSCTL_TCP_MAX_SYN_BACKLOG:-65535}" \
  --argjson sysctl_netdev_max_backlog "${SYSCTL_NETDEV_MAX_BACKLOG:-65535}" \
  --argjson sysctl_tcp_tw_reuse "${SYSCTL_TCP_TW_REUSE:-1}" \
  --argjson sysctl_tcp_fin_timeout "${SYSCTL_TCP_FIN_TIMEOUT:-15}" \
  --argjson sysctl_rmem_max "${SYSCTL_RMEM_MAX:-16777216}" \
  --argjson sysctl_wmem_max "${SYSCTL_WMEM_MAX:-16777216}" \
  --arg sysctl_tcp_rmem "${SYSCTL_TCP_RMEM:-4096 87380 16777216}" \
  --arg sysctl_tcp_wmem "${SYSCTL_TCP_WMEM:-4096 87380 16777216}" \
  --argjson sysctl_tcp_syncookies "${SYSCTL_TCP_SYNCOOKIES:-1}" \
  --argjson sysctl_gc_thresh1 "${SYSCTL_GC_THRESH1:-4096}" \
  --argjson sysctl_gc_thresh2 "${SYSCTL_GC_THRESH2:-8192}" \
  --argjson sysctl_gc_thresh3 "${SYSCTL_GC_THRESH3:-16384}" \
  --argjson sysctl_nf_conntrack_max "${SYSCTL_NF_CONNTRACK_MAX:-1048576}" \
  --argjson sysctl_nf_conntrack_tcp_timeout_established "${SYSCTL_NF_CONNTRACK_TCP_TIMEOUT_ESTABLISHED:-86400}" \
  --argjson sysctl_dirty_background_ratio "${SYSCTL_DIRTY_BACKGROUND_RATIO:-5}" \
  --argjson sysctl_dirty_ratio "${SYSCTL_DIRTY_RATIO:-10}" \
  --argjson sysctl_inotify_max_user_watches "${SYSCTL_INOTIFY_MAX_USER_WATCHES:-1048576}" \
  --argjson sysctl_inotify_max_user_instances "${SYSCTL_INOTIFY_MAX_USER_INSTANCES:-16384}" \
  --argjson sysctl_vm_max_map_count "${SYSCTL_VM_MAX_MAP_COUNT:-1048576}" \
  --argjson sysctl_swappiness "${SYSCTL_SWAPPINESS:-1}" \
  --argjson sysctl_vfs_cache_pressure "${SYSCTL_VFS_CACHE_PRESSURE:-50}" \
  --argjson sysctl_overcommit_memory "${SYSCTL_OVERCOMMIT_MEMORY:-1}" \
  --arg sysctl_ip_local_port_range "${SYSCTL_IP_LOCAL_PORT_RANGE:-10240 65535}" \
  --argjson sysctl_tcp_keepalive_time "${SYSCTL_TCP_KEEPALIVE_TIME:-600}" \
  --argjson sysctl_tcp_keepalive_intvl "${SYSCTL_TCP_KEEPALIVE_INTVL:-30}" \
  --argjson sysctl_tcp_keepalive_probes "${SYSCTL_TCP_KEEPALIVE_PROBES:-5}" \
  --argjson sysctl_netdev_budget "${SYSCTL_NETDEV_BUDGET:-600}" \
  --argjson sysctl_rp_filter "${SYSCTL_RP_FILTER:-2}" \
  --argjson sysctl_aio_max_nr "${SYSCTL_AIO_MAX_NR:-1048576}" \
  --argjson sysctl_pid_max "${SYSCTL_PID_MAX:-4194304}" \
  --arg podman_events_logger "${PODMAN_EVENTS_LOGGER:-file}" \
  --arg podman_log_driver "${PODMAN_LOG_DRIVER:-k8s-file}" \
  --argjson podman_log_size_max "${PODMAN_LOG_SIZE_MAX:-52428800}" \
  --argjson kubelet_max_pods "${KUBELET_MAX_PODS:-250}" \
  --argjson containerd_max_concurrent_downloads "${CONTAINERD_MAX_CONCURRENT_DOWNLOADS:-10}" \
  --arg sysctl_tcp_congestion_control "${SYSCTL_TCP_CONGESTION_CONTROL:-bbr}" \
  --arg sysctl_default_qdisc "${SYSCTL_DEFAULT_QDISC:-fq}" \
  --argjson sysctl_tcp_fastopen "${SYSCTL_TCP_FASTOPEN:-3}" \
  --arg dynamic_swappiness_enabled "${DYNAMIC_SWAPPINESS_ENABLED:-true}" \
  --argjson dynamic_swappiness_interval "${DYNAMIC_SWAPPINESS_INTERVAL:-60}" \
  --argjson dynamic_swappiness_low_load "${DYNAMIC_SWAPPINESS_LOW_LOAD:-30}" \
  --argjson dynamic_swappiness_high_load "${DYNAMIC_SWAPPINESS_HIGH_LOAD:-80}" \
  --argjson dynamic_swappiness_min "${DYNAMIC_SWAPPINESS_MIN:-80}" \
  --argjson dynamic_swappiness_max "${DYNAMIC_SWAPPINESS_MAX:-95}" \
  --arg flannel_backend "${FLANNEL_BACKEND:-host-gw}" \
  --arg kube_proxy_mode "${KUBE_PROXY_MODE:-iptables}" \
  --arg podman_network_cidr "${PODMAN_NETWORK_CIDR:-10.89.0.0/24}" \
  --arg podman_network_gateway "${PODMAN_NETWORK_GATEWAY:-10.89.0.1}" \
  --arg cluster_dns_ip "${CLUSTER_DNS_IP:-127.0.0.1}" \
  --arg k8s_service_cidr "${K8S_SERVICE_CIDR:-10.43.0.0/16}" \
  --arg k8s_cluster_cidr "${K8S_CLUSTER_CIDR:-10.42.0.0/16}" \
  --argjson k8s_node_cidr_mask_size "${K8S_NODE_CIDR_MASK_SIZE:-24}" \
  --argjson k8s_api_port "${K8S_API_PORT:-6443}" \
  --argjson http_port "${HTTP_PORT:-80}" \
  --argjson https_port "${HTTPS_PORT:-443}" \
  --argjson postgres_port "${POSTGRES_PORT:-5432}" \
  --argjson grafana_port "${GRAFANA_PORT:-3000}" \
  --argjson oauth2_proxy_port "${OAUTH2_PROXY_PORT:-4180}" \
  '{
    cluster_name: $cluster_name,
    servers: $servers,
    agents: $agents,
    server_cpus: $server_cpus,
    agent_cpus: $agent_cpus,
    server_cpuset: $server_cpuset,
    agent_cpuset: $agent_cpuset,
    default_rollout_timeout: $default_rollout_timeout,
    extended_rollout_timeout: $extended_rollout_timeout,
    long_rollout_timeout: $long_rollout_timeout,
    helm_timeout: $helm_timeout,
    node_ready_timeout: $node_ready_timeout,
    k3d_create_timeout: $k3d_create_timeout,
    k3d_gpus: $k3d_gpus,
    pod_delete_timeout: $pod_delete_timeout,
    default_retry_count: $default_retry_count,
    default_retry_delay: $default_retry_delay,
    quick_retry_count: $quick_retry_count,
    quick_retry_delay: $quick_retry_delay,
    steady_retry_count: $steady_retry_count,
    steady_retry_delay: $steady_retry_delay,
    standard_retry_count: $standard_retry_count,
    standard_retry_delay: $standard_retry_delay,
    once_retry_count: $once_retry_count,
    curl_connect_timeout: $curl_connect_timeout,
    curl_max_time: $curl_max_time,
    curl_retry_count: $curl_retry_count,
    curl_retry_delay: $curl_retry_delay,
    k3s_image: $k3s_image,
    podman_network: $podman_network,
    enable_network_policy: $enable_network_policy,
    disable_traefik: $disable_traefik,
    kubelet_user_namespace: $kubelet_user_namespace,
    pre_import_images: $pre_import_images,
    traefik_replicas: $traefik_replicas,
    webhook_replicas: $webhook_replicas,
    fleet_replicas: $fleet_replicas,
    capi_replicas: $capi_replicas,
    turtles_replicas: $turtles_replicas,
    traefik_hostname: $traefik_hostname,
    traefik_admin_user: $traefik_admin_user,
    traefik_admin_password: $traefik_admin_password,
    traefik_client_secret: $traefik_client_secret,
    oauth2_proxy_image: $oauth2_proxy_image,
    oauth2_proxy_cookie_secret: $oauth2_proxy_cookie_secret,
    email_domain: $email_domain,
    admin_group_name: $admin_group_name,
    rancher_hostname: $rancher_hostname,
    rancher_replicas: $rancher_replicas,
    rancher_admin_password: $rancher_admin_password,
    rancher_client_secret: $rancher_client_secret,
    keycloak_hostname: $keycloak_hostname,
    keycloak_admin_user: $keycloak_admin_user,
    keycloak_admin_password: $keycloak_admin_password,
    keycloak_replicas: $keycloak_replicas,
    keycloak_pg_password: $keycloak_pg_password,
    keycloak_db_password: $keycloak_db_password,
    keycloak_pg_shared_buffers: $keycloak_pg_shared_buffers,
    keycloak_pg_metrics_enabled: $keycloak_pg_metrics_enabled,
    keycloak_pg_memory_limit: $keycloak_pg_memory_limit,
    keycloak_pg_memory_request: $keycloak_pg_memory_request,
    keycloak_pg_cpu_limit: $keycloak_pg_cpu_limit,
    keycloak_pg_cpu_request: $keycloak_pg_cpu_request,
    keycloak_pg_replica_count: $keycloak_pg_replica_count,
    keycloak_pg_max_connections: $keycloak_pg_max_connections,
    keycloak_pg_primary_pod: $keycloak_pg_primary_pod,
    keycloak_events_enabled: $keycloak_events_enabled,
    keycloak_events_expiration: $keycloak_events_expiration,
    keycloak_admin_events_enabled: $keycloak_admin_events_enabled,
    keycloak_admin_events_details_enabled: $keycloak_admin_events_details_enabled,
    grafana_hostname: $grafana_hostname,
    grafana_admin_password: $grafana_admin_password,
    grafana_client_secret: $grafana_client_secret,
    grafana_replicas: $grafana_replicas,
    prometheus_replicas: $prometheus_replicas,
    grafana_db_password: $grafana_db_password,
    pgadmin_hostname: $pgadmin_hostname,
    pgadmin_admin_email: $pgadmin_admin_email,
    pgadmin_admin_password: $pgadmin_admin_password,
    pgadmin_replicas: $pgadmin_replicas,
    pgadmin_client_secret: $pgadmin_client_secret,
    pgadmin_log_level: $pgadmin_log_level,
    cert_manager_chart_version: $cert_manager_chart_version,
    keycloak_pg_chart_version: $keycloak_pg_chart_version,
    keycloak_chart_version: $keycloak_chart_version,
    rancher_chart_version: $rancher_chart_version,
    kube_prometheus_stack_chart_version: $kube_prometheus_stack_chart_version,
    rancher_monitoring_dashboards_chart_version: $rancher_monitoring_dashboards_chart_version,
    pgadmin_image: $pgadmin_image,
    amd_gpu_plugin_enabled: $amd_gpu_plugin_enabled,
    amd_gpu_chart_version: $amd_gpu_chart_version,
    amd_gpu_device_plugin_tag: $amd_gpu_device_plugin_tag,
    kfd_device_path: $kfd_device_path,
    dri_device_path: $dri_device_path,
    amd_npu_plugin_enabled: $amd_npu_plugin_enabled,
    accel_device_path: $accel_device_path,
    amd_npu_device_plugin_image: $amd_npu_device_plugin_image,
    amd_npu_resource_domain: $amd_npu_resource_domain,
    amd_npu_device_name: $amd_npu_device_name,
    amd_npu_device_count: $amd_npu_device_count,
    ollama_enabled: $ollama_enabled,
    ollama_chart_version: $ollama_chart_version,
    ollama_hostname: $ollama_hostname,
    ollama_port: $ollama_port,
    ollama_replicas: $ollama_replicas,
    ollama_gpu_enabled: $ollama_gpu_enabled,
    ollama_gpu_type: $ollama_gpu_type,
    ollama_gpu_number: $ollama_gpu_number,
    ollama_storage_size: $ollama_storage_size,
    ollama_exporter_port: $ollama_exporter_port,
    ollama_probe_path: $ollama_probe_path,
    ollama_liveness_delay_seconds: $ollama_liveness_delay_seconds,
    ollama_liveness_timeout_seconds: $ollama_liveness_timeout_seconds,
    ollama_liveness_failure_threshold: $ollama_liveness_failure_threshold,
    ollama_liveness_period_seconds: $ollama_liveness_period_seconds,
    ollama_readiness_delay_seconds: $ollama_readiness_delay_seconds,
    ollama_readiness_timeout_seconds: $ollama_readiness_timeout_seconds,
    ollama_readiness_failure_threshold: $ollama_readiness_failure_threshold,
    ollama_readiness_period_seconds: $ollama_readiness_period_seconds,
    oga_enabled: $oga_enabled,
    oga_version: $oga_version,
    oga_image: $oga_image,
    oga_hostname: $oga_hostname,
    oga_port: $oga_port,
    oga_replicas: $oga_replicas,
    oga_gpu_enabled: $oga_gpu_enabled,
    oga_gpu_type: $oga_gpu_type,
    oga_gpu_number: $oga_gpu_number,
    oga_storage_size: $oga_storage_size,
    oga_startup_delay_seconds: $oga_startup_delay_seconds,
    oga_startup_timeout_seconds: $oga_startup_timeout_seconds,
    oga_startup_failure_threshold: $oga_startup_failure_threshold,
    oga_startup_period_seconds: $oga_startup_period_seconds,
    npu_flm_enabled: $npu_flm_enabled,
    npu_flm_port: $npu_flm_port,
    npu_flm_default_model: $npu_flm_default_model,
    npu_flm_host_ip: $npu_flm_host_ip,
    npu_flm_bind_host: $npu_flm_bind_host,
    npu_flm_probe_host: $npu_flm_probe_host,
    npu_flm_probe_path: $npu_flm_probe_path,
    npu_flm_startup_retries: $npu_flm_startup_retries,
    npu_flm_startup_retry_interval: $npu_flm_startup_retry_interval,
    npu_flm_kernel_dir: $npu_flm_kernel_dir,
    npu_flm_client_timeout: $npu_flm_client_timeout,
    npu_flm_health_timeout: $npu_flm_health_timeout,
    open_webui_enabled: $open_webui_enabled,
    open_webui_chart_version: $open_webui_chart_version,
    open_webui_image_tag: $open_webui_image_tag,
    open_webui_hostname: $open_webui_hostname,
    open_webui_port: $open_webui_port,
    open_webui_replicas: $open_webui_replicas,
    open_webui_client_secret: $open_webui_client_secret,
    open_webui_storage_size: $open_webui_storage_size,
    open_webui_storage_class: $open_webui_storage_class,
    open_webui_cpu_request: $open_webui_cpu_request,
    open_webui_memory_request: $open_webui_memory_request,
    open_webui_memory_limit: $open_webui_memory_limit,
    open_webui_rollout_timeout: $open_webui_rollout_timeout,
    open_webui_web_search_enabled: $open_webui_web_search_enabled,
    open_webui_web_search_engine: $open_webui_web_search_engine,
    open_webui_web_search_result_count: $open_webui_web_search_result_count,
    open_webui_web_search_concurrent_requests: $open_webui_web_search_concurrent_requests,
    sysctl_somaxconn: $sysctl_somaxconn,
    sysctl_tcp_max_syn_backlog: $sysctl_tcp_max_syn_backlog,
    sysctl_netdev_max_backlog: $sysctl_netdev_max_backlog,
    sysctl_tcp_tw_reuse: $sysctl_tcp_tw_reuse,
    sysctl_tcp_fin_timeout: $sysctl_tcp_fin_timeout,
    sysctl_rmem_max: $sysctl_rmem_max,
    sysctl_wmem_max: $sysctl_wmem_max,
    sysctl_tcp_rmem: $sysctl_tcp_rmem,
    sysctl_tcp_wmem: $sysctl_tcp_wmem,
    sysctl_tcp_syncookies: $sysctl_tcp_syncookies,
    sysctl_gc_thresh1: $sysctl_gc_thresh1,
    sysctl_gc_thresh2: $sysctl_gc_thresh2,
    sysctl_gc_thresh3: $sysctl_gc_thresh3,
    sysctl_nf_conntrack_max: $sysctl_nf_conntrack_max,
    sysctl_nf_conntrack_tcp_timeout_established: $sysctl_nf_conntrack_tcp_timeout_established,
    sysctl_dirty_background_ratio: $sysctl_dirty_background_ratio,
    sysctl_dirty_ratio: $sysctl_dirty_ratio,
    sysctl_inotify_max_user_watches: $sysctl_inotify_max_user_watches,
    sysctl_inotify_max_user_instances: $sysctl_inotify_max_user_instances,
    sysctl_vm_max_map_count: $sysctl_vm_max_map_count,
    sysctl_swappiness: $sysctl_swappiness,
    sysctl_vfs_cache_pressure: $sysctl_vfs_cache_pressure,
    sysctl_overcommit_memory: $sysctl_overcommit_memory,
    sysctl_ip_local_port_range: $sysctl_ip_local_port_range,
    sysctl_tcp_keepalive_time: $sysctl_tcp_keepalive_time,
    sysctl_tcp_keepalive_intvl: $sysctl_tcp_keepalive_intvl,
    sysctl_tcp_keepalive_probes: $sysctl_tcp_keepalive_probes,
    sysctl_netdev_budget: $sysctl_netdev_budget,
    sysctl_rp_filter: $sysctl_rp_filter,
    sysctl_aio_max_nr: $sysctl_aio_max_nr,
    sysctl_pid_max: $sysctl_pid_max,
    podman_events_logger: $podman_events_logger,
    podman_log_driver: $podman_log_driver,
    podman_log_size_max: $podman_log_size_max,
    kubelet_max_pods: $kubelet_max_pods,
    containerd_max_concurrent_downloads: $containerd_max_concurrent_downloads,
    sysctl_tcp_congestion_control: $sysctl_tcp_congestion_control,
    sysctl_default_qdisc: $sysctl_default_qdisc,
    sysctl_tcp_fastopen: $sysctl_tcp_fastopen,
    dynamic_swappiness_enabled: $dynamic_swappiness_enabled,
    dynamic_swappiness_interval: $dynamic_swappiness_interval,
    dynamic_swappiness_low_load: $dynamic_swappiness_low_load,
    dynamic_swappiness_high_load: $dynamic_swappiness_high_load,
    dynamic_swappiness_min: $dynamic_swappiness_min,
    dynamic_swappiness_max: $dynamic_swappiness_max,
    flannel_backend: $flannel_backend,
    kube_proxy_mode: $kube_proxy_mode,
    podman_network_cidr: $podman_network_cidr,
    podman_network_gateway: $podman_network_gateway,
    cluster_dns_ip: $cluster_dns_ip,
    k8s_service_cidr: $k8s_service_cidr,
    k8s_cluster_cidr: $k8s_cluster_cidr,
    k8s_node_cidr_mask_size: $k8s_node_cidr_mask_size,
    k8s_api_port: $k8s_api_port,
    http_port: $http_port,
    https_port: $https_port,
    postgres_port: $postgres_port,
    grafana_port: $grafana_port,
    oauth2_proxy_port: $oauth2_proxy_port
  }')

log "適用コンポーネントバージョン一覧:"
log "  - K3s イメージ:       ${IMAGE}"
log "  - cert-manager:       ${CERT_MANAGER_CHART_VERSION:-v1.21.2}"
log "  - keycloak-pg:        ${KEYCLOAK_PG_CHART_VERSION:-16.3.2}"
log "  - keycloak:           ${KEYCLOAK_CHART_VERSION:-3.0.12}"
log "  - rancher:            ${RANCHER_CHART_VERSION:-2.15.2}"
log "  - monitoring:         ${KUBE_PROMETHEUS_STACK_CHART_VERSION:-91.9.0}"
log "  - ollama:             ${OLLAMA_CHART_VERSION:-1.84.0}"
log "  - open-webui:         ${OPEN_WEBUI_CHART_VERSION:-16.6.0}"

# --- 4. 依存コレクションの確認 ---
if [[ -f "${ANSIBLE_DIR}/requirements.yml" ]]; then
  log "Ansible 依存コレクションを確認中..."
  ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yml" --quiet 2>/dev/null || true
fi

# 実ユーザーおよびホームディレクトリを特定 (sudo 実行時対応)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  ACTUAL_USER="${SUDO_USER}"
  ACTUAL_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "/home/${SUDO_USER}")
else
  ACTUAL_USER="$(whoami)"
  ACTUAL_USER_HOME="${HOME:-/home/$(whoami)}"
fi

# --- 4.5 AMD XDNA NPU (FastFlowLM) サービスの起動 (有効時) ---
if [[ "$CHECK_MODE" == false && "${NPU_FLM_ENABLED:-true}" == true ]]; then
  if command -v flm >/dev/null 2>&1; then
    log "AMD XDNA NPU (FastFlowLM) の状態を確認中..."
    FLM_KERNEL_DIR="${NPU_FLM_KERNEL_DIR:-/opt/fastflowlm/lib}"
    if [[ ! -d "${FLM_KERNEL_DIR}" ]]; then
      log "FastFlowLM NPU カーネルが見つからないため取得中 (sudo flm-fetch-kernels)..."
      sudo flm-fetch-kernels || warn "flm-fetch-kernels に失敗しました"
    fi
    FLM_MODEL="${NPU_FLM_DEFAULT_MODEL:-qwen3:0.6b}"
    FLM_CMD=(flm)
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      FLM_CMD=(sudo -u "${SUDO_USER}" HOME="${ACTUAL_USER_HOME}" flm)
    fi

    if ! "${FLM_CMD[@]}" list --filter installed 2>/dev/null | grep -q "${FLM_MODEL}"; then
      log "FastFlowLM モデル (${FLM_MODEL}) をダウンロード中..."
      "${FLM_CMD[@]}" pull "${FLM_MODEL}" || warn "FastFlowLM モデルの pull に失敗しました: ${FLM_MODEL}"
    fi

    FLM_PORT="${NPU_FLM_PORT:-52625}"
    FLM_BIND_HOST="${NPU_FLM_BIND_HOST:-0.0.0.0}"
    FLM_PROBE_HOST="${NPU_FLM_PROBE_HOST:-127.0.0.1}"
    FLM_PROBE_PATH="${NPU_FLM_PROBE_PATH:-/v1/models}"
    FLM_RETRIES="${NPU_FLM_STARTUP_RETRIES:-15}"
    FLM_INTERVAL="${NPU_FLM_STARTUP_RETRY_INTERVAL:-1}"

    if ! curl -s "http://${FLM_PROBE_HOST}:${FLM_PORT}${FLM_PROBE_PATH}" >/dev/null 2>&1; then
      log "FastFlowLM API サーバーをポート ${FLM_PORT} で起動中..."
      PID_FILE="/tmp/flm_serve_${ACTUAL_USER}.pid"
      LOG_FILE="/tmp/flm_serve_${ACTUAL_USER}.log"
      nohup "${FLM_CMD[@]}" serve "${FLM_MODEL}" --host "${FLM_BIND_HOST}" --port "${FLM_PORT}" > "${LOG_FILE}" 2>&1 &
      echo $! > "${PID_FILE}"

      FLM_STARTED=false
      for _i in $(seq 1 "${FLM_RETRIES}"); do
        if curl -s "http://${FLM_PROBE_HOST}:${FLM_PORT}${FLM_PROBE_PATH}" >/dev/null 2>&1; then
          FLM_STARTED=true
          succ "FastFlowLM API サーバーが正常に起動しました (ポート: ${FLM_PORT}, モデル: ${FLM_MODEL})"
          break
        fi
        sleep "${FLM_INTERVAL}"
      done
      if [[ "$FLM_STARTED" == false ]]; then
        warn "FastFlowLM API サーバーの起動確認がタイムアウトしました。ログを確認してください: ${LOG_FILE}"
      fi
    else
      log "FastFlowLM API サーバーは既に稼働中です (ポート: ${FLM_PORT})"
    fi
  else
    warn "flm コマンドが見つかりません。NPU 推論はスキップされます。"
  fi
fi

# --- 5. Ansible Playbook 実行 ---
log "Ansible Playbook を開始します: ${PLAYBOOK}"
(
  cd "${ANSIBLE_DIR}"
  ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" -e "${EXTRA_VARS}" "${ANSIBLE_ARGS[@]}"
)

# --- 6. クラスタ接続確認 & 残存 ReplicaSet クリーンアップ ---
if command -v kubectl &>/dev/null; then
  log "Kubernetes クラスタへの接続を確認中..."
  export KUBECONFIG="${HOME}/.kube/config"
  if kubectl cluster-info &>/dev/null; then
    log "Kubernetes クラスタは正常に稼働しています"
  fi
fi

# --- 7. Grafana の日本語化および Home Dashboard 設定 ---
GRAFANA_POD=$(kubectl -n cattle-monitoring-system get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$GRAFANA_POD" ]]; then
  log "Grafana 初期設定 (Home Dashboard, 日本語化) を適用中..."
  kubectl -n cattle-monitoring-system exec "$GRAFANA_POD" -c grafana -- \
    curl -s -X PUT http://admin:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3000/api/user/preferences \
    -H "Content-Type: application/json" \
    -d '{"homeDashboardUID":"rancher-home-1","timezone":"Asia/Tokyo","language":"ja-JP"}' >/dev/null 2>&1 || true

  kubectl -n cattle-monitoring-system exec "$GRAFANA_POD" -c grafana -- \
    curl -s -X PUT http://admin:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3000/api/org/preferences \
    -H "Content-Type: application/json" \
    -d '{"homeDashboardUID":"rancher-home-1","timezone":"Asia/Tokyo","language":"ja-JP"}' >/dev/null 2>&1 || true

  log "Grafana Preferences (Home Dashboard, Timezone, Language) を適用しました。"
fi

log "すべてのデプロイ処理が完了しました。"

# --- 8. ルート CA 証明書のホスト OS トラストストアへの自動登録 ---
TRUST_CA_SCRIPT="${SCRIPT_DIR}/trust-ca.sh"
if [[ "$CHECK_MODE" == false && -x "$TRUST_CA_SCRIPT" ]]; then
  log "クラスタのルート CA 証明書をホスト OS に自動登録中 (Chrome/ブラウザ SSL 警告回避)..."
  if ! "$TRUST_CA_SCRIPT" --insert; then
    warn "ルート CA 証明書の登録中に警告が発生しましたが、デプロイ処理を継続します"
  fi
fi

# --- 9. 各コンソール URL & 認証情報一覧表示 ---
SECRETS_FILE="${SCRIPT_DIR}/secrets.txt"
RANCHER_PASS="${RANCHER_ADMIN_PASSWORD:-admin12345}"
if [[ -f "$SECRETS_FILE" ]]; then
  FILE_PASS=$(grep -E "^Password=" "$SECRETS_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  [[ -n "$FILE_PASS" ]] && RANCHER_PASS="$FILE_PASS"
fi

echo ""
echo -e "\033[1;32m==============================================================================\033[0m"
echo -e "\033[1;32m                    各コンソール URL & 認証情報一覧                           \033[0m"
echo -e "\033[1;32m==============================================================================\033[0m"
cat << EOF

【Open WebUI (Local AI チャット)】(Worker ノード: 24コア)
  URL:            https://${OPEN_WEBUI_HOSTNAME:-chat.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  SSO Login:      Keycloak OIDC (ワンクリックログイン)
  Client ID:      open-webui
  Client Secret:  ${OPEN_WEBUI_CLIENT_SECRET:-open-webui-secret}
  Backend:        Ollama API (${OLLAMA_HOSTNAME:-ollama.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}})

【Ollama LLM サービス】(Worker ノード: 24コア)
  API URL:        https://${OLLAMA_HOSTNAME:-ollama.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  Internal URL:   http://ollama.ollama.svc.cluster.local:11434
  Storage:        PVC (${OLLAMA_STORAGE_SIZE:-30Gi}, local-path)
  Acceleration:   AMD GPU / ROCm パススルー (/dev/kfd, /dev/dri)

【OnnxRuntime GenAI (OGA)】(Worker ノード: 24コア)
  API URL:        https://${OGA_HOSTNAME:-oga.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  Acceleration:   AMD NPU (XDNA) パススルー (/dev/accel)

【Keycloak】(Server ノード: 8コア)
  URL:            https://${KEYCLOAK_HOSTNAME:-keycloak.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  Admin Console:  https://${KEYCLOAK_HOSTNAME:-keycloak.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}/admin
  User ID:        ${KEYCLOAK_ADMIN_USER:-admin}
  Password:       ${KEYCLOAK_ADMIN_PASSWORD:-admin}

【PostgreSQL】(Server ノード: 8コア)
  Primary:        ${KEYCLOAK_PG_HOST:-keycloak-pg-postgresql}.${KEYCLOAK_NAMESPACE:-keycloak}.svc.cluster.local:${POSTGRES_PORT:-5432}
  Admin User:     postgres
  Admin Password: ${KEYCLOAK_PG_PASSWORD:-keycloak-pg-2026}
  App User/DB:    keycloak / keycloak (${KEYCLOAK_DB_PASSWORD:-keycloak-db-2026})

【pgAdmin 4】(Server ノード: 8コア)
  URL:            https://${PGADMIN_HOSTNAME:-pgadmin.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  Login Email:    ${PGADMIN_ADMIN_EMAIL:-admin@${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  Password:       ${PGADMIN_ADMIN_PASSWORD:-admin}
  SSO Login:      Keycloak OIDC (ワンクリックログイン)

【Grafana】(Server ノード: 8コア)
  URL:            https://${GRAFANA_HOSTNAME:-grafana.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  User ID:        admin
  Password:       ${GRAFANA_ADMIN_PASSWORD:-admin}
  Home Dashboard: Dashboards Home (rancher-home-1)
  Timezone / Lang: Asia/Tokyo (JST) / 日本語 (ja-JP)

【Traefik Dashboard】(Server ノード: 8コア)
  URL:            https://${TRAEFIK_HOSTNAME:-traefik.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  Dashboard UI:   https://${TRAEFIK_HOSTNAME:-traefik.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}/dashboard/
  SSO Login:      Keycloak OIDC (oauth2-proxy forwardAuth)
  User ID:        ${TRAEFIK_ADMIN_USER:-admin}
  Password:       ${TRAEFIK_ADMIN_PASSWORD:-admin}

【Rancher】(Server ノード: 8コア)
  URL:            https://${RANCHER_HOSTNAME:-rancher.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}
  User ID:        admin
  Password:       ${RANCHER_PASS}
  SSO Login:      Keycloak OIDC (ワンクリックログイン)
  OIDC Callback:  https://${RANCHER_HOSTNAME:-rancher.${EMAIL_DOMAIN:-$DEFAULT_EMAIL_DOMAIN}}/verify-auth

EOF

echo -e "\033[1;32m==============================================================================\033[0m"
if [[ -f "$SECRETS_FILE" ]]; then
  log "認証情報はファイルにも保存されています: ${SECRETS_FILE}"
fi

# --- 10. アップグレード可否の自動判定 & 問い合わせ ---
if [[ "$CHECK_MODE" == false && "$SKIP_UPGRADE_CHECK" == false ]]; then
  echo ""
  log "クラスタコンポーネントの最新バージョン確認 (アップグレード判定) を実行中..."
  set +e
  "${SCRIPT_DIR}/upgrade.sh" --check
  UPGRADE_CHECK_RC=$?
  set -e

  if [[ $UPGRADE_CHECK_RC -eq 10 ]]; then
    if [[ "$AUTO_UPGRADE" == true ]]; then
      log "自動アップグレード (-y/--yes) が指定されているため、アップグレードを実行します..."
      "${SCRIPT_DIR}/upgrade.sh" -y
    elif [ -t 0 ] || [ -e /dev/tty ]; then
      echo ""
      read -r -p "アップグレード可能なコンポーネントが存在します。今すぐアップグレードを実行しますか？ [y/N]: " do_upgrade </dev/tty || do_upgrade="n"
      case "$do_upgrade" in
        [yY]|[yY][eE][sS])
          log "アップグレードを開始します..."
          "${SCRIPT_DIR}/upgrade.sh"
          ;;
        *)
          log "アップグレードをスキップしました。手動で実行する場合は './upgrade.sh' を実行してください。"
          ;;
      esac
    else
      log "非対話環境のため自動アップグレードの問い合わせをスキップしました。手動で実行する場合は './upgrade.sh' を実行してください。"
    fi
  elif [[ $UPGRADE_CHECK_RC -eq 0 ]]; then
    log "すべてのコンポーネントは最新です (アップグレード不要)。"
  else
    warn "アップグレード確認処理で異常が発生しました (終了コード: ${UPGRADE_CHECK_RC})"
  fi
fi

# --- 11. 標準 LLM モデルの自動登録 & Open WebUI 標準モデル設定 ---
if [[ "$CHECK_MODE" == false && "${OLLAMA_ENABLED:-true}" == true \
  && "${OLLAMA_DEFAULT_MODEL_AUTO_SETUP:-true}" == true && -n "${OLLAMA_DEFAULT_MODEL:-}" ]]; then
  echo ""
  log "標準 LLM モデル (${OLLAMA_DEFAULT_MODEL}) の登録状態を確認中..."

  OLLAMA_MODEL_LIST=""
  for _attempt in $(seq 1 "${OLLAMA_DEFAULT_MODEL_SETUP_RETRIES:-30}"); do
    if OLLAMA_MODEL_LIST="$("${SCRIPT_DIR}/ollama-pull.sh" --list 2>/dev/null)" && [[ -n "${OLLAMA_MODEL_LIST}" ]]; then
      break
    fi
    OLLAMA_MODEL_LIST=""
    sleep "${OLLAMA_DEFAULT_MODEL_SETUP_RETRY_INTERVAL:-2}"
  done

  if [[ -z "${OLLAMA_MODEL_LIST}" ]]; then
    warn "Ollama に接続できないため標準 LLM モデルの登録をスキップしました"
  else
    # 登録済みモデル名の検出 (Ollama はモデル名を小文字で保持するため大文字小文字を区別しない)
    REGISTERED_MODEL="$(printf '%s\n' "${OLLAMA_MODEL_LIST}" \
      | awk -v m="${OLLAMA_DEFAULT_MODEL}" 'tolower($1) == tolower(m) { print $1; exit }')"

    if [[ -z "${REGISTERED_MODEL}" ]]; then
      log "標準 LLM モデルが未登録のため pull を実行します (ダウンロードには時間がかかります)..."
      if "${SCRIPT_DIR}/ollama-pull.sh" "${OLLAMA_DEFAULT_MODEL}"; then
        OLLAMA_MODEL_LIST="$("${SCRIPT_DIR}/ollama-pull.sh" --list 2>/dev/null || true)"
        REGISTERED_MODEL="$(printf '%s\n' "${OLLAMA_MODEL_LIST}" \
          | awk -v m="${OLLAMA_DEFAULT_MODEL}" 'tolower($1) == tolower(m) { print $1; exit }')"
        REGISTERED_MODEL="${REGISTERED_MODEL:-${OLLAMA_DEFAULT_MODEL}}"
        succ "標準 LLM モデルを登録しました: ${REGISTERED_MODEL}"
      else
        REGISTERED_MODEL=""
        warn "標準 LLM モデルの pull に失敗しました。手動で登録してください: ./ollama-pull.sh ${OLLAMA_DEFAULT_MODEL}"
      fi
    else
      log "標準 LLM モデルは既に登録されています: ${REGISTERED_MODEL}"
      # 登録済みモデルでも tools サポートが無い場合は Modelfile を適用して自動再作成
      "${SCRIPT_DIR}/ollama-pull.sh" --enable-tools "${REGISTERED_MODEL}" || true
    fi

    if [[ "${OPEN_WEBUI_ENABLED:-true}" == true ]]; then
      # 管理者 API が利用できない (管理者ユーザー未作成) ため、アプリ内 DB を直接更新する
      OWUI_NAMESPACE="${OPEN_WEBUI_NAMESPACE:-open-webui}"
      OWUI_POD="$(kubectl -n "${OWUI_NAMESPACE}" get pod -l app.kubernetes.io/name=open-webui \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

      if [[ -n "${OWUI_POD}" ]]; then
        log "Open WebUI の標準設定 (モデル / ロケール / Web検索) を更新中 (pod: ${OWUI_POD}, model: ${REGISTERED_MODEL:-なし}, locale: ${OPEN_WEBUI_DEFAULT_LOCALE:-ja-JP}, search: ${OPEN_WEBUI_WEB_SEARCH_ENGINE:-duckduckgo})..."
        if kubectl -n "${OWUI_NAMESPACE}" exec -i "${OWUI_POD}" -- sh -c \
          'cd /app/backend && WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY:-open-webui-config-setup}" python3 - "$@"' \
          sh "${REGISTERED_MODEL}" "${OPEN_WEBUI_DEFAULT_LOCALE:-ja-JP}" "${OPEN_WEBUI_WEB_SEARCH_ENABLED:-true}" "${OPEN_WEBUI_WEB_SEARCH_ENGINE:-duckduckgo}" "${OPEN_WEBUI_WEB_SEARCH_RESULT_COUNT:-3}" "${OPEN_WEBUI_WEB_SEARCH_CONCURRENT_REQUESTS:-10}" <<'PYEOF'
import asyncio
import json
import sqlite3
import sys

from open_webui.models.config import Config

model_id = sys.argv[1] if len(sys.argv) > 1 else ""
locale = sys.argv[2] if len(sys.argv) > 2 else "ja-JP"
web_search_enabled = sys.argv[3] if len(sys.argv) > 3 else "true"
web_search_engine = sys.argv[4] if len(sys.argv) > 4 else "duckduckgo"
try:
    web_search_count = int(sys.argv[5]) if len(sys.argv) > 5 else 3
except Exception:
    web_search_count = 3
try:
    web_search_concurrent = int(sys.argv[6]) if len(sys.argv) > 6 else 10
except Exception:
    web_search_concurrent = 10

    updates = {
        "ui.default_locale": locale,
        "ui.default_interface_settings": {"locale": locale},
        "web.search.enable": (web_search_enabled.lower() == "true"),
        "web.search.engine": web_search_engine,
        "web.search.result_count": web_search_count,
        "web.search.concurrent_requests": web_search_concurrent,
        "web.search.bypass_web_loader": True,
        "web.search.bypass_embedding_and_retrieval": True,
        "web.search.ddgs_backend": "auto",
    }
    if model_id:
        updates["ui.default_models"] = model_id
        updates["ui.default_pinned_models"] = model_id

    asyncio.run(Config.upsert(updates))

if model_id:
    print("ui.default_models =", asyncio.run(Config.get("ui.default_models")))
    print("ui.default_pinned_models =", asyncio.run(Config.get("ui.default_pinned_models")))
print("ui.default_locale =", asyncio.run(Config.get("ui.default_locale")))
print("ui.default_interface_settings =", asyncio.run(Config.get("ui.default_interface_settings")))
print("web.search.enable =", asyncio.run(Config.get("web.search.enable")))
print("web.search.engine =", asyncio.run(Config.get("web.search.engine")))

try:
    conn = sqlite3.connect("/app/backend/data/webui.db")
    c = conn.cursor()
    users = c.execute("SELECT id, settings FROM user").fetchall()
    for uid, raw_settings in users:
        try:
            s = json.loads(raw_settings) if raw_settings else {}
        except Exception:
            s = {}
        if not isinstance(s, dict):
            s = {}
        ui = s.get("ui")
        if not isinstance(ui, dict):
            ui = {}
        ui["locale"] = locale
        s["ui"] = ui
        c.execute("UPDATE user SET settings = ? WHERE id = ?", (json.dumps(s), uid))
    conn.commit()
    conn.close()
except Exception as e:
    print(f"Warning: Failed to update existing user settings: {e}")

try:
    import os, re
    html_path = "/app/build/index.html"
    if os.path.exists(html_path):
        with open(html_path, "r", encoding="utf-8") as f:
            content = f.read()
        content = re.sub(r'<html lang="[^"]*"', f'<html lang="{locale}"', content)
        content = content.replace('src="/static/loader.js" defer', 'src="/static/loader.js"')
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(content)
        print("Patched index.html language attribute and synchronous loader script")
except Exception as e:
    print(f"Warning: Failed to patch index.html: {e}")

try:
    from open_webui.models.tools import Tools, ToolForm, ToolMeta
    from open_webui.models.users import Users
    from open_webui.utils.tools import load_tool_module_by_id, get_tool_specs

    TOOL_ID = "web_search"
    TOOL_NAME = "Web Search"
    TOOL_DESC = "DuckDuckGo を使用してインターネット上の最新ニュース、天気、情報を検索します。"
    TOOL_CONTENT = '''"""
title: Web Search
author: Open WebUI
version: 1.0.0
description: DuckDuckGo を使用してインターネット上の最新ニュース、天気、情報を検索します。
"""

from ddgs import DDGS

class Tools:
    def __init__(self):
        pass

    def search_web(self, query: str, count: int = 5) -> str:
        """
        インターネットを検索して最新の情報（ニュース、天気、事実など）を取得します。
        :param query: 検索キーワードや質問
        :param count: 取得する検索結果の件数 (デフォルト: 5)
        :return: 検索結果（タイトル、URL、要約スニペット）
        """
        try:
            with DDGS() as ddgs:
                results = list(ddgs.text(query, max_results=count))
                if not results:
                    return f"「{query}」に関する検索結果は見つかりませんでした。"
                
                output = []
                for i, r in enumerate(results, 1):
                    title = r.get("title", "")
                    url = r.get("href", "")
                    body = r.get("body", "")
                    output.append(f"[{i}] {title}\\nURL: {url}\\n要約: {body}\\n")
                return "\\n".join(output)
        except Exception as e:
            return f"検索エラー: {str(e)}"
'''
    async def register_tool():
        users_data = await Users.get_users()
        users_list = users_data.get("users", []) if isinstance(users_data, dict) else users_data
        admin_id = None
        for u in users_list:
            role = getattr(u, "role", "") or (u.get("role") if isinstance(u, dict) else "")
            if role == "admin":
                admin_id = getattr(u, "id", None) or (u.get("id") if isinstance(u, dict) else None)
                break
        if not admin_id and users_list:
            admin_id = getattr(users_list[0], "id", None) or (users_list[0].get("id") if isinstance(users_list[0], dict) else None)

        module, _ = await load_tool_module_by_id(TOOL_ID, content=TOOL_CONTENT)
        specs = get_tool_specs(module)

        existing = await Tools.get_tool_by_id(TOOL_ID)
        form = ToolForm(
            id=TOOL_ID,
            name=TOOL_NAME,
            content=TOOL_CONTENT,
            meta=ToolMeta(description=TOOL_DESC),
            access_grants=[]
        )
        if existing:
            update_dict = {
                "name": TOOL_NAME,
                "content": TOOL_CONTENT,
                "specs": specs,
                "meta": {"description": TOOL_DESC}
            }
            await Tools.update_tool_by_id(TOOL_ID, update_dict)
            print("Updated web_search tool successfully")
        elif admin_id:
            await Tools.insert_new_tool(admin_id, form, specs=specs)
            print("Created web_search tool successfully")

        # Configure default model with toolIds
        try:
            from open_webui.models.models import Models, ModelForm, ModelMeta, ModelParams
            default_model = await Config.get("ui.default_models")
            if default_model:
                for mid in default_model.split(","):
                    mid = mid.strip()
                    if mid:
                        mform = ModelForm(
                            id=mid,
                            base_model_id=None,
                            name=mid,
                            meta=ModelMeta(
                                description=f"{mid} with Web Search capabilities",
                                capabilities={"tools": True, "web_search": True},
                                toolIds=["web_search"]
                            ),
                            params=ModelParams(),
                            access_grants=[],
                            is_active=True
                        )
                        m_exist = await Models.get_model_by_id(mid)
                        if m_exist:
                            await Models.update_model_by_id(mid, mform)
                        elif admin_id:
                            await Models.insert_new_model(mform, admin_id)
                        print(f"Configured model {mid} with default toolIds: ['web_search']")
        except Exception as e:
            print(f"Warning: Failed to configure default model with toolIds: {e}")

    asyncio.run(register_tool())
except Exception as e:
    print(f"Warning: Failed to register web_search tool: {e}")

# Patch frontend to enable Web Search (globe icon) by default
try:
    import glob
    js_files = glob.glob("/app/build/_app/immutable/chunks/*.js")
    for js_path in js_files:
        with open(js_path, "r", encoding="utf-8") as f:
            content = f.read()
        if "webSearchEnabled" in content:
            new_content, count = re.subn(r'("webSearchEnabled",\s*\d+,\s*)!1', r'\g<1>!0', content)
            if count > 0:
                with open(js_path, "w", encoding="utf-8") as f:
                    f.write(new_content)
                print(f"Patched {count} webSearchEnabled defaults to true in {os.path.basename(js_path)}")
except Exception as e:
    print(f"Warning: Failed to patch frontend webSearchEnabled defaults: {e}")

# Patch backend middleware to auto-enable web_search and inherit toolIds
try:
    mw_path = "/app/backend/open_webui/utils/middleware.py"
    if os.path.exists(mw_path):
        with open(mw_path, "r", encoding="utf-8") as f:
            content = f.read()
        changed = False
        mw_target1 = "    features = form_data.pop('features', None) or {}\n    extra_params['__features__'] = features"
        mw_repl1 = "    features = form_data.pop('features', None) or {}\n    if 'web_search' not in features and await Config.get('web.search.enable'):\n        features['web_search'] = True\n    extra_params['__features__'] = features"
        if mw_target1 in content:
            content = content.replace(mw_target1, mw_repl1)
            changed = True

        mw_target2 = "        # Server side tools\n        tool_ids = metadata.get('tool_ids', None)"
        mw_repl2 = "        # Server side tools\n        tool_ids = metadata.get('tool_ids', None)\n        if not tool_ids and task_model_id in models:\n            tool_ids = list(models[task_model_id].get('info', {}).get('meta', {}).get('toolIds') or [])"
        if mw_target2 in content:
            content = content.replace(mw_target2, mw_repl2)
            changed = True

        if changed:
            with open(mw_path, "w", encoding="utf-8") as f:
                f.write(content)
            print("Patched backend middleware for default web_search and toolIds")
except Exception as e:
    print(f"Warning: Failed to patch backend middleware: {e}")
PYEOF
        then
          succ "Open WebUI の標準設定を更新しました (モデル: ${REGISTERED_MODEL:-未設定}, ロケール: ${OPEN_WEBUI_DEFAULT_LOCALE:-ja-JP})"
        else
          warn "Open WebUI の標準設定に失敗しました (UI の Settings > Interface から手動で設定してください)"
        fi
      else
        warn "Open WebUI Pod が見つからないため標準設定をスキップしました"
      fi
    fi
  fi
fi
