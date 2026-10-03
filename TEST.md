# テスト仕様書 (Test Specification)

本ドキュメントは、Ollama on K3D 環境における自動化テストスイート、機能別検証項目、エンドツーエンド (E2E) ライフサイクルテスト、および AI / LLM ワークロード動作確認の仕様と実施手順を定義した仕様書です。

---

## 1. 概要とテスト方針

### 1.1 目的
- K3D クラスタ（Server 1ノード 8コア / Worker 1ノード 24コア）およびローカル AI スタック（Ollama, OGA, Open WebUI, Keycloak, PostgreSQL, pgAdmin 4, Rancher, Monitoring Stack）の正常性、ハードウェアアクセラレーション透過性、セキュリティ分離、冪等性を検証する。
- スクリプト・Playbook の構文検証から、個別機能、コンポーネント間連携、E2E ライフサイクル（作成・停止・アップグレード・クリーンアップ）までを一貫して自動検証できる体制を確立する。

### 1.2 テストレベル分類

| テスト種別 | 実行コマンド | 対象スコープ | 特徴 |
| :--- | :--- | :--- | :--- |
| **単体・個別機能テスト (Unit)** | `./test.sh --unit`<br>`tests/test-unit.sh` | スクリプト構文、Ansible 構文、インベントリ、引数バリデーション、非破壊イメージ抽出、Jinja2 テンプレート構文、`--tags` 選択整合性、共通タスク整合性 | 非破壊・高速（数秒〜十数秒）。クラスタ停止中・起動中の双方で安全に実行可能。 |
| **全体ライフサイクルテスト (E2E)** | `./test.sh --e2e`<br>`tests/test-e2e.sh` | クラスタ起動 (`start.sh`)、ノード・Pod 健全性、AI サービス疎通、クラスタ停止 (`stop.sh`)、キャッシュ保存、完全削除 | クラスタの再作成を伴う包括的ライフサイクル検証（約 5〜10 分）。 |
| **自動アップグレードテスト (Upgrade)** | `./upgrade.sh --check` | K3s、全 Helm Chart、主要コンテナイメージの最新版検索・バージョン比較 | 既存環境を破壊せずに最新バージョン差分を検出・表示。 |
| **機能別統合検証 (Component)** | `kubectl` / `curl` 手動実行 | 各サービスの個別詳細機能（SSO、Ollama API、NPU デバイス、ダッシュボード等） | 本仕様書に記載の検証コマンドによる各コンポーネントの動作確認。 |

---

## 2. テスト実行環境・前提条件

### 2.1 ハードウェア & OS 要件
- **OS**: Linux (cgroup v2 有効)
- **CPU / メモリ**: 32 コア (Server 8 + Worker 24) / 32 GB 以上推奨
- **ハードウェアアクセラレーション**: AMD ROCm 対応 GPU (`/dev/kfd`, `/dev/dri`)、AMD XDNA 対応 NPU (`/dev/accel`)
- **ディスク**: 空き容量 40 GB 以上

### 2.2 依存ツール要件
- **Podman**: 4.x / 5.x (`sudo podman` で実行可能であること)
- **k3d**: v5.x 以上
- **Ansible**: core 2.15+ (コレクション: `community.general`, `kubernetes.core`)
- **kubectl**: v1.28+
- **helm**: v3.12+
- **CLI ユーティリティ**: `jq`, `curl`, `python3`, `bash` (4.x+)

---

## 3. テストスイート詳細仕様

### 3.1 単体・個別機能テスト (`tests/test-unit.sh`)

#### 【TC-UNIT-01】スクリプト構文検証 (Shell / Python)
- **前提**: プロジェクトルートに各スクリプトが存在すること。
- **操作**: `bash -n <script>` および `python3 -m py_compile <script>` を実行。
  - 対象: `start.sh`, `stop.sh`, `upgrade.sh`, `test.sh`, `tests/*.sh`, `import-images.sh`, `lib/common.sh`, `save-images.sh`, `patch-rancher-i18n.sh`, `ollama-pull.sh`, `patch-dashboards.py`
- **期待結果**: 全ファイルで構文エラー (Syntax Error) が検出されず、リターンコード 0 で終了すること。

#### 【TC-UNIT-02】設定変数ファイル検証 (`config.env` / `versions.env`)
- **前提**: `config.env` および `versions.env` が存在すること。
- **操作**: `bash -u config.env` および `bash -u versions.env` を実行。
- **期待結果**: ネットワーク CIDR、待受ポート番号、CPU コア割当変数を含む全定義変数において、未割り当て変数による評価エラーが発生せず、正常に読み込めること。

#### 【TC-UNIT-03】Ansible Playbook 構文 & インベントリ・変数解決検証
- **前提**: `ansible.cfg`, `inventory.ini`, `group_vars/all.yml` が存在すること。
- **操作**: 
  - `ansible-playbook -i ansible/inventory.ini --syntax-check ansible/playbooks/*.yml`
  - `ansible-inventory -i ansible/inventory.ini --list`
