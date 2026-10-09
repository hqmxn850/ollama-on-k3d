# AGENTS (Ollama on K3D)

## 必須指示
- 回答・応答は必ず日本語で行う。
- **リテラルの変数化の徹底（ハードコード禁止）**:
  - ドメイン名、公開・内部 URL、名前空間（Namespace）、ポート番号、タイムアウト値、リトライ回数、CPU 割当コア数などのリテラル文字列をコード（Playbook、Role、Shell Script、Template、Manifest）内に直接ハードコードしてはならない。
  - 全て `config.env` および `ansible/group_vars/all.yml` を Single Source of Truth (信頼できる唯一の情報源) として一元管理・変数化し、テンプレート内では `{{ 変数名 | default(...) }}` 形式で参照すること。
- **ワークロード配置ルールの厳守**:
  - **Server ノード (8 コア: 0-7)**: CORE 機能 (Traefik, Rancher, cert-manager)、モニタリング機能 (Prometheus, Grafana)、SSO 機能 (Keycloak, pgAdmin, PostgreSQL) を配置。(`nodeSelector: node-role.kubernetes.io/control-plane: "true"`)
  - **Worker ノード (24 コア: 8-31)**: AI / LLM 機能 (Lemonade, FastFlowLM, Open WebUI, AMD GPU/NPU device plugin) を集中配置。(`nodeSelector: node-role.kubernetes.io/worker: "true"`)
- **ストレージクラス**: K3s 標準の `local-path` を全面使用。

---

## リポジトリアップデート手順

このリポジトリは、ローカル AI / LLM ワークロードに特化した K3D クラスタを Podman 環境に自動的にデプロイするためのスクリプトと設定ファイル群です。

### 動作環境
- **コンテナランタイム**: Podman (system モード、sudo で実行)
- **クラスタ管理**: K3D (v5.8.0+)
- **OS**: cgroup v2 対応 Linux
- **ハードウェア**: AMD ROCm 対応 GPU (`/dev/kfd`, `/dev/dri`)、AMD XDNA 対応 NPU (`/dev/accel`)

### デプロイ手順

1. `config.env` ファイルを編集して、クラスタ設定をカスタマイズ
2. `./start.sh` を実行してクラスタデプロイメントを開始
3. インストール完了後、`~/.kube/config` にクライアント設定が自動的にコピーされます

### クラスタ停止

```bash
./stop.sh
```

---

## ディレクトリ構成

```text
├── lib/                     # 共通シェル関数ライブラリ (log/warn/err/ensure_command)
├── start.sh                 # クラスタ起動スクリプト (Ansible ラッパー版 / config.env 自動連携)
├── stop.sh                  # クラスタ停止スクリプト (Ansible ラッパー版 / config.env 自動連携)
├── trust-ca.sh              # K3D ルート CA 証明書のホスト OS 自動信頼登録 / 削除スクリプト
├── upgrade.sh               # 最新版検索 & 自動アップグレードスクリプト (K8s, Helm, イメージ)
├── import-images.sh         # Podman ローカルキャッシュからクラスタ全ノード containerd への一括事前インポートスクリプト
├── lemonade-pull.sh         # Kubernetes 上の Lemonade モデル pull スクリプト
├── pull-model.sh            # Lemonade モデル pull スクリプト (lemonade-pull.sh へのリンク)
├── config.env               # クラスタ設定変数ファイル (Single Source of Truth)
├── versions.env             # バージョン情報ファイル (K3s/Helm/イメージ最新保証)
├── config.yaml              # K3D 設定ファイル (start.sh 実行時に自動生成)
├── images.txt               # クラスタ用コンテナイメージ一覧 (自動更新・事前キャッシュ対象)
├── secrets.txt              # デプロイ後に自動生成される各サービス認証情報ファイル
├── test.sh                  # 総合テストランナー (個別機能・全体E2E)
├── tests/                   # テストスイート
│   ├── test-unit.sh         # 単体・構文テスト
│   └── test-e2e.sh          # E2E ライフサイクルテスト
├── manifests/               # 自動生成マニフェスト配置先・i18n リソース
│   └── rancher-i18n/        # Rancher UI 完全日本語化リソース (ja.yaml, パッチスクリプト群)
├── ansible/                 # Ansible による宣言的デプロイメント基盤
│   ├── ansible.cfg          # Ansible 設定
│   ├── inventory.ini        # インベントリ設定 (localhost)
│   ├── requirements.yml     # 依存コレクション
│   ├── README.md            # Ansible デプロイ概要
│   ├── group_vars/          # クラスタ設定変数 (all.yml)
│   ├── playbooks/           # site.yml, cluster.yml, storage_auth.yml, apps.yml, oidc.yml, teardown.yml
│   ├── shared/              # 共通タスク (helm_repo.yml: Helm リポジトリ冪等登録)
│   └── roles/               # 各機能 Role (host_setup, k3d_cluster, keycloak, rancher, monitoring, oidc_integration, amd_gpu, lemonade, open_webui, cluster_teardown)
├── AGENTS.md                # 運用・開発エージェント向け指示書
├── README.md                # プロジェクト概要・利用手順
├── NETWORK.md               # ネットワーク構成仕様書
├── goal.md                  # プロジェクト目標・アーキテクチャ概要
├── TEST.md                  # テスト仕様書
└── spec.md                  # 詳細仕様書
```

