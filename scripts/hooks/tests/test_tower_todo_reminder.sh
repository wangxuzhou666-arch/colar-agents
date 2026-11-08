#!/usr/bin/env bash
# tower_todo_reminder.sh 的判别力自证：
#   S 组（必须零输出）：塔台不在 · 输入不是 JSON · session_id 带 ../
#   N 组（必须提示 set）：这个 session 没写过待办 · 待办文件写坏了——S 组的对照，证明零输出不是测试看不见
#   L 组（必须注入清单）：编号从 1 数、勾对得上，并提示 done N
#   P 组：塔台在 HOME 下时命令写成 ~/…，不把绝对路径整段塞进 context
#
# 跑法：bash scripts/hooks/tests/test_tower_todo_reminder.sh
# 变异验证：HOOK=<改坏的副本> bash 本脚本 → 对应用例必须转红。
#   2026-11-08 已验 3 个变异全部被杀：去掉 todo.mjs 存在检查（S1）· 去掉 session_id 格式检查（S3）· 勾选取反（L1）。
#
# 隔离：HOME 和 TOWER_DIR 都指进临时目录，不读真塔台的 .state。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK=${HOOK:-$HERE/../tower_todo_reminder.sh}
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TOWER="$TMP/home/tower"
mkdir -p "$TOWER/scripts" "$TOWER/.state/todos"
: >"$TOWER/scripts/todo.mjs"
SID=5e551011-aaaa-4bbb-8ccc-000000000001
OTHER=5e551011-aaaa-4bbb-8ccc-000000000002
printf '%s' '{"items":[{"text":"甲","done":true},{"text":"乙","done":false}],"updatedAt":1}' >"$TOWER/.state/todos/$SID.json"
printf '%s' '{"items": [' >"$TOWER/.state/todos/$OTHER.json"

run() { # $1 塔台目录 · $2 stdin
  printf '%s' "$2" | HOME="$TMP/home" TOWER_DIR="$1" bash "$HOOK"
}

check() { # $1 用例名 · $2 实际输出 · $3 期望：empty 或要包含的子串（多个用 | 分隔，全部要有）
  local name=$1 out=$2 want=$3 ok=1 part
  if [ "$want" = empty ]; then
    [ -z "$out" ] || ok=0
  else
    IFS='|' read -ra parts <<<"$want"
    for part in "${parts[@]}"; do
      case "$out" in *"$part"*) ;; *) ok=0 ;; esac
    done
  fi
  if [ $ok = 1 ]; then
    pass=$((pass + 1))
    echo "✓ ${name}"
  else
    fail=$((fail + 1))
    echo "✗ ${name}：期望 [${want}]，实际 [${out}]"
  fi
}

check "S1 塔台不在" "$(run "$TMP/nowhere" "{\"session_id\":\"$SID\"}")" empty
check "S2 输入不是 JSON" "$(run "$TOWER" 'not json')" empty
check "S3 session_id 带 ../" "$(run "$TOWER" '{"session_id":"../../etc/passwd-0000-0000-0000-000000"}')" empty
check "N1 没写过待办" "$(run "$TOWER" '{"session_id":"00000000-0000-0000-0000-000000000000"}')" "还没有待办|set"
check "N2 待办文件写坏了" "$(run "$TOWER" "{\"session_id\":\"$OTHER\"}")" "还没有待办|set"
check "L1 注入清单" "$(run "$TOWER" "{\"session_id\":\"$SID\"}")" "1✓ 甲；2☐ 乙|done N"
check "P1 命令写成 ~/" "$(run "$TOWER" "{\"session_id\":\"$SID\"}")" "node ~/tower/scripts/todo.mjs done N"

echo "通过 ${pass}，失败 ${fail}"
[ $fail = 0 ]