- **期待結果**: 
  - `site.yml`, `cluster.yml`, `storage_auth.yml`, `apps.yml`, `oidc.yml`, `teardown.yml` の全 Playbook で構文エラーが発生しないこと。
  - 全ホストグループ・変数（ネットワーク CIDR、各種ポート番号、AI サービス設定）が正常に解決されること。
  - 依存コレクション（`community.general`, `kubernetes.core`）が認識されること。

#### 【TC-UNIT-04】スクリプト引数・異常系ハンドリング & 共通関数検証
- **前提**: テスト対象スクリプトが存在すること。
- **操作**:
  - `lib/common.sh` を source し `ensure_command` 等の共通関数が定義されることを確認。
  - `version_ge` 関数によるセマンティックバージョン比較（大小関係・同値）を検証。
  - `ensure_latest_kubectl` および `ensure_latest_helm` 関数の定義と最新バージョン確認・スキップ（冪等性）を検証。
  - `save-images.sh` を無効な KUBECONFIG (`/dev/null`) で実行。
  - `save-images.sh` を環境変数 `_SAVED_IMAGES_DONE=1` 設定下で二重実行。
  - `start.sh --help`, `upgrade.sh --help`, `stop.sh --help`, `trust-ca.sh --help`, `ollama-pull.sh --help` を実行。
- **期待結果**: 各共通関数が正常に評価され、異常系において安全なスキップメッセージまたはヘルプ画面を出力して終了すること。

#### 【TC-UNIT-05】Jinja2 テンプレート構文 & タグ・共通タスク整合性検証
- **前提**: `ansible/roles/*/templates/*.j2` および `ansible/shared/tasks/helm_repo.yml` が存在すること。
- **操作**:
  - `jinja2.Environment().parse()` で全テンプレートを解析。
  - `ansible-playbook <pb> --list-tasks -t <tag>` を全階層タグ (`cluster`, `storage_auth`, `apps`, `oidc`, `cleanup`, `teardown`, `cluster_teardown`) に対して実行し、該当タスクが 1 件以上選択されることを確認。
  - `import_tasks: ../../../shared/tasks/helm_repo.yml` を宣言するロール数が 6 であることを確認。
- **期待結果**: 全 52 件のテンプレートが構文エラーなく解析でき、全タグで選択タスクが 0 件にならず、共通タスク導入が 6 ロールで維持されること。

---

### 3.2 全体ライフサイクルテスト (`tests/test-e2e.sh`)

#### 【TC-E2E-01】クラスタ自動構築検証
- **前提**: ホスト環境で Podman ソケットが有効であること。
- **操作**: `./start.sh` (または `test.sh --e2e`) を実行。
- **期待結果**:
  - K3D クラスタが正常作成され、全 2 ノード（Server 1: 8コア, Worker 1: 24コア）が `Ready` になること。
  - `~/.kube/config` に kubeconfig が自動生成・配置されること。
  - Phase 1 〜 Phase 4 の全サービスがロールアウト完了すること。

#### 【TC-E2E-02】クラスタ健全性 & 主要 Pod 稼働確認
- **前提**: TC-E2E-01 が完了していること。
- **操作**: `kubectl get pods -A` で各名前空間の Pod 状態を確認。
- **期待結果**:
  - `kube-system`: CoreDNS (1), Traefik (1), metrics-server (1), local-path (1) が Running
  - `keycloak`: Keycloak (1), PostgreSQL (1), Pgpool (1), pgAdmin (1) が Running (Server ノード)
  - `ollama`: Ollama (1), Ollama Exporter (1) が Running (Worker ノード)
  - `open-webui`: Open WebUI (1) が Running (Worker ノード)
  - `cattle-system`: Rancher (1), Rancher Webhook (1) が Running (Server ノード)
  - `cattle-monitoring-system`: Alertmanager (1), Prometheus (1), Prometheus Operator (1), Grafana (1), Node Exporter (2) が Running (Server ノード)

#### 【TC-E2E-03】AI サービス健全性確認
- **前提**: TC-E2E-02 が完了していること。
- **操作**: Ollama API (`https://ollama.philippines.com.ph/api/tags`) および Open WebUI (`https://chat.philippines.com.ph/`) へ疎通。
- **期待結果**: HTTP 200 (またはリダイレクト) が返却されること。

#### 【TC-E2E-04】クラスタ停止 & イメージ自動保存・クリーンアップ検証
- **前提**: クラスタが正常稼働していること。
- **操作**: `./stop.sh` を実行。
- **期待結果**:
  - 停止前に稼働中コンテナイメージが `images.txt` へ自動書き込みされ、ファイルの更新時刻が停止処理開始以降であること。
  - Podman ローカルストレージにイメージがキャッシュ保存されること。
  - `sudo k3d cluster list` でクラスタが完全に削除されていること。
  - NetworkManager の dnsmasq 設定が削除され、ホストの DNS 設定が復元されること。

---

## 4. 機能別統合テスト仕様 (Component Verification)

### 4.1 AI / LLM ワークロード (Ollama / Open WebUI / OGA)