---

## 主要設定変数 (`config.env`)

| 変数名 | 説明 | デフォルト値 |
| :--- | :--- | :--- |
| `CLUSTER_NAME` | クラスタ名 | `ollama-cluster` |
| `SERVERS` | サーバーノード数 (CORE/SSO/監視用) | `1` |
| `AGENTS` | エージェントノード数 (AI/LLM/推論用) | `1` |
| `SERVER_CPUS` | サーバーノード割当 CPU コア数 | `8` |
| `AGENT_CPUS` | エージェントノード割当 CPU コア数 | `24` |
| `SERVER_CPUSET` | サーバーノード CPU コア範囲 | `0-7` |
| `AGENT_CPUSET` | エージェントノード CPU コア範囲 | `8-31` |
| `NETWORK` | Podman ネットワーク名 | `k3d` |
| `ENABLE_NETWORK_POLICY` | NetworkPolicy によるプライベートネットワーク隔離 | `true` |
| `DISABLE_TRAEFIK` | Traefik を無効化 | `false` |
| `KUBELET_USER_NAMESPACE` | Kubelet UserNamespace 対応 | `true` |
| `PRE_IMPORT_IMAGES` | ホストから全ノード containerd へのイメージ一括事前インポート | `true` |
| `K3D_GPUS` | k3d ノードへの GPU パススルー | `all` |
| `EMAIL_DOMAIN` | メールドメイン | `philippines.com.ph` |
| `ADMIN_GROUP_NAME` | 管理者グループ名 (Keycloak / Grafana / Open WebUI) | `rancher-admins` |
| `LEMONADE_ENABLED` | Lemonade Server (GPU LLM / Ollama 互換 API) のデプロイ有効化 | `true` |
| `LEMONADE_NAMESPACE` | Lemonade の名前空間 | `lemonade` |
| `LEMONADE_HOSTNAME` | Lemonade API ホスト名 | `lemonade.${EMAIL_DOMAIN}` |
| `LEMONADE_PORT` | Lemonade API 待受ポート (Ollama 互換) | `11434` |
| `LEMONADE_SERVICE_NAME` | クラスタ内 Service 名 (Service FQDN = Service 名.名前空間.svc.cluster.local) | `lemonade` |
| `LEMONADE_INGRESS_ENABLED` | Lemonade Ingress 作成の有効化 | `true` |
| `LEMONADE_INGRESS_AUTH_ENABLED` | 公開 Ingress への SSO forwardAuth (Keycloak OIDC / oauth2-proxy) 適用。クラスタ内呼び出しは無影響 | `true` |
| `LEMONADE_IMAGE_PULL_POLICY` | Lemonade コンテナイメージ pull ポリシー | `IfNotPresent` |
| `LEMONADE_IMAGE` | Lemonade コンテナイメージ (versions.env で管理) | `ghcr.io/lemonade-sdk/lemonade-server:v2026.40.0` |
| `LEMONADE_REPLICAS` | Lemonade Replica 数 (**単一レプリカ専用**: GPU 1 枚割当のため拡張不可) | `1` |
| `LEMONADE_BACKEND` | 推論バックエンド (llama.cpp) | `rocm` |
| `LEMONADE_GPU_ENABLED` | AMD GPU パススルー有効化 | `true` |
| `LEMONADE_GPU_NUMBER` | 割り当て GPU デバイス数 | `1` |
| `LEMONADE_STORAGE_SIZE` | モデル保存用 PVC 容量 | `30Gi` |
| `LEMONADE_STORAGE_CLASS` | モデル保存用 StorageClass | `local-path` |
| `LEMONADE_CPU_REQUEST` | CPU リクエスト | `500m` |
| `LEMONADE_MEMORY_REQUEST` | メモリリクエスト | `2Gi` |
| `LEMONADE_MEMORY_LIMIT` | メモリリミット | `48Gi` |
| `LEMONADE_LIVENESS_FAILURE_THRESHOLD` | liveness プローブ連続失敗閾値 (モデルロード中の誤検知防止) | `40` |
| `LEMONADE_PROBE_PATH` | 死活監視パス | `/live` |
| `LEMONADE_CTX_SIZE` | モデル推論コンテキスト長 (auto-tune 無効化・KV メモリ固定) | `32768` |
| `LEMONADE_DEFAULT_MODEL` | 標準 LLM モデル (start.sh が自動登録し Open WebUI 標準モデルに設定) | `Gemma-4-E4B-it-GGUF` |
| `LEMONADE_DEFAULT_MODEL_AUTO_SETUP` | 標準 LLM モデルの自動登録・設定の有効化 | `true` |
| `LEMONADE_DEFAULT_MODEL_SETUP_RETRIES` | 標準 LLM モデル登録前の Lemonade 接続リトライ回数 | `30` |
| `LEMONADE_DEFAULT_MODEL_SETUP_RETRY_INTERVAL` | 標準 LLM モデル登録前のリトライ間隔 (秒) | `2` |
| `LEMONADE_PULL_RETRIES` | モデル pull の最大リトライ回数 (部分再開) | `10` |
| `LEMONADE_PULL_RETRY_INTERVAL` | モデル pull のリトライ間隔 (秒) | `10` |
| `LEGACY_CLEANUP_ENABLED` | 旧 Ollama / OGA 名前空間の自動削除 (GPU 概奪防止) | `true` |
| `LEGACY_AI_NAMESPACES` | 旧リソース削除対象の名前空間 (カンマ区切り) | `ollama,oga` |
| `LEGACY_CLEANUP_TIMEOUT` | 旧名前空間削除の待機タイムアウト | `180s` |
| `CATTLE_CONVERGE_TIMEOUT_SECONDS` | Rancher (cattle-*) 起動待ち合わせの全体期限 (秒・rancher 収束時の同期ポイント) | `600` |
| `OPEN_WEBUI_ENABLED` | Open WebUI のデプロイ有効化 | `true` |
| `OPEN_WEBUI_NAMESPACE` | Open WebUI の名前空間 | `open-webui` |
| `OPEN_WEBUI_HOSTNAME` | Open WebUI ホスト名 | `chat.${EMAIL_DOMAIN}` |
| `OPEN_WEBUI_PORT` | Open WebUI 待受ポート | `8080` |
| `OPEN_WEBUI_STORAGE_CLASS` | Open WebUI データ用 StorageClass | `local-path` |
| `OPEN_WEBUI_DEFAULT_LOCALE` | Open WebUI デフォルト言語ロケール | `ja-JP` |
| `OPEN_WEBUI_DEFAULT_SYSTEM_PROMPT` | Open WebUI デフォルトシステムプロンプト | `あなたは親切で極めて有能なAIアシスタントです。…` |
| `OPEN_WEBUI_WEB_SEARCH_ENABLED` | Open WebUI インターネット Web 検索 (RAG) 有効化 | `true` |
| `OPEN_WEBUI_WEB_SEARCH_ENGINE` | Open WebUI Web 検索エンジン (duckduckgo / searxng 等) | `duckduckgo` |
| `OPEN_WEBUI_WEB_SEARCH_RESULT_COUNT` | Open WebUI Web 検索取得結果件数 | `3` |
| `OPEN_WEBUI_WEB_SEARCH_CONCURRENT_REQUESTS` | Open WebUI Web 検索並列リクエスト数 | `10` |
| `OPEN_WEBUI_WEB_SEARCH_BYPASS_WEB_LOADER` | Web 全文スクレイピングをバイパスし検索スニペット直接注入 (高速・耐障害性) | `true` |
| `OPEN_WEBUI_WEB_SEARCH_BYPASS_EMBEDDING_AND_RETRIEVAL` | Web 検索時のベクトル Embedding 計算をバイパス | `true` |
| `OPEN_WEBUI_CORS_ALLOW_ORIGIN` | Open WebUI CORS 許可オリジン | `https://${OPEN_WEBUI_HOSTNAME}` |
| `OPEN_WEBUI_DB_TYPE` | Open WebUI データベース種別 (postgres / sqlite) | `postgres` |
| `OPEN_WEBUI_PG_DATABASE` | Open WebUI 用 PostgreSQL データベース名 | `openwebui` |
| `OPEN_WEBUI_PG_USER` | Open WebUI 用 PostgreSQL ユーザー名 | `openwebui` |
| `OPEN_WEBUI_PG_PASSWORD` | Open WebUI 用 PostgreSQL パスワード | `openwebui-db-2026` |
| `AMD_GPU_PLUGIN_ENABLED` | AMD GPU Device Plugin 有効化 | `true` |
| `AMD_GPU_RESOURCE_DOMAIN` | AMD GPU リソースドメイン (extended resource) | `amd.com` |
| `AMD_GPU_DEVICE_NAME` | AMD GPU デバイス名 (extended resource 名) | `gpu` |
| `AMD_NPU_PLUGIN_ENABLED` | AMD NPU Device Plugin 有効化 | `true` |
| `AMD_NPU_EXPORTER_ENABLED` | AMD NPU Prometheus Exporter 有効化 | `true` |
| `AMD_NPU_EXPORTER_PORT` | AMD NPU Prometheus Exporter 待受ポート | `9105` |
| `AMD_NPU_POWER_MODE` | AMD NPU 動作パワーモード (0=DEFAULT, 1=LOW, 2=MED, 3=HIGH, 4=TURBO) | `TURBO` |
| `NPU_FLM_ENABLED` | AMD XDNA NPU (FastFlowLM) 推論エンジンの有効化 | `true` |
| `NPU_FLM_PORT` | FastFlowLM API 待受ポート | `52625` |
| `NPU_FLM_DEFAULT_MODEL` | FastFlowLM 標準 NPU モデル | `gemma4-it:12b` |
| `NPU_FLM_HOST_IP` | FastFlowLM ホスト IP (Podman Gateway) | `10.89.0.1` |
| `NPU_FLM_BIND_HOST` | FastFlowLM バインドホスト | `0.0.0.0` |
| `NPU_FLM_PROBE_HOST` | FastFlowLM 内部死活監視ホスト | `127.0.0.1` |
| `NPU_FLM_PROBE_PATH` | FastFlowLM 死活監視エンドポイント | `/v1/models` |
| `NPU_FLM_STARTUP_RETRIES` | FastFlowLM 起動待機リトライ回数 | `15` |
| `NPU_FLM_STARTUP_RETRY_INTERVAL` | FastFlowLM 起動待機リトライ間隔 (秒) | `1` |
| `NPU_FLM_KERNEL_DIR` | FastFlowLM NPU カーネル配置ディレクトリ | `/opt/fastflowlm/lib` |

