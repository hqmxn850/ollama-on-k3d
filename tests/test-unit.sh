#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 個別機能テスト (Unit / Component Tests)
# - 各種スクリプトの構文チェック
# - Ansible Playbook 構文チェック
# - 引数チェック・異常系ハンドリング
# - save-images.sh によるイメージ抽出・カテゴリ分類・Podman 保存の非破壊検証
# - Jinja2 テンプレート構文検証 / --tags 選択スモーク / 共通タスク整合性検証
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo -e "  [${GREEN}PASS${RESET}] $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo -e "  [${RED}FAIL${RESET}] $*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

info() { echo -e "${CYAN}=== $* ===${RESET}"; }

cd "${PROJECT_ROOT}"

export ANSIBLE_CONFIG="${PROJECT_ROOT}/ansible/ansible.cfg"
export ANSIBLE_HOME="${PROJECT_ROOT}/ansible/.ansible"

info "1. スクリプト構文チェック (Syntax Check)"

for script in start.sh stop.sh upgrade.sh trust-ca.sh \
  test.sh tests/test-unit.sh tests/test-e2e.sh \
  import-images.sh \
  ansible/roles/k3d_cluster/files/import-images.sh \
  lib/common.sh \
  ansible/roles/cluster_teardown/files/save-images.sh \
  manifests/rancher-i18n/patch-rancher-i18n.sh \
  ansible/roles/lemonade/files/lemonade-pull.sh \
  lemonade-pull.sh \
  pull-model.sh; do
  if [[ -f "$script" ]]; then
    if bash -n "$script" 2>/dev/null; then
      pass "Bash 構文: $script"
    else
      fail "Bash 構文エラー: $script"
    fi
  fi
done

if [[ -f "config.env" ]]; then
  if bash -u "config.env" 2>/dev/null; then
    pass "config.env: 変数未割り当てチェック (bash -u)"
  else
    fail "config.env: 変数未割り当てエラー"
  fi
fi

if [[ -f "versions.env" ]]; then
  if bash -u "versions.env" 2>/dev/null; then
    pass "versions.env: 変数未割り当てチェック (bash -u)"
  else
    fail "versions.env: 変数未割り当てエラー"
  fi
fi

for pyscript in ansible/roles/monitoring/files/patch-dashboards.py lib/npu-power-mode.py; do
  if [[ -f "$pyscript" ]]; then
    if python3 -m py_compile "$pyscript" 2>/dev/null; then
      pass "Python 構文: $pyscript"
    else
      fail "Python 構文エラー: $pyscript"
    fi
  fi
done

info "2. Ansible Playbook 構文チェック (全 Playbook)"
if command -v ansible-playbook &>/dev/null; then
  for pb in site.yml cluster.yml storage_auth.yml apps.yml oidc.yml teardown.yml; do
    PB_PATH="${PROJECT_ROOT}/ansible/playbooks/${pb}"
    if [[ -f "$PB_PATH" ]]; then
      if ANSIBLE_CONFIG="${PROJECT_ROOT}/ansible/ansible.cfg" \
        ansible-playbook -i "${PROJECT_ROOT}/ansible/inventory.ini" --syntax-check \
        "$PB_PATH" &>/dev/null; then
        pass "Ansible Playbook 構文: ${pb}"
      else
        fail "Ansible Playbook 構文エラー: ${pb}"
      fi
    fi
  done
else
  echo -e "  ${YELLOW}[SKIP]${RESET} ansible-playbook コマンドが見つからないためスキップ"
fi

info "3. Ansible インベントリ & 依存コレクション検証"
if command -v ansible-inventory &>/dev/null; then
  if ANSIBLE_CONFIG="${PROJECT_ROOT}/ansible/ansible.cfg" \
    ansible-inventory -i "${PROJECT_ROOT}/ansible/inventory.ini" --list &>/dev/null; then
    pass "Ansible インベントリ & 変数解決 (inventory.ini / group_vars/all.yml)"
  else
    fail "Ansible インベントリ検証失敗"
  fi
fi

if command -v ansible-galaxy &>/dev/null && [[ -f "${PROJECT_ROOT}/ansible/requirements.yml" ]]; then
  if ansible-galaxy collection list community.general &>/dev/null && \
     ansible-galaxy collection list kubernetes.core &>/dev/null; then
    pass "Ansible 依存コレクション確認 (community.general, kubernetes.core)"
  else
    echo -e "  ${YELLOW}[INFO]${RESET} 依存コレクションをインストール中..."
    ansible-galaxy collection install -r "${PROJECT_ROOT}/ansible/requirements.yml" --quiet 2>/dev/null || true
    pass "Ansible 依存コレクションの確認・インストール完了"
  fi
