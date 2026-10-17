#!/usr/bin/env python3
"""bash_pitfall_guard 规则 9 的判定器：跳过仓库钩子（--no-verify / 换走 core.hooksPath）与强推。

stdin 喂整条 Bash 命令；命中时 stdout 打印一行「<类别> <标签>」，类别是 no-verify / hooks-path / force
（如 "force git push --force-with-lease"）；未命中不输出、退出码 0。

为什么拦（2026-10-17 织锦 git 协作规范）：多个助理共用一个仓，规则的机械层就是仓库钩子
（pre-commit / pre-merge-commit / pre-push）——--no-verify 一个词就让它们全部失效、且不留痕；
把 core.hooksPath 换走或清掉是同一件事，用 git config 写进仓库配置的还会一直生效（之后谁提交都不跑钩子）。
开发分支一律 merge origin/main 后快进推送，推送被拒说明远端有你没有的提交（单写入方已被破坏），
强推会把别人已推的提交覆盖掉；push --mirror 是对全部引用强推，还会删掉远端多出来的分支 / 标签。

命中：
  - git commit 带 --no-verify / -n（含 -an 这类合写短选项；-m 等吃值的短选项之后的字母是值，不算）
  - git merge 带 --no-verify（会跳过 pre-merge-commit；git merge -n 是 --no-stat，不算）
  - git push 带 --no-verify
  - git push 带 --force / -f（含 -uf 合写）/ --force-with-lease[=…] / --force-if-includes / --mirror / 「+」开头的 refspec
  - git -c core.hooksPath=… / --config-env[=]core.hooksPath=…：任何子命令、任何值（键不分大小写，git 本身就不分）
  - git config [作用域 / 类型选项] core.hooksPath <值>（值不是 .githooks）、git config --unset[-all] core.hooksPath，
    以及 git 2.46+ 的同义写法 git config set / unset
  - git 全局选项（-C <目录> / -c k=v / --git-dir …）在子命令之前、以及规则 8 同款的包装与 bash -c 递归
不命中：
  - git push -n / --dry-run（演习，没有副作用）；--delete / -d / 「:分支」删除；普通推送
  - git config core.hooksPath .githooks（带不带 --local 都放行：织锦 SessionStart 钩子每次开会话都跑这一句）；
    只读：不带值的 git config core.hooksPath、--get / --get-regexp / --list …
  - 只是「提到」：引号里 / 注释 / heredoc 正文 / commit message 里；git stash push 之类别的子命令
放行：紧贴该条 git 命令写前缀 ALLOW_NO_VERIFY=1（跳钩子 / 换钩子目录）/ ALLOW_GIT_FORCE=1（强推 / --mirror），
  只对紧跟的那一条生效、各管各的；export 不算 —— 同规则 8 的 ALLOW_DOCKER_PRUNE=1。

已知边界（宁漏勿误、不追）：长选项缩写（--no-veri / --force-w / --mirr）、git 别名（git pf）、
  GIT_CONFIG_COUNT / GIT_CONFIG_PARAMETERS 环境变量、直接改 .git/config 都不检查——兜底是 main 上的服务端 ruleset；
  切词层的边界见 shell_segments.py。
自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
"""
import sys

from shell_segments import first_hit, skip_options

ALLOW_NO_VERIFY = "ALLOW_NO_VERIFY=1"
ALLOW_FORCE = "ALLOW_GIT_FORCE=1"
# git 全局选项里后面跟一个值的（git -C <dir> / -c k=v / --git-dir <d> …）
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}
FORCE_LONG = ("--force", "--force-with-lease", "--force-if-includes", "--mirror")
HOOKS_PATH = "core.hookspath"   # git 配置键不分大小写，一律转小写再比
REPO_HOOKS_DIR = ".githooks"    # core.hooksPath 唯一放行的值（原样比，./.githooks 也不算）

# 各子命令「后面跟一个值」的选项：值可能恰好长得像 -n / +ref，必须连同值一起跳过。
# VALUE_SHORT：-m <msg>，合写时（-am msg）其后的字母都属于值；OPTIONAL_SHORT：-u[<mode>] 这种值只能紧贴。
COMMIT_VALUE_SHORT = set("mFCct")
COMMIT_OPTIONAL_SHORT = set("uS")
COMMIT_VALUE_LONG = {"--message", "--file", "--reuse-message", "--reedit-message", "--fixup", "--squash",
                     "--author", "--date", "--template", "--cleanup", "--trailer", "--pathspec-from-file"}
MERGE_VALUE_SHORT = set("mFsX")
MERGE_OPTIONAL_SHORT = set("S")
MERGE_VALUE_LONG = {"--message", "--file", "--strategy", "--strategy-option", "--into-name", "--cleanup"}
PUSH_VALUE_SHORT = set("o")
PUSH_VALUE_LONG = {"--repo", "--receive-pack", "--exec", "--push-option"}
CONFIG_VALUE_SHORT = set("ft")   # -f <文件> / -t <类型>
CONFIG_VALUE_LONG = {"--file", "--blob", "--type", "--value", "--comment", "--default", "--url"}
# 旧写法里这些动作不是「给键赋值」（另有 --get* 一族）：只读 / 列出 / 编辑器 / 改段名
CONFIG_NOT_SET = {"--list", "--edit", "--rename-section", "--remove-section"}