---


## 開発・運用ガイドライン

1. **CPU 制限の適用メカニズム**:
   - `k3d` 自体にはコンテナレベルの `--cpus` 引数がないため、`ansible/roles/k3d_cluster/tasks/main.yml` において、ノードコンテナ作成直後に `podman update --cpus {{ server_cpus }} --cpuset-cpus {{ server_cpuset }} k3d-<cluster>-server-0` および `podman update --cpus {{ agent_cpus }} --cpuset-cpus {{ agent_cpuset }} k3d-<cluster>-agent-0` を実行する (値は `config.env` の `SERVER_CPUS` / `SERVER_CPUSET` / `AGENT_CPUS` / `AGENT_CPUSET`)。
2. **ノードラベリングと nodeSelector**:
   - Server ノードには `tier=core, role=control-plane, node-role.kubernetes.io/control-plane=true` を付与。
   - Worker ノードには `tier=ai, role=worker, node-role.kubernetes.io/worker=true` を付与。
   - 各 Helm values / Deployment において `nodeSelector` を設定し、意図せぬノード間混在を防止する。
3. **モデル管理**:
   - `./lemonade-pull.sh pull <モデル名>` により、稼働中の Lemonade Pod 内へ直接モデルをダウンロード・永続化可能 (`--list` で一覧、`rm` で削除)。
   - `start.sh` はデプロイ末尾 (セクション 11) で `LEMONADE_DEFAULT_MODEL` が Lemonade に未登録の場合に自動 pull し、登録後のモデル名で Open WebUI の標準モデル (`ui.default_models` / `ui.default_pinned_models`) を DB に設定する (管理者 API が使えないため直接更新)。`LEMONADE_DEFAULT_MODEL_AUTO_SETUP=false` で無効化可能。`ui.default_pinned_models` には NPU 標準モデル (`NPU_FLM_DEFAULT_MODEL`) も併せて固定表示される。
