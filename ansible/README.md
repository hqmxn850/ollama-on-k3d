# Ollama on K3D - Ansible Playbooks

本ディレクトリは、Ollama on K3D クラスタおよび AI / LLM ワークロード基盤（Lemonade, FastFlowLM, Open WebUI, AMD ROCm/XDNA Device Plugin, Keycloak, Rancher, Monitoring）を Ansible により宣言的かつ冪等にデプロイするための基盤です。

## ディレクトリ構成

```text
ansible/
├── ansible.cfg              # Ansible 設定ファイル (ローカル実行用)
├── inventory.ini            # インベントリ定義 (localhost)
├── requirements.yml         # 依存コレクション (community.general, kubernetes.core 等)
├── group_vars/
│   └── all.yml              # クラスタ・サービスのパラメータ設定 (Single Source of Truth)
├── playbooks/
│   ├── site.yml             # 全フェーズ一括実行 (Phase 1〜5 / --tags 群組)
│   ├── cluster.yml          # クラスタ基盤プロビジョニング (Phase 1)
│   ├── storage_auth.yml     # 認証・PostgreSQL基盤 (Phase 2)
│   ├── apps.yml             # Rancher・監視・AI/LLM基盤 (Phase 3)
│   ├── oidc.yml             # OIDC 統合・認証情報保存 (Phase 4)
│   └── teardown.yml         # クラスタ停止・クリーンアップ
├── shared/
│   └── tasks/
│       └── helm_repo.yml     # Helm リポジトリ冪等登録 (各ロール共通 import)
└── roles/
    ├── host_setup/          # Podman ソケット、ネットワーク作成、NetworkManager 設定
    ├── k3d_cluster/         # config.yaml 生成、k3d 作成 (--wait)、kubeconfig 同期、CPUクォータ設定
    ├── keycloak/            # PostgreSQL replication & Keycloak & pgAdmin 4
    ├── rancher/             # cert-manager & Rancher Manager (i18n 日本語化)
    ├── monitoring/          # kube-prometheus-stack & Grafana (PostgreSQL データソース & ダッシュボード)
    ├── amd_gpu/             # AMD GPU (ROCm) & AMD NPU (XDNA) Device Plugin
    ├── lemonade/            # Lemonade Server (ローカル Helm チャート) & モデル pull スクリプト
    ├── open_webui/          # Open WebUI (Local AI Web チャット基盤)
    ├── oidc_integration/   # Keycloak クライアント・マッパー登録、OIDC SSO 統合
    └── cluster_teardown/    # クラスタ停止・残存リソース削除・イメージキャッシュ保存
```

## クイックスタート

### 1. 依存コレクションのインストール

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 2. パラメータの編集

[group_vars/all.yml](file:///home/masashi/ai/projects/ollama-on-k3d/ansible/group_vars/all.yml) および `config.env` を編集して、クラスタ名やノード数、ドメイン名、パスワード、各種サービス待受ポート、およびカーネルチューニングパラメータを一元的に設定（Single Source of Truth）します。
`start.sh` 経由で実行する場合は、`config.env` の設定値が Ansible extra-vars として自動反映されます。

### 3. クラスタの起動 (完全自動デプロイ)

```bash
cd ansible
ansible-playbook playbooks/site.yml
```

### 4. クラスタの停止 (クリーンアップ)

```bash
cd ansible
ansible-playbook playbooks/teardown.yml
```

## デプロイメントフェーズ概要

- **Phase 1: クラスタ基盤プロビジョニング (`cluster.yml`)**
  - Podman ソケット有効化・権限設定
  - DNS 有効な Podman ネットワーク (`k3d`) の作成
  - `config.yaml` の動的生成と K3D クラスタ作成 (`--wait`)
  - Server (8コア: 0-7) / Worker (24コア: 8-31) の CPU 制限適用とノードラベリング
  - kubeconfig の配置 (`~/.kube/config`)
- **Phase 2: 認証基盤プロビジョニング (`storage_auth.yml`)**
  - Keycloak PostgreSQL (単一インスタンス, NetworkPolicy プライベート保護)
  - Keycloak SSO 認証基盤 & pgAdmin 4
- **Phase 3: アプリケーション・AI・監視基盤プロビジョニング (`apps.yml`)**
  - Rancher (cert-manager & Rancher Manager, UI 完全日本語化)
  - モニタリング基盤 (Prometheus & Grafana, PostgreSQL / AI & LLM ダッシュボード自動ロード)
  - AMD GPU (ROCm) & AMD NPU (XDNA) Device Plugin
  - Lemonade Server (GPU LLM 推論 / Ollama 互換 API + Prometheus `/metrics`)
  - FastFlowLM (OpenAI 互換 NPU API / ホスト常駐, Open WebUI から直接参照)
  - Open WebUI (Local AI Web チャット UI)
- **Phase 4: Keycloak OIDC 統合・認証情報出力 (`oidc.yml`)**
  - Keycloak OIDC クライアント (Open WebUI, Rancher, Grafana, pgAdmin, Traefik) 登録
  - Realm 国際化 (日本語化)、SSO ワンクリックログイン有効化
  - 認証情報の画面表示および `secrets.txt` 保存
- **Phase 5: クラスタ健全化 & クリーンアップ**
  - 不要な ReplicaSet の自動クリーンアップ
  - サーバーノード配置パッチの最終適用
