#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Ollama on K3D 総合テストランナー
# 使用方法: ./test.sh [オプション]
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

show_help() {
  cat << EOF
使用方法: $(basename "$0") [オプション]

Ollama on K3D 総合テストスイート実行スクリプト

オプション:
  --unit, -u        個別機能テストを実行 (構文チェック、引数・設定値整合性の非破壊検証) [デフォルト]
  --e2e, --all      全体テスト (End-to-End) を実行 (クラスタ起動 -> 稼働検証 -> 停止・保存 -> クリーンアップ)
  --ansible         E2E テスト時に start.sh/stop.sh ラッパーではなく ansible-playbook を直接実行
  -y, --yes         E2E テスト時の確認プロンプトをスキップして自動承認
  -h, --help        このヘルプを表示

実行例:
  ./test.sh                 # 個別機能テスト (安全・非破壊)
  ./test.sh --e2e           # 全体 E2E ライフサイクルテスト (start.sh / stop.sh 経由)
  ./test.sh --e2e --ansible # 全体 E2E ライフサイクルテスト (ansible-playbook 直接実行)
EOF
}

MODE="unit"
E2E_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit|-u)
      MODE="unit"
      shift
      ;;
    --e2e|--all)
      MODE="e2e"
      shift
      ;;
    --ansible)
      E2E_ARGS+=("$1")
      shift
      ;;
    -y|--yes|--force)
      E2E_ARGS+=("$1")
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "不明なオプション: $1"
      show_help
      exit 1
      ;;
  esac
done

case "$MODE" in
  unit)
    "${TESTS_DIR}/test-unit.sh"
    ;;
  e2e)
    "${TESTS_DIR}/test-e2e.sh" ${E2E_ARGS[@]+"${E2E_ARGS[@]}"}
    ;;
esac