4. **UI 日本語化**:
   - Open WebUI は `DEFAULT_LOCALE` / `DEFAULT_INTERFACE_SETTINGS` 環境変数、`loader.js` によるフロントエンドロケール自動設定、および DB 内の `ui.default_locale` / `ui.default_interface_settings` / 既存ユーザー設定同期により、新規アクセス時および全ユーザーにおいて `OPEN_WEBUI_DEFAULT_LOCALE` (デフォルト: `ja-JP`) で統一される。
5. **AMD XDNA NPU (FastFlowLM) 連携 & Turbo モード**:
   - AMD XDNA NPU (Strix Halo / Ryzen AI) を用いた高速推論はホスト上の `fastflowlm` (`flm serve`) により提供され、Open WebUI が `OPENAI_API_BASE_URLS` によりホスト上の FastFlowLM (`http://${NPU_FLM_HOST_IP}:${NPU_FLM_PORT}/v1`) を OpenAI 互換バックエンドとして直接参照する。
   - `start.sh` 実行時に `AMD_NPU_POWER_MODE` (デフォルト: `TURBO` / `4`) に基づき `lib/npu-power-mode.py` により NPU デバイスのクロックおよびパワープロファイルが自動設定され、最大周波数 (例: MP-NPU 1267MHz, H-Clock 1800MHz) で動作する。
   - `flm` カーネルバイナリ確認、`NPU_FLM_DEFAULT_MODEL` (例: `gemma4-it:12b`) の pull、`flm serve` API サーバーの自動バックグラウンド起動が行われ、`stop.sh` 実行時に安全に終了される。
   - Open WebUI からは FastFlowLM (`http://${NPU_FLM_HOST_IP}:${NPU_FLM_PORT}/v1`) としてモデル一覧に表示され、選択するだけで 100+ tokens/sec の NPU ハードウェア推論が実行される。推論実行時は Prometheus の `amd_npu_command_submissions_total`, `amd_npu_power_mode` に即座に反映される。
