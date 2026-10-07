#!/bin/sh
# 跑全部回归测试。
#
# 为什么需要它:曾经出现过「某个 spec 因为语法/加载错误直接崩掉,没有任何输出」,
# 而当时的检查只看有没有『合计』这一行、崩了就什么也不打印 —— 于是漏过了一个
# 已经提交并打包出去的语法错误。所以这里把「没有输出合计」明确判为失败。
#
# 只用 shell 内建(read/case),不依赖 grep/sed/tail/head:
# 第一次写的时候用了它们,而调用时的 PATH 里没有这些命令,结果四份测试全被误判成崩溃。
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

    summary=""
    while IFS= read -r line; do
        case "$line" in
            *合计*) summary="$line" ;;
        esac
    done <<EOF
$out
EOF

    if [ -z "$summary" ]; then
        echo "FAIL(崩溃,无输出合计)  $spec"
        n=0
        while IFS= read -r line; do
            if [ "$n" -ge 6 ]; then break; fi
            echo "      $line"
            n=$((n + 1))
        done <<EOF
$out
EOF
        fail=1
    else
        case "$summary" in
            *，0 失败*)
                echo "ok                  $spec  $summary"
                ;;
            *)
                echo "FAIL                $spec  $summary"
                fail=1
                ;;
        esac
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "---- 全部通过 ----"
else
    echo "---- 有测试未通过 ----"
fi
exit "$fail"
