# K3D on Podman - Ansible Playbooks

本ディレクトリは、K3D クラスタおよび付随コンポーネント（Keycloak, Ceph (Rook-Ceph), Harbor, Rancher, Monitoring）を Ansible により宣言的かつ冪等にデプロイするための基盤です。

## ディレクトリ構成

```
ansible/
├── ansible.cfg              # Ansible 設定ファイル (ローカル実行用)
├── inventory.ini            # インベントリ定義 (localhost)
├── requirements.yml         # 依存コレクション (kubernetes.core, containers.podman 等)
├── group_vars/
│   └── all.yml              # クラスタ・サービスのパラメータ設定 (config.env から移行)
├── playbooks/
│   ├── site.yml             # 全フェーズ一括実行 (Phase 1〜5 / --tags 群組)
│   ├── cluster.yml          # クラスタ基盤プロビジョニング (Phase 1)
│   ├── storage_auth.yml     # 認証・ストレージ基盤 (Phase 2)
│   ├── apps.yml             # アプリケーション・DB・管理基盤 (Phase 3)
│   ├── oidc.yml             # OIDC 統合・認証情報保存 (Phase 4)
│   ├── backup-restore.yml   # バックアップ & リストア (ラッパー: backup.yml / restore.yml)
│   └── teardown.yml         # クラスタ停止・クリーンアップ
├── shared/
│   └── tasks/
│       └── helm_repo.yml     # Helm リポジトリ冪等登録 (7 ロール共通 import)
└── roles/
    ├── host_setup/          # Podman ソケット、ネットワーク作成、NetworkManager 設定
    ├── k3d_cluster/         # config.yaml 生成、k3d 作成 (--wait)、fetch による kubeconfig 同期、HA 化
    ├── keycloak/            # PostgreSQL replication & Keycloak HA & pgAdmin 4 (Harbor/Grafana DB 含む)
    ├── rook_ceph/           # Ceph HA3 (MON/MGR/MDS/OSD/RGW) & S3 バケット・メトリクス設定
    ├── harbor/              # Harbor HA (Portal/Core/Registry/Jobservice 3, keycloak-pg 共有, Ceph S3 永続化)
    ├── rancher/             # cert-manager & Rancher HA
    ├── monitoring/          # kube-prometheus-stack & Grafana (PostgreSQL データソース & Overview ダッシュボード)
    ├── kubevirt/            # KubeVirt / CDI / KubeVirt Manager (日本語化) / KCCM (post-renderer 二段防御)
    ├── amd_gpu/             # AMD GPU Device Plugin (ROCm k8s-device-plugin)
    ├── oidc_integration/   # Keycloak クライアント・マッパー登録、Realm 国際化・イベント追跡、SSO 有効化 (Rancher UI 日本語化は rancher ロールへ移管)
    └── cluster_teardown/    # クラスタ停止・残存リソース削除
```


## クイックスタート

### 1. 依存コレクションのインストール

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 2. パラメータの編集

[group_vars/all.yml](file:///home/masashi/ai/projects/k3d-on-podman/ansible/group_vars/all.yml) を編集して、クラスタ名やノード数、ドメイン名、パスワード、ネットワーク CIDR (`podman_network_cidr`, `k8s_service_cidr` 等)、各種サービス待受ポート (`k8s_api_port`, `http_port`, `postgres_port` 等)、およびカーネルチューニングパラメータ (`sysctl_*`) を一元的に設定（Single Source of Truth）します。
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

## 段階的移行ロードマップ

- [x] **Phase 1: クラスタ基盤整備**
  - Podman ソケット有効化・権限設定
  - DNS 有効な Podman ネットワーク (`k3d`) の作成
  - `config.yaml` の動的生成と K3D クラスタ作成 (`--wait`)
  - ノード Ready 状態待機と `fetch` (Remote → Local) による動的ポート対応 kubeconfig の配置 (`~/.kube/config`)
  - CoreDNS, local-path-provisioner, metrics-server の HA 化
- [x] **Phase 2: 認証・ストレージ基盤**
  - Keycloak PostgreSQL (HA replication, postgres-exporter メトリクス有効, NetworkPolicy プライベート保護, Harbor/Grafana と共有利用) & Keycloak HA, pgAdmin 4 (3 レプリカ, Keycloak/Harbor/Grafana サーバー自動登録)
  - Ceph HA3 (ROOK_CEPH) & バケット作成・OIDCポリシー作成
- [x] **Phase 3: アプリケーション・DB基盤**
  - Harbor (HA 3 レプリカ, keycloak-pg 共有 DB & Ceph S3 永続化 & Keycloak OIDC SSO & Proxy Cache)
  - Rancher (cert-manager & HA) & fleet パッチ
  - Monitoring Stack (Prometheus & Grafana, PostgreSQL データソース & Overview ダッシュボード)

- [x] **Phase 4: OIDC 統合・停止処理**
  - Keycloak OIDC クライアント (Rancher, Ceph, Grafana, Harbor) 登録
  - Realm 国際化 (日本語化)、Rancher Keycloak SSO 有効化、プロトコルマッパー・管理者設定
  - Rancher UI 完全日本語化（`ja.yaml` からの Webpack 言語チャンク動的生成、キャッシュバスター、全 Rancher Pod への自動ホット適用）
  - 認証情報の画面表示および `secrets.txt` 保存
  - 停止・クリーンアップ Playbook (`teardown.yml`) の実装
