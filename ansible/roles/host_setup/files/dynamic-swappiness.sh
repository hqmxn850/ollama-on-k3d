#!/usr/bin/env bash
# 動的 swappiness ガバナー
#
# /proc/loadavg (1 分) を CPU コア数で正規化した load% に応じて vm.swappiness を
# [DYNAMIC_SWAPPINESS_MIN, DYNAMIC_SWAPPINESS_MAX] の範囲で線形補間する。
#
#   load% >= DYNAMIC_SWAPPINESS_HIGH_LOAD -> DYNAMIC_SWAPPINESS_MIN (高負荷時はスワップ抑制)
#   load% <= DYNAMIC_SWAPPINESS_LOW_LOAD  -> DYNAMIC_SWAPPINESS_MAX (低負荷時はスワップ積極化)
#   その間は線形補間
#
# 設定は /etc/default/dynamic-swappiness から読む
# (SSOT: config.env / ansible/group_vars/all.yml)。
# 値が変化した場合のみ journald (タグ: dynamic-swappiness) にログを出す。
set -euo pipefail

ENV_FILE="/etc/default/dynamic-swappiness"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

: "${DYNAMIC_SWAPPINESS_LOW_LOAD:=30}"
: "${DYNAMIC_SWAPPINESS_HIGH_LOAD:=80}"
: "${DYNAMIC_SWAPPINESS_MIN:=80}"
: "${DYNAMIC_SWAPPINESS_MAX:=95}"

load1=$(cut -d' ' -f1 /proc/loadavg)
cpus=$(nproc)

target=$(awk \
  -v lavg="$load1" -v cpus="$cpus" \
  -v low="$DYNAMIC_SWAPPINESS_LOW_LOAD" -v high="$DYNAMIC_SWAPPINESS_HIGH_LOAD" \
  -v min="$DYNAMIC_SWAPPINESS_MIN" -v max="$DYNAMIC_SWAPPINESS_MAX" '
  BEGIN {
    if (cpus < 1) cpus = 1
    if (high <= low) high = low + 1
    pct = (lavg / cpus) * 100
    if (pct >= high) t = min
    else if (pct <= low) t = max
    else t = max - (pct - low) * (max - min) / (high - low)
    printf "%d", t
  }')

current=$(sysctl -n vm.swappiness)
if [ "$target" != "$current" ]; then
  sysctl -w "vm.swappiness=${target}" >/dev/null
  load_pct=$(awk -v lavg="$load1" -v cpus="$cpus" 'BEGIN { if (cpus < 1) cpus = 1; printf "%.1f", (lavg / cpus) * 100 }')
  logger -t dynamic-swappiness "load=${load_pct}% vm.swappiness ${current} -> ${target}"
fi