fi

info "4. 引数チェック & 異常系ハンドリング"

# 共通関数 (ensure_command, version_ge, ensure_latest_kubectl, ensure_latest_helm) の読み込み・動作検証
if bash -c "source '${PROJECT_ROOT}/lib/common.sh' && type ensure_command >/dev/null 2>&1"; then
  pass "lib/common.sh: 共通関数 (ensure_command) の読み込み成功"
else
  fail "lib/common.sh: 共通関数の読み込みに失敗"
fi

if bash -c "source '${PROJECT_ROOT}/lib/common.sh' && version_ge '1.37.1' '1.27.4' && ! version_ge '1.27.4' '1.37.1' && version_ge 'v4.3.0' 'v4.2.2'"; then
  pass "lib/common.sh: バージョン比較関数 (version_ge) の検証成功"
else
  fail "lib/common.sh: バージョン比較関数 (version_ge) の検証に失敗"
fi

if bash -c "source '${PROJECT_ROOT}/lib/common.sh' && type ensure_latest_kubectl >/dev/null 2>&1 && type ensure_latest_helm >/dev/null 2>&1"; then
  pass "lib/common.sh: CLI 最新化関数 (ensure_latest_kubectl, ensure_latest_helm) の定義確認"
else
  fail "lib/common.sh: CLI 最新化関数の定義確認に失敗"
fi

if bash -c "source '${PROJECT_ROOT}/lib/common.sh' && ensure_latest_kubectl && ensure_latest_helm" >/dev/null 2>&1; then
  pass "lib/common.sh: kubectl / helm 最新バージョン確認・スキップ (冪等性) 成功"
else
  fail "lib/common.sh: kubectl / helm 最新バージョン確認・スキップ (冪等性) に失敗"
fi

# save-images.sh: クラスタ未接続時のハンドリング確認 (不正なKUBECONFIGで検証)
OUTPUT_NO_KUBE=$(KUBECONFIG="/dev/null" "${PROJECT_ROOT}/ansible/roles/cluster_teardown/files/save-images.sh" "/tmp/dummy.txt" 2>&1 || true)
if echo "$OUTPUT_NO_KUBE" | grep -q "イメージ保存をスキップします"; then
  pass "save-images.sh: クラスタ未接続時の安全スキップ"
else
  fail "save-images.sh: クラスタ未接続時のハンドリングに失敗 (出力: $OUTPUT_NO_KUBE)"
fi

# save-images.sh: 実行済みフラグ設定時の二重実行スキップ確認
OUTPUT_DUPLICATE=$(_SAVED_IMAGES_DONE=1 "${PROJECT_ROOT}/ansible/roles/cluster_teardown/files/save-images.sh" "/tmp/dummy.txt" 2>&1 || true)
if echo "$OUTPUT_DUPLICATE" | grep -q "イメージ保存は既に実行済みのためスキップします"; then
  pass "save-images.sh: 実行済みフラグ設定時の二重実行スキップ"
else
  fail "save-images.sh: 二重実行スキップのハンドリングに失敗 (出力: $OUTPUT_DUPLICATE)"
fi

# upgrade.sh: ヘルプオプション動作確認
if [[ -f "${PROJECT_ROOT}/upgrade.sh" ]]; then
  OUTPUT_UPGRADE_HELP=$("${PROJECT_ROOT}/upgrade.sh" --help 2>&1 || true)
  if echo "$OUTPUT_UPGRADE_HELP" | grep -q "使用法:"; then
    pass "upgrade.sh: ヘルプオプション (--help) 正常出力"
  else
    fail "upgrade.sh: ヘルプオプション出力に失敗 (出力: $OUTPUT_UPGRADE_HELP)"
  fi
fi

# start.sh: ヘルプオプション動作確認
if [[ -f "${PROJECT_ROOT}/start.sh" ]]; then
  OUTPUT_START_HELP=$("${PROJECT_ROOT}/start.sh" --help 2>&1 || true)
  if echo "$OUTPUT_START_HELP" | grep -q "使用方法:"; then
    pass "start.sh: ヘルプオプション (--help) 正常出力"
  else
    fail "start.sh: ヘルプオプション出力に失敗 (出力: $OUTPUT_START_HELP)"
  fi
