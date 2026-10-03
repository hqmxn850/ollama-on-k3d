# Ollama on K3D クラスタ自動デプロイプロジェクト - ゴールと現状

本ドキュメントは、Podman 環境上に K3D を用いてローカル AI / LLM 実行環境（Ollama, Open WebUI, OGA 等）を備えたクラスタを完全自動デプロイするプロジェクト（本リポジトリ）の**全体ゴール**と**現状**を整理する。

## 1. プロジェクトゴール

- Podman 上の単一ホストに、ローカル AI 特化型 K3D クラスタを **1コマンドで自動デプロイ**する（Shell スクリプトおよび Ansible Playbook をサポート）。
- **ホスト CPU コアの最適分離**:
  - ホストの 32 コア (AMD Ryzen AI Max+ 395 等) を **Server ノード (8 コア: 0-7)** と **Worker ノード (24 コア: 8-31)** に厳密に分離・割当。
  - Server ノードには管理・CORE・SSO・監視基盤を集約し、Worker ノードに AI/LLM ワークロード（Ollama, OGA, Open WebUI）を集中配置。
- **ハードウェアアクセラレーション対応**:
  - AMD GPU (ROCm: `/dev/kfd`, `/dev/dri`) および AMD NPU (XDNA: `/dev/accel`) をノードコンテナへパススルーし、K8s Device Plugin により Pod にリソースを透過的に提供。
- **軽量・高効率な単一インスタンス構成**:
  - HA (多重化)、Ceph、Harbor、KubeVirt、Backup/Restore 機能は排除し、軽量・シンプルな構成に特化。
  - ストレージは K3s 標準の `local-path` を全面採用。
- **設定・URL・エンドポイントの一元管理 (Single Source of Truth)**:
  - `ansible/group_vars/all.yml` および `config.env` により、各サービス公開/内部 URL、名前空間、待機タイムアウト、リソース割当を完全変数化（ハードコード禁止）。
- **完全日本語化対応**:
  - Open WebUI、Rancher UI、Grafana、ドキュメントの完全日本語化。

### クラスタ構成（デフォルト）

| 項目 | 値 |
| :--- | :--- |
| クラスタ名 | `ollama-cluster` |
| サーバーノード (Server) | 1 台 (CPU 8コア: `0-7`, ラベル `tier=core, role=control-plane`) |
| エージェントノード (Worker) | 1 台 (CPU 24コア: `8-31`, ラベル `tier=ai, role=worker`) |
| K3s イメージ | 最新安定版を自動取得 (`versions.env` 連動) |
| ネットワーク | `k3d` (DNS 有効, CIDR: `10.89.0.0/24`, Gateway: `10.89.0.1`) |
| Kubernetes 内部ネットワーク | Service: `10.43.0.0/16`, Pod: `10.42.0.0/16` (/24 マスク, Flannel host-gw, iptables) |
| 主要公開ポート | K8s API: 6443, HTTP: 80, HTTPS: 443 |
| 主要内部ポート | PostgreSQL: 5432, Ollama: 11434, OGA: 8000, Open WebUI: 8080, Grafana: 3000 |
| ストレージクラス | `local-path` (K3s 標準 host-path プロビジョナ) |
| Open WebUI (Local AI Web UI) | 1 レプリカ (Worker ノード配置, Keycloak OIDC SSO, local-path 30Gi PVC) |
| Ollama (LLM 実行エンジン) | 1 レプリカ (Worker ノード配置, AMD GPU/ROCm アクセラレーション, local-path 30Gi PVC) |
| OnnxRuntime GenAI (OGA) | 1 レプリカ (Worker ノード配置, AMD NPU/XDNA アクセラレーション, local-path 30Gi PVC) |
| Device Plugin | AMD GPU Device Plugin (`/dev/kfd`, `/dev/dri`), AMD NPU Device Plugin (`/dev/accel`) |
| Rancher | 1 レプリカ (Server ノード配置, Keycloak OIDC SSO, UI 完全日本語化) |
| cert-manager | 1 レプリカ (Server ノード配置, クラスタ内部 CA 自動発行) |
| Keycloak | 1 レプリカ (Server ノード配置, OIDC 統合認証基盤) |
| PostgreSQL | 1 レプリカ (Server ノード配置, Keycloak 運用 DB) |
| pgAdmin 4 | 1 レプリカ (Server ノード配置, Keycloak OIDC SSO, DB 自動登録済み) |
| kube-prometheus-stack | Prometheus + Grafana (Server ノード配置, Keycloak OIDC, 日本語対応, Ollama Exporter 監視ダッシュボード) |
| DNS | dnsmasq (NetworkManager 経由, `127.0.0.1:53`) |

## 2. デプロイフロー

### Ansible Playbook (`ansible/playbooks/site.yml`) / ラッパー (`start.sh`)

`start.sh` を実行すると、`config.env` を読み込んで Ansible の extra-vars (JSON) に変換し、以下のフェーズが完全自動実行されます。

