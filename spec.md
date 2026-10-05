# Ollama on K3D デプロイメント仕様書 (spec.md)

## 概要
本プロジェクトは、Podman 環境上にローカル AI / LLM ワークロード（Lemonade, FastFlowLM, Open WebUI）に特化した K3D Kubernetes クラスタ（クラスタ名: `ollama-cluster`）を自動デプロイするための自動化基盤です。

**本プロジェクトのデプロイメントは、Shell スクリプト（start.sh）および Ansible Playbook により自動化する。**

### デザイン原則
- **構成管理**: `config.env`（Shell 向け）および `ansible/group_vars/all.yml`（Ansible 向け）でクラスタ設定を一元定義（Single Source of Truth）。
- **ホスト CPU コアの最適分離**:
  - ホストの 32 コア (AMD Ryzen AI Max+ 395 等) を **Server ノード (8 コア: 0-7)** と **Worker ノード (24 コア: 8-31)** に厳密に分離・割当。
  - Server ノードには CORE・SSO・監視基盤を集約し、Worker ノードに AI/LLM ワークロード（Lemonade, FastFlowLM, Open WebUI）を集中配置。
- **ハードウェアアクセラレーション対応**:
  - AMD GPU (ROCm: `/dev/kfd`, `/dev/dri`) および AMD NPU (XDNA: `/dev/accel`) をノードコンテナへパススルーし、K8s Device Plugin により透過的に提供。
  - AMD XDNA NPU の Turbo モード (最大クロック・パフォーマンス) を自動検出・有効化。
- **軽量・単一インスタンス構成**:
  - Ceph、Harbor、KubeVirt、Backup/Restore を排除し、軽量・シンプルな構成に特化。
  - ストレージは K3s 標準の `local-path` を全面採用。
- **完全日本語化対応**:
  - Open WebUI、Rancher UI、Grafana、ドキュメントの完全日本語化。

---

## 1. システム構成

### 1.1 ノード構成
| ノードタイプ | ノード名 | CPU コア数 | CPU 割当 (cpuset) | ラベル | 説明 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Server** | `k3d-ollama-cluster-server-0` | 8 | `0-7` | `tier=core, role=control-plane, node-role.kubernetes.io/control-plane=true` | CORE/SSO/監視基盤配置用コントロールプレーンノード |
| **Worker** | `k3d-ollama-cluster-agent-0` | 24 | `8-31` | `tier=ai, role=worker, node-role.kubernetes.io/worker=true` | AI/LLM/推論基盤配置用ワーカーノード (GPU/NPU パススルー) |