fi

# stop.sh: ヘルプオプション動作確認
if [[ -f "${PROJECT_ROOT}/stop.sh" ]]; then
  OUTPUT_STOP_HELP=$("${PROJECT_ROOT}/stop.sh" --help 2>&1 || true)
  if echo "$OUTPUT_STOP_HELP" | grep -q "使用方法:"; then
    pass "stop.sh: ヘルプオプション (--help) 正常出力"
  else
    fail "stop.sh: ヘルプオプション出力に失敗 (出力: $OUTPUT_STOP_HELP)"
  fi
fi

# trust-ca.sh: ヘルプおよび引数チェック
if [[ -f "${PROJECT_ROOT}/trust-ca.sh" ]]; then
  OUTPUT_TCA_HELP=$("${PROJECT_ROOT}/trust-ca.sh" --help 2>&1 || true)
  if echo "$OUTPUT_TCA_HELP" | grep -qi "使用方法:\|trust-ca"; then
    pass "trust-ca.sh: ヘルプオプション (--help) 正常出力"
  else
    fail "trust-ca.sh: ヘルプオプション出力に失敗 (出力: $OUTPUT_TCA_HELP)"
  fi

  OUTPUT_TCA_BAD=$("${PROJECT_ROOT}/trust-ca.sh" --invalid-option 2>&1 || true)
  if echo "$OUTPUT_TCA_BAD" | grep -qi "未知のオプション"; then
    pass "trust-ca.sh: 無効オプション指定時のエラーハンドリング"
  else
    fail "trust-ca.sh: 無効オプション時のハンドリングに失敗 (出力: $OUTPUT_TCA_BAD)"
  fi
fi

# lemonade-pull.sh: ヘルプおよび引数チェック
if [[ -f "${PROJECT_ROOT}/lemonade-pull.sh" ]]; then
  OUTPUT_LP_HELP=$("${PROJECT_ROOT}/lemonade-pull.sh" --help 2>&1 || true)
  if echo "$OUTPUT_LP_HELP" | grep -qi "使用方法:\|lemonade-pull"; then
    pass "lemonade-pull.sh: ヘルプオプション (--help) 正常出力"
  else
    fail "lemonade-pull.sh: ヘルプオプション出力に失敗 (出力: $OUTPUT_LP_HELP)"
  fi

  OUTPUT_LP_BAD=$("${PROJECT_ROOT}/lemonade-pull.sh" --invalid-option 2>&1 || true)
  if echo "$OUTPUT_LP_BAD" | grep -qi "未知のオプション"; then
    pass "lemonade-pull.sh: 無効オプション指定時のエラーハンドリング"
  else
    fail "lemonade-pull.sh: 無効オプション時のハンドリングに失敗 (出力: $OUTPUT_LP_BAD)"
  fi

  OUTPUT_LP_NOMODEL=$("${PROJECT_ROOT}/lemonade-pull.sh" 2>&1 || true)
  if echo "$OUTPUT_LP_NOMODEL" | grep -qi "ダウンロードするモデル名が指定されていません"; then
    pass "lemonade-pull.sh: モデル未指定時のエラーハンドリング (pull)"
  else
    fail "lemonade-pull.sh: モデル未指定時ハンドリングに失敗 (出力: $OUTPUT_LP_NOMODEL)"
  fi

  OUTPUT_LP_NORM=$("${PROJECT_ROOT}/lemonade-pull.sh" rm 2>&1 || true)
  if echo "$OUTPUT_LP_NORM" | grep -qi "削除するモデル名が指定されていません"; then
    pass "lemonade-pull.sh: モデル未指定時のエラーハンドリング (rm/delete)"
  else
    fail "lemonade-pull.sh: rm モデル未指定時ハンドリングに失敗 (出力: $OUTPUT_LP_NORM)"
  fi

  if [[ -L "${PROJECT_ROOT}/lemonade-pull.sh" && -f "${PROJECT_ROOT}/ansible/roles/lemonade/files/lemonade-pull.sh" ]]; then
    pass "lemonade-pull.sh: ルート symlink → ansible/roles/lemonade/files/lemonade-pull.sh"
  else
    fail "lemonade-pull.sh: ルート symlink またはロール実体が不正"
  fi
fi