| フェーズ | ロール | 配置ノード | 内容 |
| :--- | :--- | :--- | :--- |
| **Phase 1** | `host_setup` | ホスト | Podman ソケット有効化、k3d ネットワーク作成、dnsmasq 準備 |
| | `k3d_cluster` | Server / Worker | K3s 最新版取得、`config.yaml` 生成、クラスタ作成（`--wait`）、ノード Ready 待機、kubeconfig 同期、CPU コア割当 (`podman update --cpus 8/24`)、ノードラベリング (`tier=core`, `tier=ai`) |
| **Phase 2** | `keycloak` | Server | PostgreSQL + Keycloak + pgAdmin 4 デプロイ、DB 初期化 |
| **Phase 3** | `rancher` | Server | cert-manager、内部ルート CA 発行、Rancher デプロイ、dnsmasq 登録 |
| | `monitoring` | Server | kube-prometheus-stack、Grafana (日本語/OIDC 連携, Ollama 監視ダッシュボード, PostgreSQL 監視) |
| | `amd_gpu` | Worker | AMD GPU / ROCm Device Plugin & AMD NPU (XDNA) Device Plugin デプロイ |
| | `ollama` | Worker | Ollama LLM サービスデプロイ、モデル永続 PVC、Prometheus Exporter |
| | `oga` | Worker | OnnxRuntime GenAI サービスデプロイ、NPU パススルー |
| | `open_webui` | Worker | Open WebUI Web チャット基盤デプロイ、Ollama 連携、Keycloak SSO 連携 |
| **Phase 4** | `oidc_integration` | Server | Keycloak クライアント/マッパー登録 (Open WebUI, Rancher, Grafana, pgAdmin 4, Traefik)、Realm 国際化 (日本語化)、認証情報出力 (`secrets.txt`) |
| **Phase 5** | `cluster_teardown` | - | 一時キャッシュ・残存リソース健全化 |

Playbook 実行完了後、`start.sh` により以下が自動実行されます：
1. **クラスタ疎通確認**: `kubectl cluster-info` による API サーバー疎通テスト
2. **Grafana 初期設定 (Preferences API)**: Home Dashboard (`rancher-home-1`)、タイムゾーン (`Asia/Tokyo`)、言語 (`ja-JP`) の自動反映
3. **各コンソール URL・認証情報の一覧画面表示**: Open WebUI、Ollama、Keycloak、pgAdmin 4、Grafana、Traefik Dashboard、Rancher のコンソール URL、ユーザー ID、パスワード、接続コマンドを端末末尾にフォーマット表示

## 3. 停止・クリーンアップフロー

### Ansible Playbook (`ansible/playbooks/teardown.yml`) / ラッパー (`stop.sh`)

1. **クラスタイメージの Podman 保存・一覧更新**:
   - `kubectl get pods -A` から稼働中 Pod のイメージを抽出し、カテゴリ別に整理して `images.txt` を自動更新
   - 未キャッシュイメージを `sudo podman pull` でホストのローカルストレージにキャッシュ保存
2. **ルート CA 証明書の登録解除**:
   - ホスト OS のトラストストアから K3D ルート CA 証明書を削除
3. **リソース削除** (`cluster_teardown` ロール):
   - `config.env` からクラスタ名を読み込み、K3D クラスタ削除、残存コンテナ/ボリューム/ネットワークのクリーンアップ、NetworkManager dnsmasq 設定解除

## 4. 関連ドキュメント・ファイル構成

- [spec.md](file:///home/masashi/ai/projects/ollama-on-k3d/spec.md) … 詳細仕様・設計・Ansible 構成・トラブルシューティング
- [AGENTS.md](file:///home/masashi/ai/projects/ollama-on-k3d/AGENTS.md) … 運用・開発エージェント向け指示書・設定変数・OIDC 設定
- [README.md](file:///home/masashi/ai/projects/ollama-on-k3d/README.md) … プロジェクト概要・クイックスタート・利用手順
- [NETWORK.md](file:///home/masashi/ai/projects/ollama-on-k3d/NETWORK.md) … ネットワーク構成仕様書
- [TEST.md](file:///home/masashi/ai/projects/ollama-on-k3d/TEST.md) … テスト仕様書
- `config.env` … クラスタ設定変数ファイル (Single Source of Truth)
- `versions.env` … バージョン情報ファイル (K3s/Helm/コンテナイメージ)
- `start.sh` … クラスタ起動スクリプト (Ansible ラッパー / config.env 自動連携 / 一覧表示)
- `stop.sh` … クラスタ停止スクリプト (Ansible ラッパー / config.env 自動連携 / イメージ保存・更新)
- `upgrade.sh` … 最新版検索 & 自動アップグレードスクリプト
- `trust-ca.sh` … K3D ルート CA 証明書のホスト OS 自動信頼登録 / 削除スクリプト
- `ollama-pull.sh` … Kubernetes 上の Ollama モデル pull / 管理スクリプト
- `test.sh` … 総合テストランナー (単体・構文・E2Eテスト)
- `tests/` … テストスイート (`test-unit.sh`, `test-e2e.sh`)
- `ansible/` … Ansible プレイブック・ロール群
