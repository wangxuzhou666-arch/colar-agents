#!/usr/bin/env python3
"""bash_pitfall_guard 规则 8 的判定器：会删镜像 / build cache 的 docker 全局清理。

stdin 喂整条 Bash 命令；命中时 stdout 打印一行命中标签（如 "docker image prune -a"），
未命中不输出、退出码 0。

为什么拦：本机有钉死 digest、按政策不推 registry、无法按字节复原的本地镜像。
实证 2026-10-07：磁盘清理 session 把 `docker image prune -a -f; docker builder prune -a -f`
当无风险操作执行，删掉织锦 PPTAgent 线 B3 验收钉死的 colar/pptagent-lab:v1d-f60543fb…
及 C 系列冻结 / 复核 / 变异镜像，零恢复来源，B3 硬阻塞。

命中：
  - docker {image|system|builder|buildx} prune 带 -a / --all（含 -af / -fa / -a -f / --all --force）
  - docker rmi …、docker image rm / remove …
  - 出现在 ; && || | & 换行 $( ) ` 之后；前面带 VAR=… 赋值；被 sudo / env / xargs / nice /
    timeout / if / do 等包装；docker 全局选项 --context / -c / -H / --host 在子命令之前；
    bash|sh|zsh -c '<脚本>' 与 eval 包裹的脚本递归检查
不命中：
  - 不带 -a 的 prune（只删 dangling）、只读子命令（ps -a / image ls / images -a / inspect）
  - 只是「提到」：作为别的命令的参数（grep / echo / git commit -m）、注释、heredoc 正文
  - 带 --help / -h
放行：紧贴该条 docker 命令写前缀 ALLOW_DOCKER_PRUNE=1（也认 sudo / env / xargs 之前的赋值），
  只对紧跟的那一条生效；`export ALLOW_DOCKER_PRUNE=1` 不算，也不读 hook 进程的环境变量 ——
  刻意不做全局开关。

切词与已知边界（双引号内的 $(…)、引号不平衡、ssh 远端命令、变量间接调用不检查）见 shell_segments.py。
自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
"""
import re
import sys

from shell_segments import first_hit, skip_options

ALLOW = "ALLOW_DOCKER_PRUNE=1"
SHORT_ALL = re.compile(r"-[A-Za-z]*a[A-Za-z]*")  # -a / -af / -fa，不含 --all（两个短横线不匹配）
DOCKER_VALUE_OPTS = {"-c", "--context", "-H", "--host", "--config", "-l", "--log-level",
                     "--tlscacert", "--tlscert", "--tlskey"}
BUILDX_VALUE_OPTS = {"--builder"}
PRUNE_GROUPS = {"image", "system", "builder", "buildx"}


def has_all_flag(args):
    return any(a in ("--all", "--all=true") or SHORT_ALL.fullmatch(a) for a in args)


def docker_hit(args):
    """args = docker 之后的词。命中返回标签，否则 None。"""
    i = skip_options(args, DOCKER_VALUE_OPTS)
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    if "--help" in rest or "-h" in rest:
        return None
    if sub == "rmi":
        return "docker rmi"
    if sub not in PRUNE_GROUPS:
        return None
    j = skip_options(rest, BUILDX_VALUE_OPTS if sub == "buildx" else set())
    if j >= len(rest):
        return None
    action, tail = rest[j], rest[j + 1:]
    if sub == "image" and action in ("rm", "remove"):
        return "docker image " + action
    if action == "prune" and has_all_flag(tail):
        return "docker %s prune -a" % sub
    return None


def docker_leaf(base, rest, assigns):
    if base != "docker" or ALLOW in assigns:
        return None
    return docker_hit(rest)


def main():
    hit = first_hit(sys.stdin.read(), docker_leaf)
    if hit:
        print(hit)


if __name__ == "__main__":
    main()