def parse_args(args, value_short, optional_short, value_long):
    """拆成（短选项字母集合，长选项名列表，位置参数列表）。"""
    shorts, longs, positionals = set(), [], []
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            positionals += args[i:]
            break
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            longs.append(name)
            if "=" not in a and name in value_long:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:], 1):
                if ch in value_short:
                    if k == len(a) - 1:
                        i += 1  # 值在下一个词
                    break
                if ch in optional_short:
                    break       # 可选值只能紧贴，其后的字母都是值
                shorts.add(ch)
        else:
            positionals.append(a)
    return shorts, longs, positionals


def commit_hit(args, assigns):
    shorts, longs, _ = parse_args(args, COMMIT_VALUE_SHORT, COMMIT_OPTIONAL_SHORT, COMMIT_VALUE_LONG)
    if ALLOW_NO_VERIFY in assigns:
        return None
    if "--no-verify" in longs:
        return "no-verify git commit --no-verify"
    if "n" in shorts:
        return "no-verify git commit -n"
    return None


def merge_hit(args, assigns):
    _, longs, _ = parse_args(args, MERGE_VALUE_SHORT, MERGE_OPTIONAL_SHORT, MERGE_VALUE_LONG)
    if "--no-verify" in longs and ALLOW_NO_VERIFY not in assigns:
        return "no-verify git merge --no-verify"
    return None


def push_hit(args, assigns):
    shorts, longs, positionals = parse_args(args, PUSH_VALUE_SHORT, set(), PUSH_VALUE_LONG)
    if "n" in shorts or "--dry-run" in longs:
        return None
    if "--no-verify" in longs and ALLOW_NO_VERIFY not in assigns:
        return "no-verify git push --no-verify"
    if ALLOW_FORCE in assigns:
        return None
    for flag in FORCE_LONG:
        if flag in longs:
            return "force git push " + flag
    if "f" in shorts:
        return "force git push -f"
    for refspec in positionals[1:]:   # 第一个位置参数是远端
        if refspec.startswith("+"):
            return "force git push " + refspec
    return None


def config_hit(args, assigns):
    """git config 换走 / 清掉 core.hooksPath；设成 .githooks 放行。git 2.46+ 的 set / unset 子命令同等对待。"""
    shorts, longs, words = parse_args(args, CONFIG_VALUE_SHORT, set(), CONFIG_VALUE_LONG)
    if words and words[0] in ("set", "unset"):
        action, words = words[0], words[1:]
    elif "--unset" in longs or "--unset-all" in longs:
        action = "unset"
    elif shorts & set("le") or CONFIG_NOT_SET.intersection(longs) or any(x.startswith("--get") for x in longs):
        return None   # 读 / 列出 / 编辑，不是给键赋值
    else:
        action = "set"
    if not words or words[0].lower() != HOOKS_PATH or ALLOW_NO_VERIFY in assigns:
        return None
    if action == "unset":
        return "hooks-path git config --unset core.hooksPath"
    if len(words) > 1 and words[1] != REPO_HOOKS_DIR:
        return "hooks-path git config core.hooksPath " + words[1]
    return None   # 不带值是读；设成 .githooks 放行


def hooks_path_option(opts, assigns):
    """git 全局选项 -c / --config-env 临时换 core.hooksPath：对任何子命令、任何值都算。"""
    if ALLOW_NO_VERIFY in assigns:
        return None
    for k, opt in enumerate(opts):
        if opt in ("-c", "--config-env") and k + 1 < len(opts):
            setting, shown = opts[k + 1], opt + " " + opts[k + 1]
        elif opt.startswith("--config-env="):
            setting, shown = opt[len("--config-env="):], opt
        else:
            continue
        if setting.split("=", 1)[0].lower() == HOOKS_PATH:
            return "hooks-path git " + shown
    return None


SUBCOMMANDS = {"commit": commit_hit, "merge": merge_hit, "push": push_hit, "config": config_hit}


def git_leaf(base, rest, assigns):
    if base != "git":
        return None
    i = skip_options(rest, GIT_VALUE_OPTS)
    if i >= len(rest):
        return None
    sub, args = rest[i], rest[i + 1:]
    if "-h" in args or "--help" in args:
        return None
    hit = hooks_path_option(rest[:i], assigns)
    if hit or sub not in SUBCOMMANDS:
        return hit
    return SUBCOMMANDS[sub](args, assigns)


def main():
    hit = first_hit(sys.stdin.read(), git_leaf)
    if hit:
        print(hit)


if __name__ == "__main__":
    main()