6. **Web 検索機能とツール (Tool Calling)**:
   - Open WebUI には DuckDuckGo を用いたインターネット Web 検索機能が統合されており、2 つの方法でリアルタイム検索・回答が可能：
     1. **RAG 検索 (地球儀アイコン 🌐)**: チャット入力欄の地球儀アイコンをクリックして ON にすると、最新の検索結果をコンテキストとして自動取得しプロンプトに注入する。
     2. **自律型 Tool Calling (Web Search ツール)**: Workspace > Tools に登録された `web_search` ツール (DuckDuckGo 検索) をチャット入力欄の「＋」アイコンから選択することで、LLM が Function Calling により自律的にキーワード検索を発行・要約回答できる。`start.sh` および Ansible ロール (`open_webui`) により自動的に DB 登録・更新される。
7. **Lemonade の Helm デプロイ & Generation Throughput**:
   - Lemonade はローカル Helm チャート (`ansible/roles/lemonade/chart`) を用いて `helm upgrade --install` でデプロイされる。values は `templates/values-lemonade.yaml.j2` が `config.env` / `group_vars/all.yml` (SSOT) から jinja レンダリングして供給し、既存の kubectl 管理リソースは adoption タスク (`meta.helm.sh/release-name` 等の付与) で Helm release へ引き継がれる。
   - 生成スループット (tokens/sec) は `rate(lemonade_output_tokens_total[1m])` (生成) / `rate(lemonade_prompt_tokens_total[1m])` (prefill) で取得する。非ストリーミングの `/api/generate` はメトリクス未計上のため、ストリーミング API 経由の利用時のみ加算される。
   - Grafana ダッシュボード `AI / LLM Inference (Lemonade & FastFlowLM)` (`grafana-dashboard-ai` ConfigMap) に Throughput / ROCm (amdgpu 温度・SCLK) / Hybrid 判定パネルを備える (FastFlowLM は `/metrics` 非提供のため案内テキストパネルで明示)。
   - ハイブリッド実行 (NPU prefill + GPU decode) は AMD OGA の **Windows のみ対応**機能のため、本 Linux 環境の Lemonade は llama.cpp (ROCm) の **GPU 単体**で動作する (NPU は FastFlowLM が単体利用)。