| テスト ID | 検証項目 | 前提条件 | 操作手順 | 期待結果 | 検証コマンド |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TC-AI-01** | Ollama API 疎通 | Ollama 稼働中 | `/api/tags` エンドポイントへアクセス | HTTP 200 およびモデル一覧 JSON が返却されること | `curl -sk https://ollama.philippines.com.ph/api/tags` |
| **TC-AI-02** | AMD GPU パススルー | Worker ノード稼働中 | Ollama Pod 内で ROCm デバイス確認 | `/dev/kfd` および `/dev/dri` がマウントされ、GPU が認識されていること | `kubectl -n ollama exec deploy/ollama -- ls -la /dev/kfd /dev/dri` |
| **TC-AI-03** | AMD NPU パススルー | Worker ノード稼働中 | NPU Device Plugin および OGA Pod 確認 | `/dev/accel` が認識され、NPU リソース (`amd.com/npu`) が割当可能であること | `kubectl describe node -l node-role.kubernetes.io/worker=true \| grep -i "amd.com/npu"` |
| **TC-AI-04** | Open WebUI SSO ログイン | Open WebUI 稼働中 | Web UI へアクセスし Keycloak 認証リダイレクトを確認 | Keycloak OIDC 認証画面が表示され、ワンクリックログインできること | ブラウザで `https://chat.philippines.com.ph` にアクセス |
| **TC-AI-05** | モデル pull / 推論動作 | Ollama 稼働中 | `./ollama-pull.sh pull <model>` を実行 | モデルが PVC (`local-path`) へダウンロードされ推論が可能なこと | `./ollama-pull.sh pull qwen2.5-coder:0.5b` |

### 4.2 Keycloak & 認証・運用 DB

| テスト ID | 検証項目 | 前提条件 | 操作手順 | 期待結果 | 検証コマンド |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TC-KC-01** | Keycloak OIDC Discovery | Keycloak 稼働中 | OpenID Configuration エンドポイントへアクセス | HTTP 200 および OIDC メタデータ JSON が返却されること | `curl -sk https://keycloak.philippines.com.ph/realms/master/.well-known/openid-configuration \| jq .issuer` |
| **TC-KC-02** | PostgreSQL 稼働確認 | PostgreSQL 稼働中 | PostgreSQL 待受ポート 5432 へ疎通 | `pg_isready` が成功すること | `kubectl exec -n keycloak deployment/pgadmin -- pg_isready -h keycloak-pg-postgresql-ha-pgpool -p 5432` |
| **TC-KC-03** | pgAdmin 4 自動ログイン | pgAdmin 稼働中 | `https://pgadmin.philippines.com.ph` へアクセス | Keycloak OIDC でシングルサインオンできること | ブラウザでアクセス |

### 4.3 監視スタック (Prometheus & Grafana)

| テスト ID | 検証項目 | 前提条件 | 操作手順 | 期待結果 | 検証コマンド |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TC-MON-01** | Ollama Exporter スクレイプ健全性 | 監視スタック稼働中 | Prometheus API から activeTargets を照会 | `ollama-exporter` ターゲットが `health: "up"` であること | `kubectl run test-targets --rm -i --image=curlimages/curl:latest --restart=Never -- curl -s http://kube-prometheus-stack-prometheus.cattle-monitoring-system:9090/api/v1/targets \| jq '[.data.activeTargets[] \| select(.labels.job == "ollama-exporter")]'` |
| **TC-MON-02** | Grafana ダッシュボード自動ロード | Grafana 稼働中 | Grafana API でプロビジョニング済みダッシュボードを検索 | **PostgreSQL Overview**, **K8S Dashboard** 等が一覧に含まれること | `curl -sk -u admin:admin "https://grafana.philippines.com.ph/api/search" \| jq -r '.[].title'` |

---

## 5. テスト実行手順

### 5.1 個別機能テスト (Unit) の実行
作業後の構文チェック、スクリプトの単体テストを安全かつ瞬時に実行します。

```bash
./test.sh
# または
./test.sh --unit
```

**合否判定基準**: `個別テスト結果: 51 PASSED, 0 FAILED` で終了コード 0 であること。

### 5.2 全体ライフサイクルテスト (E2E) の実行
クリーンな環境からクラスタを作成し、全サービス健全性、AI 疎通、停止、イメージ保存、クリーンアップを一気通貫で検証します。

```bash
# 対話プロンプト付きで実行 (start.sh / stop.sh 経由)
./test.sh --e2e

# 確認プロンプトをスキップして自動実行 (-y)
./test.sh --e2e -y

# ansible-playbook 直接実行モード (site.yml / teardown.yml 経由)
./test.sh --e2e --ansible -y
```

**合否判定基準**: 
1. 全 2 ノード (Server 8コア, Worker 24コア) が Ready
2. Ollama / Open WebUI が正常稼働
3. 停止処理が正常完了
4. `images.txt` が更新
5. Podman ストレージにイメージがキャッシュ保存
6. K3D クラスタが残存せず完全に削除されること
