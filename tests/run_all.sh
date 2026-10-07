#!/bin/sh
# 跑全部回归测试。
#
# 为什么需要它:曾经出现过「某个 spec 因为语法/加载错误直接崩掉,没有任何输出」,
# 而当时的检查只看有没有『合计』这一行、崩了就什么也不打印 —— 于是漏过了
# 一个已经提交并打包出去的语法错误。所以这里把「没有输出合计」明确判为失败。
#
# 用法(仓库根目录):
#   sh tests/run_all.sh
#   LUAJIT=/path/to/luajit sh tests/run_all.sh
set -u

LUAJIT="${LUAJIT:-luajit}"
SPECS="tests/moon_spec.lua tests/webdav_spec.lua tests/main_spec.lua tests/state_spec.lua"

fail=0
for spec in $SPECS; do
    out="$("$LUAJIT" "$spec" 2>&1)"
    summary="$(printf '%s\n' "$out" | grep '合计' | tail -1)"
    if [ -z "$summary" ]; then
        echo "FAIL(崩溃,无输出)  $spec"
        printf '%s\n' "$out" | head -6 | sed 's/^/      /'
        fail=1
    elif printf '%s' "$summary" | grep -q '，0 失败'; then
        echo "ok                  $spec  $summary"
    else
        echo "FAIL                $spec  $summary"
        printf '%s\n' "$out" | grep 'FAIL' | head -10 | sed 's/^/      /'
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "---- 有测试未通过 ----"
else
    echo "---- 全部通过 ----"
fi
exit "$fail"