8. **クラスタ内 Service FQDN と旧リソース掃除**:
   - Lemonade のクラスタ内 FQDN は「**Service 名** (`LEMONADE_SERVICE_NAME`) **. 名前空間** (`LEMONADE_NAMESPACE`) `.svc.cluster.local`」。Service 名と名前空間は別物のため、テンプレート・スクリプトでは必ず両方の変数を併用して組み立てる (名前空間変数の二重使用は禁止)。
   - `start.sh` / Ansible デプロイ時は、移行前の旧 `ollama` / `oga` 名前空間が残存していれば自動削除する (`LEGACY_CLEANUP_ENABLED` / `LEGACY_AI_NAMESPACES` / `LEGACY_CLEANUP_TIMEOUT`)。旧 Pod が GPU を保持したままでは Lemonade Pod が Pending のまま起動できないため、無効化する場合は GPU 競合に注意すること。
   - デプロイの冪等判定は「レンダリング済み期待マニフェストとデプロイ済みマニフェストの正規化比較」で行う。`helm upgrade` は入力が同一でも必ず新しいリビジョンを生成するため、リビジョン番号や出力文言では変更を判定できない。
9. **Rancher (cattle-*) 起動待ち合わせ**:
   - `rancher` ロール収束フェーズ (`converge.yml`) の最後に、`cattle_ns_prefix` (既定 `cattle-`) に前方一致する全名前空間の Active 化、各 Deployment / DaemonSet / StatefulSet のロールアウト完了、さらに**全 Pod の完全起動 (Ready)** までをブロッキング待機する同期ポイントを設ける。
   - Pod 待ちは非終端 Pod (全レプリカ Ready・`0/0` 非許容) を対象とし、終端済み Pod (`Completed` / `Error` / `Failed`) および `Terminating` 中は除外する (Rancher の helm 操作一時 Pod は終了状態のまま残存するため)。
   - これにより Stage 2-2 (監視収束) や Phase 4 (OIDC 統合) が Rancher 系コンポーネントの起動中に走ることを防ぐ。全体期限は `CATTLE_CONVERGE_TIMEOUT_SECONDS` (既定 `600` 秒)、ポーリング間隔は `QUICK_RETRY_DELAY`。
   - 期限内に収束しなかった場合は対象リソースと Pod 一覧を出力してフェイルファストする (監視ロールの `kubectl rollout status --timeout` と同じ方針)。タスクは `changed_when: false` で再実行時も `ok` のまま冪等に動作する。