### 1.2 ネットワーク構成
| 項目 | 設定変数名 | デフォルト値 | 説明 |
| :--- | :--- | :--- | :--- |
| Podman ネットワーク | `NETWORK` | `k3d` | Podman 仮想ブリッジネットワーク (DNS 有効) |
| Podman ネットワーク CIDR | `PODMAN_NETWORK_CIDR` | `10.89.0.0/24` | Podman 仮想ブリッジサブネット |
| Podman ゲートウェイ IP | `PODMAN_NETWORK_GATEWAY` | `10.89.0.1` | Podman 仮想ブリッジデフォルトゲートウェイ |
| ホスト DNS リッスン IP | `CLUSTER_DNS_IP` | `127.0.0.1` | NetworkManager 内蔵 dnsmasq 待受 IP |
| Kubernetes Service CIDR | `K8S_SERVICE_CIDR` | `10.43.0.0/16` | Kubernetes 内部 Service (ClusterIP) 範囲 |
| Kubernetes Cluster CIDR | `K8S_CLUSTER_CIDR` | `10.42.0.0/16` | Flannel Pod 割り当て CIDR 範囲 |
| ノード別 Pod CIDR マスク | `K8S_NODE_CIDR_MASK_SIZE` | `24` | ノード単位 Pod CIDR マスク (/24 = 256 Pod) |
| Kubernetes API ポート | `K8S_API_PORT` | `6443` | Kubernetes API Server 待受ポート |
| Traefik HTTP ポート | `HTTP_PORT` | `80` | Ingress HTTP 待受ポート (HTTPS へリダイレクト) |
| Traefik HTTPS ポート | `HTTPS_PORT` | `443` | Ingress HTTPS 待受ポート (TLS 終端) |
| Traefik 管理 UI ポート | `TRAEFIK_ADMIN_PORT` | `8080` | Traefik 管理ダッシュボードポート |
| PostgreSQL ポート | `POSTGRES_PORT` | `5432` | Keycloak 運用 PostgreSQL 待受ポート |
| Keycloak ポート | `KEYCLOAK_HTTP_PORT` | `8080` | Keycloak HTTP 待受ポート |
| Grafana Web ポート | `GRAFANA_PORT` | `3000` | Grafana Web UI 待受ポート |
| Prometheus ポート | `PROMETHEUS_PORT` | `9090` | Prometheus 待受ポート |
| Alertmanager ポート | `ALERTMANAGER_PORT` | `9093` | Alertmanager 待受ポート |
| Lemonade API ポート | `LEMONADE_PORT` | `11434` | Lemonade (Ollama 互換) LLM API 待受ポート |
| FastFlowLM API ポート | `NPU_FLM_PORT` | `52625` | FastFlowLM (OpenAI 互換) NPU API ホスト待受ポート |
| Open WebUI ポート | `OPEN_WEBUI_PORT` | `8080` | Open WebUI Web チャット待受ポート |
| pgAdmin 4 ポート | `PGADMIN_PORT` | `80` | pgAdmin 4 Web コンソール待受ポート |

---

## 2. 設定管理

### 2.1 config.env
クラスタ設定を一元管理する環境変数ファイル（Single Source of Truth）。

```bash
CLUSTER_NAME="ollama-cluster"
SERVERS=1
AGENTS=1
SERVER_CPUS=8
AGENT_CPUS=24
SERVER_CPUSET="0-7"
AGENT_CPUSET="8-31"
NETWORK="k3d"
ENABLE_NETWORK_POLICY=true
DISABLE_TRAEFIK=false
KUBELET_USER_NAMESPACE=true
PRE_IMPORT_IMAGES=true
K3D_GPUS="all"

# AI ワークロード設定 (Lemonade / GPU LLM)
LEMONADE_ENABLED=true
LEMONADE_PORT=11434
LEMONADE_STORAGE_SIZE="30Gi"
LEMONADE_STORAGE_CLASS="local-path"
LEMONADE_DEFAULT_MODEL="Qwen3.8-27B-GGUF"
LEMONADE_DEFAULT_MODEL_AUTO_SETUP=true
LEMONADE_DEFAULT_MODEL_SETUP_RETRIES=30
LEMONADE_DEFAULT_MODEL_SETUP_RETRY_INTERVAL=2

OPEN_WEBUI_ENABLED=true
OPEN_WEBUI_NAMESPACE="open-webui"
OPEN_WEBUI_PORT=8080
OPEN_WEBUI_STORAGE_SIZE="30Gi"
OPEN_WEBUI_STORAGE_CLASS="local-path"
```

---

## 3. ワークロード配置とハードウェアアクセラレーション

### 3.1 Server ノード (8 コア: 0-7) 割当
- **目的**: クラスタコントロールプレーンおよび統合認証・運用監視スタックの安定稼働。
- **配置ワークロード**:
  - `kube-system`: CoreDNS, Traefik, metrics-server, local-path-provisioner
  - `keycloak`: Keycloak (SSO 認証), PostgreSQL (運用 DB), pgAdmin 4
  - `cattle-system`: Rancher Manager, Rancher Webhook, cert-manager
  - `cattle-monitoring-system`: Prometheus, Grafana, Alertmanager
- **nodeSelector**: `node-role.kubernetes.io/control-plane: "true"`