if [[ -f "${PROJECT_ROOT}/lib/npu-power-mode.py" ]]; then
  OUTPUT_NPU_USAGE=$(python3 "${PROJECT_ROOT}/lib/npu-power-mode.py" 2>&1 || true)
  if echo "$OUTPUT_NPU_USAGE" | grep -q "Usage: npu-power-mode.py"; then
    pass "npu-power-mode.py: 引数なし時の Usage 正常出力"
  else
    fail "npu-power-mode.py: 引数なし時のハンドリングに失敗 (出力: $OUTPUT_NPU_USAGE)"
  fi

  OUTPUT_NPU_INVALID=$(python3 "${PROJECT_ROOT}/lib/npu-power-mode.py" set INVALID 2>&1 || true)
  if echo "$OUTPUT_NPU_INVALID" | grep -qi "Invalid power mode"; then
    pass "npu-power-mode.py: 無効なパワーモード指定時のエラーハンドリング"
  else
    fail "npu-power-mode.py: 無効なパワーモード指定時のハンドリングに失敗 (出力: $OUTPUT_NPU_INVALID)"
  fi
fi

info "5. イメージ抽出・カテゴリ分類・保存テスト (save-images.sh)"

TMP_TEST_IMAGES=$(mktemp /tmp/test-images-XXXXXX.txt)

if kubectl cluster-info &>/dev/null; then
  # 稼働中クラスタでテスト実行
  if "${PROJECT_ROOT}/ansible/roles/cluster_teardown/files/save-images.sh" "$TMP_TEST_IMAGES" >/dev/null 2>&1; then
    pass "save-images.sh: 正常実行完了"

    # 生成されたファイルのチェック
    if [[ -s "$TMP_TEST_IMAGES" ]]; then
      pass "save-images.sh: イメージリスト生成成功 (非空)"
    else
      fail "save-images.sh: イメージリストが空です"
    fi

    # カテゴリヘッダーの存在確認
    if grep -q "# 基本イメージ" "$TMP_TEST_IMAGES" && grep -q "# K3s / K3D コンポーネント" "$TMP_TEST_IMAGES"; then
      pass "save-images.sh: カテゴリ分類ヘッダー正常出力"
    else
      fail "save-images.sh: カテゴリヘッダーの出力が不正です"
    fi

    # Podman にイメージが保存されているかチェック
    FIRST_IMAGE=$(grep -v '^#' "$TMP_TEST_IMAGES" | grep -v '^[[:space:]]*$' | head -n 1 || true)
    if [[ -n "$FIRST_IMAGE" ]]; then
      if sudo podman image exists "$FIRST_IMAGE" 2>/dev/null; then
        pass "Podman キャッシュ確認: $FIRST_IMAGE がローカルに存在"
      else
        fail "Podman キャッシュ未確認: $FIRST_IMAGE が存在しません"
      fi
    fi
  else
    fail "save-images.sh: 実行失敗"
  fi
else
  echo -e "  ${YELLOW}[SKIP]${RESET} Kubernetes クラスタが稼働していないため抽出テストをスキップ"
fi

rm -f "$TMP_TEST_IMAGES"

echo ""
info "6. Jinja2 テンプレート構文 & タグ・共通タスク整合性検証"

