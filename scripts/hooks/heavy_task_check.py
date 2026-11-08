#!/usr/bin/env python3
"""bash_pitfall_guard 规则 10 的判定器：没走全机重任务槽的多 worker pytest（pytest-xdist -n ≥2 / auto / logical）。

stdin 喂整条 Bash 命令；命中时 stdout 打印一行命中标签（如 "pytest -n auto"），未命中不输出、退出码 0。

为什么拦（2026-11-07 实证，Colar 2026-11-08 拍板）：两个会话各跑一套全量测试（-n auto 8 个 worker + 覆盖率，
另一套 -n 6），再加刚重启的 Docker 虚拟机，把 16G 内存和 swap 一起压满，机器卡死被强制重启。每个会话自己看都只跑了
「一套」，没有任何地方统管全机。全机重任务槽（scripts/heavy_slot.py）就是那个统管点，这条规则把手跑的多 worker
pytest 拦到槽里去。只看 -n：内存乘数是 xdist 的 worker 数；单进程 pytest（带不带 --cov）约 0.5–1G，不拦。

命中：
  - pytest / py.test 带 -n <N≥2|auto|logical>（也认 -nauto、-n4、--numprocesses N、--numprocesses=N）
  - python* -m pytest 带同样的参数（含 .venv/bin/python、python3.12）
  - 被 uv run / poetry run / pipenv run / wt run <名> 包着的上述命令；其余 sudo / env / timeout / bash -c 包装由 shell_segments 处理
不命中：
  - -n 0 / -n 1、不带 -n、带 --help
  - 已经经过槽：命令词是 python*，且第一个参数是 …/heavy_slot.py（heavy_slot.py run … -- pytest -n auto）
  - 只是「提到」：作为别的命令的参数（grep / echo）、注释、heredoc 正文
各仓自己接了槽的入口脚本（织锦 clean_check_all.sh / check_all.sh / coverage_snapshot.py）不在这里拦，它们内部排队。
"""
import re
import sys

from shell_segments import first_hit

PYTHON = re.compile(r"python[0-9.]*")
RUNNERS = {"uv": 1, "poetry": 1, "pipenv": 1, "wt": 2}   # 命令词 → 跳过几个词才是被包的命令（wt run <名> …）
SERIAL = {"0", "1"}


def xdist_workers(args):
    """pytest 参数里的 -n 取值；没有 -n 返回 None。"""
    for index, arg in enumerate(args):
        if arg in ("-n", "--numprocesses"):
            return args[index + 1] if index + 1 < len(args) else None
        if arg.startswith("--numprocesses="):
            return arg.split("=", 1)[1]
        if arg.startswith("-n") and not arg.startswith("--"):
            return arg[2:].lstrip("=")
    return None


def pytest_hit(args):
    if "--help" in args or "-h" in args:
        return None
    workers = xdist_workers(args)
    if workers is None or workers in SERIAL:
        return None
    return "pytest -n " + workers


def heavy_leaf(base, rest, assigns):
    if base in ("pytest", "py.test"):
        return pytest_hit(rest)
    if PYTHON.fullmatch(base):
        if rest and rest[0].endswith("heavy_slot.py"):
            return None
        for index, arg in enumerate(rest):
            if arg == "-m" and rest[index + 1:index + 2] == ["pytest"]:
                return pytest_hit(rest[index + 2:])
            if arg == "-mpytest":
                return pytest_hit(rest[index + 1:])
        return None
    skip = RUNNERS.get(base)
    if skip and rest[:1] == ["run"] and len(rest) > skip:
        inner = rest[skip:]
        return heavy_leaf(inner[0].rsplit("/", 1)[-1], inner[1:], assigns)
    return None


def main():
    hit = first_hit(sys.stdin.read(), heavy_leaf)
    if hit:
        print(hit)


if __name__ == "__main__":
    main()