### 3.2 Worker ノード (24 コア: 8-31) 割当
- **目的**: 大規模言語モデル (LLM) 推論および Web フロントエンドの実行。CPU 24 コアの集中投入と GPU/NPU ハードウェアアクセラレーション。
- **配置ワークロード**:
  - `lemonade`: Lemonade Server (AMD ROCm GPU パススルー, Ollama 互換 API)
  - FastFlowLM (ホスト常駐プロセス, AMD XDNA NPU): Open WebUI から `http://<gateway>:52625/v1` で直接参照
  - `open-webui`: Open WebUI フロントエンドチャット UI (local-path PVC 30Gi)
  - `kube-system`: AMD GPU Device Plugin, AMD NPU Device Plugin
- **nodeSelector**: `node-role.kubernetes.io/worker: "true"`
- **デバイスパススルー**:
  - AMD GPU: `/dev/kfd`, `/dev/dri`
  - AMD NPU: `/dev/accel`

---

## 4. Ansible Playbook 構成

デプロイメントは `ansible/playbooks/site.yml` により宣言的・冪等に実行されます。

| フェーズ | Playbook | 実行ロール | 主な処理内容 |
| :--- | :--- | :--- | :--- |
| **Phase 1** | `cluster.yml` | `host_setup` | Podman ソケット、k3d ネットワーク作成、dnsmasq 準備 |
| | | `k3d_cluster` | `config.yaml` 生成、クラスタ起動、kubeconfig 同期、CPU 割当 (`podman update --cpus 8/24`)、ノードラベリング |
| **Phase 2** | `storage_auth.yml` | `keycloak` | PostgreSQL + Keycloak + pgAdmin 4 デプロイ (Server ノード) |
| **Phase 3** | `apps.yml` | `rancher` | cert-manager、内部 CA、Rancher デプロイ (Server ノード) |
| | | `monitoring` | Prometheus, Grafana, AI & LLM 監視ダッシュボードデプロイ (Server ノード) |
| | | `amd_gpu` | AMD GPU / NPU Device Plugin デプロイ (Worker ノード) |
| | | `lemonade` | Lemonade Server (GPU LLM / Ollama 互換 API), PVC (`local-path`), Prometheus `/metrics` (Worker ノード) |
| | | `open_webui` | Open WebUI デプロイ, Lemonade / FastFlowLM 連携, Keycloak SSO 連携 (Worker ノード) |
| **Phase 4** | `oidc.yml` | `oidc_integration` | Keycloak クライアント・マッパー自動登録 (Open WebUI, Rancher, Grafana, pgAdmin, Traefik)、`secrets.txt` 出力 |
| **Phase 5** | - | `cluster_teardown` | 一時キャッシュの整理 |

---

## 5. 公開 URL とアクセス情報 (デフォルト)

| サービス名 | 公開 URL | 認証方式 | 初期管理者ユーザー |
| :--- | :--- | :--- | :--- |
| **Open WebUI (Local AI)** | `https://chat.philippines.com.ph` | Keycloak OIDC SSO (ワンクリック) | `admin` |
| **Lemonade API (Ollama 互換)** | `https://lemonade.philippines.com.ph` | API Direct | - |
| **FastFlowLM (OpenAI 互換)** | `http://10.89.0.1:52625/v1` (ホスト直結・非公開) | 内部 API | - |
| **Keycloak 管理コンソール** | `https://keycloak.philippines.com.ph/admin` | 管理者認証 | `admin` / `admin` |
| **pgAdmin 4** | `https://pgadmin.philippines.com.ph` | Keycloak OIDC SSO | `admin@philippines.com.ph` / `admin` |
| **Grafana** | `https://grafana.philippines.com.ph` | Keycloak OIDC SSO | `admin` / `admin` |
| **Traefik Dashboard** | `https://traefik.philippines.com.ph/dashboard/` | Keycloak OIDC SSO | `admin` / `admin` |
| **Rancher** | `https://rancher.philippines.com.ph` | Keycloak OIDC SSO | `admin` / `admin12345` |