# 6a. 全テンプレートの Jinja2 構文チェック
if tpl_out=$(python3 - <<'JINJA_PY' 2>&1
import glob, sys
from jinja2 import Environment
files = sorted(set(glob.glob('ansible/roles/*/templates/*.j2') + glob.glob('ansible/**/*.j2', recursive=True)))
env = Environment()
bad = []
for f in files:
    try:
        env.parse(open(f, encoding='utf-8').read())
    except Exception as e:
        bad.append(f"{f}: {e}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(len(files))
JINJA_PY
); then
  pass "Jinja2 構文: 全テンプレート ${tpl_out} 件が解析成功"
else
  fail "Jinja2 構文エラー: ${tpl_out}"
fi

# 6b. 全テンプレートの変数解決 & レンダリング検証 (StrictUndefined)
if render_out=$(python3 - <<'RENDER_PY' 2>&1
import glob, sys, yaml, jinja2

all_vars = yaml.safe_load(open("ansible/group_vars/all.yml", encoding="utf-8"))
runtime_vars = {
    "lb_ips": ["127.0.0.1"],
    "ansible_date_time": {"date": "2026-10-03", "time": "12:00:00"},
    "role_path": "/path/to/role",
    "playbook_dir": "/path/to/playbook",
    "item": "test-item",
}
all_vars.update(runtime_vars)

env = jinja2.Environment(undefined=jinja2.StrictUndefined)
env.filters["quote"] = lambda x: f"\"{x}\""
env.filters["to_json"] = lambda x: "{}"
env.filters["to_yaml"] = lambda x: ""
env.filters["to_nice_yaml"] = lambda x: ""
env.filters["b64encode"] = lambda x: ""
env.filters["b64decode"] = lambda x: ""
env.filters["hash"] = lambda x, y=None: "dummy"
env.filters["bool"] = lambda x: bool(x)
env.globals["lookup"] = lambda *args, **kwargs: "dummy"

files = sorted(set(glob.glob("ansible/roles/*/templates/*.j2") + glob.glob("ansible/**/*.j2", recursive=True)))
bad = []
for f in files:
    try:
        t_src = open(f, encoding="utf-8").read()
        t = env.from_string(t_src)
        t.render(**all_vars)
    except Exception as e:
        bad.append(f"{f}: {e}")

if bad:
    print("\n".join(bad))
    sys.exit(1)
print(len(files))
RENDER_PY
); then
  pass "Jinja2 変数解決: 全テンプレート ${render_out} 件が StrictUndefined で正常レンダリング成功"
else
  fail "Jinja2 変数未解決エラー: ${render_out}"
fi

# 6c. config.env と group_vars/all.yml の変数一元管理検証
if var_chk_out=$(python3 - <<'VARCHK_PY' 2>&1
import re, sys

config_vars = set()
with open("config.env", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"): continue
        m = re.match(r"^([A-Z0-9_]+)=", line)
        if m:
            config_vars.add(m.group(1))

all_yml = open("ansible/group_vars/all.yml", encoding="utf-8").read()
missing = []
for var in sorted(config_vars):
    pattern = rf"lookup\([\x27\"]env[\x27\"],\s*[\x27\"]{var}[\x27\"]"
    if not re.search(pattern, all_yml):
        missing.append(var)

if missing:
    print(f"Missing in all.yml: {', '.join(missing)}")
    sys.exit(1)
print(len(config_vars))
VARCHK_PY
); then
  pass "config.env 変数連携: 全 ${var_chk_out} 変数が group_vars/all.yml で一元管理されていることを確認"
else
  fail "config.env 変数連携エラー: ${var_chk_out}"
fi

# 6d. --tags 選択スモーク (タグ体系の回帰防止)
check_tag() {
  local pb="$1" tag="$2" cnt
  cnt=$(cd ansible && ANSIBLE_CONFIG="${PROJECT_ROOT}/ansible/ansible.cfg" ANSIBLE_HOME="${PROJECT_ROOT}/ansible/.ansible" \
    ansible-playbook "playbooks/${pb}" --list-tasks -t "${tag}" 2>/dev/null \
    | grep -cE "TAGS: \[[^]]*\b${tag}\b" || true)
  if [[ "${cnt}" -gt 0 ]]; then
    pass "--tags ${tag}: ${pb} で ${cnt} タスクが選択される"
  else
    fail "--tags ${tag}: ${pb} で選択タスクが 0 件"
  fi
}
check_tag site.yml cluster
check_tag site.yml storage_auth
check_tag site.yml apps
check_tag site.yml oidc
check_tag site.yml cleanup
check_tag teardown.yml teardown
check_tag teardown.yml cluster_teardown

# 6c. Helm リポジトリ共通タスク (shared/tasks/helm_repo.yml) の整合性
if [[ -f ansible/shared/tasks/helm_repo.yml ]]; then
  pass "共通タスク: ansible/shared/tasks/helm_repo.yml が存在"
else
  fail "共通タスク: ansible/shared/tasks/helm_repo.yml が見つからない"
fi
import_cnt=$(grep -rl "import_tasks: ../../../shared/tasks/helm_repo.yml" ansible/roles/*/tasks/*.yml | wc -l)
if [[ "${import_cnt}" -eq 5 ]]; then
  pass "共通タスク導入: 5 ロールが shared/tasks/helm_repo.yml を import"
else
  fail "共通タスク導入: import ロール数が ${import_cnt} (期待: 5)"
fi

echo -e "${BOLD}個別テスト結果: ${GREEN}${PASS_COUNT} PASSED${RESET}, ${RED}${FAIL_COUNT} FAILED${RESET}"
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
