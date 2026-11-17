"""用 Python 标准编解码器生成纯 Lua 解码表，不在插件运行时依赖 Python。"""

from pathlib import Path


def generate():
    rows = []
    for lead in range(0x81, 0xFF):
        chars = []
        for trail in list(range(0x40, 0x7F)) + list(range(0x80, 0xFF)):
            chars.append(bytes([lead, trail]).decode("gb18030"))
        row = "".join(chars)
        assert "]==]" not in row and "\n" not in row and "\r" not in row
        rows.append("    [==[" + row + "]==],")

    ranges = []
    current = None
    for pointer in range(126 * 10 * 126 * 10):
        n = pointer
        d = n % 10 + 0x30
        n //= 10
        c = n % 126 + 0x81
        n //= 126
        b = n % 10 + 0x30
        a = n // 10 + 0x81
        try:
            cp = ord(bytes([a, b, c, d]).decode("gb18030"))
        except UnicodeDecodeError:
            current = None
            continue
        if (
            current is not None
            and pointer == current[1] + 1
            and cp == current[2] + pointer - current[0]
        ):
            current[1] = pointer
        else:
            current = [pointer, pointer, cp]
            ranges.append(current)
    lines = [
        "-- GB18030 解码数据：由 tests/generate_gb18030.py 使用 Python 标准 codec 生成。",
        "-- 双字节按 lead 0x81..0xFE、trail 0x40..0x7E/0x80..0xFE 排列；四字节为有效连续区间。",
        "-- 勿手改；生成结果由 Python codec 穷举验证。运行时不需要系统 iconv 或外部命令。",
        "return { rows = {",
        *rows,
        "}, ranges = {",
        *("    {%d, %d, %d}," % tuple(r) for r in ranges),
        "} }",
        "",
    ]
    target = (
        Path(__file__).resolve().parent.parent
        / "inkbridge.koplugin"
        / "inkbridge_gb18030.lua"
    )
    target.write_bytes("\n".join(lines).encode("utf-8"))
    print(
        target.name,
        "rows",
        len(rows),
        "ranges",
        len(ranges),
        "bytes",
        target.stat().st_size,
    )


if __name__ == "__main__":
    generate()
