#!/bin/sh
# 跑全部回归测试。
#
# 为什么需要它:曾经出现过「某个 spec 因为语法/加载错误直接崩掉,没有任何输出」,
# 而当时的检查只看有没有『合计』这一行、崩了就什么也不打印 —— 于是漏过了一个
# 已经提交并打包出去的语法错误。所以这里把「没有输出合计」明确判为失败。
#
# 只用 shell 内建(read/case),不依赖 grep/sed/tail/head。
# 判定用**退出码**(各 spec 失败时会 os.exit(1)),不靠匹配中文百分比字串 ——
# 那样写过的版本因为模式里含全角逗号与空格,被 shell 拆词,自己就语法错误了。
#
# 用法(仓库根目录):
#   sh tests/run_all.sh
#   LUAJIT=/path/to/luajit sh tests/run_all.sh
set -u

LUAJIT="${LUAJIT:-luajit}"
SPECS="tests/moon_spec.lua tests/moonsync_spec.lua tests/update_spec.lua tests/webdav_spec.lua tests/main_spec.lua tests/state_spec.lua"

fail=0
for spec in $SPECS; do
    out="$("$LUAJIT" "$spec" 2>&1)"
    rc=$?

    # 取最后一行含「合计」的输出,仅用于显示
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
    elif [ "$rc" -eq 0 ]; then
        echo "ok                  $spec  $summary"
    else
        echo "FAIL                $spec  $summary"
        n=0
        while IFS= read -r line; do
            case "$line" in
                *FAIL*) if [ "$n" -lt 10 ]; then echo "      $line"; n=$((n + 1)); fi ;;
            esac
        done <<EOF
$out
EOF
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "---- 全部通过 ----"
else
    echo "---- 有测试未通过 ----"
fi
exit "$fail"
