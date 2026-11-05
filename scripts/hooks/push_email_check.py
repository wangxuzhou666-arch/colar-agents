#!/usr/bin/env python3
"""push_email_guard.sh 的判定器：推到公开 GitHub 仓的提交，作者 / 提交者邮箱只能是 GitHub noreply。

stdin 是 PreToolUse(Bash) 的整个 payload（要用 tool_input.command 和 cwd）；命中时 stdout 打印整段 hook
JSON（permissionDecision=deny），未命中不输出、退出码 0。规则全文与已知边界在 push_email_guard.sh 头部注释，
这里只记实现取舍。

命令解析复用 ai_attribution_check：同一个词法器，cd / git -C / 子 shell 的跟踪（record_effects、git_target），
判 GitHub remote 的 github_slug，只读 git 查询 run_git。两条规则对「命令在哪个仓里跑、remote 指向谁」的口径一致。
用白名单（只认 noreply）而不是私人邮箱黑名单：本仓是公开仓，黑名单本身就会把邮箱公开出去。
"""
import json
import os
import re
import subprocess
import sys

from ai_attribution_check import (Context, Lexer, ParseError, git_target, github_slug, record_effects, run_git,
                                  shell_c_script)
from shell_segments import SHELLS, command_index

NOREPLY = re.compile(r"(?:\d+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com", re.IGNORECASE)
OWN_NOREPLY = "229157273+wangxuzhou666-arch@users.noreply.github.com"   # 已出现在所有公开提交里，不算私人信息
# git push 里后面跟一个值的选项：值不能当成 remote / refspec
PUSH_VALUE_OPTS = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}
PUSH_ALL_BRANCHES = {"--all", "--branches", "--mirror"}
MAX_LISTED = 3


def push_plan(push_args):
    """git push 的参数 → (目标 remote 名或 URL，None = 走默认；要推的本地 rev)。只删远端分支时 rev 为空。"""
    target, revs, positionals = None, [], []
    i = 0
    while i < len(push_args):
        arg = push_args[i]
        if arg in PUSH_VALUE_OPTS:
            if arg == "--repo" and i + 1 < len(push_args):
                target = push_args[i + 1]
            i += 2
            continue
        if arg in ("-d", "--delete"):
            return target, []
        if arg.startswith("--repo="):
            target = arg.partition("=")[2]
        elif arg in PUSH_ALL_BRANCHES:
            revs.append("--branches")
        elif arg == "--tags":
            revs.append("--tags")
        elif not arg.startswith("-"):
            positionals.append(arg)
        i += 1
    if positionals:
        target = positionals[0]
    specs = positionals[1:]
    # refspec 的源在冒号前；「+」是强推前缀；源为空（:branch）是删除，没有提交要推
    revs += [src for src in (spec.lstrip("+").split(":", 1)[0] for spec in specs) if src]
    if not specs and not revs:
        revs = ["HEAD"]   # 不写 refspec：推当前分支
    return target, revs


def git_value(repo_dir, git_args):
    """一条只读 git 查询的输出；失败 / 查不到 → ''。"""
    proc = run_git(repo_dir, git_args)
    return proc.stdout.strip() if proc is not None and proc.returncode == 0 else ""


def default_remote(repo_dir):
    """不写 remote 时 git push 推向哪个 remote：pushRemote > remote.pushDefault > 分支的 remote > origin。"""
    branch = git_value(repo_dir, ["symbolic-ref", "--short", "-q", "HEAD"])
    keys = [f"branch.{branch}.pushRemote", "remote.pushDefault", f"branch.{branch}.remote"] if branch else \
        ["remote.pushDefault"]
    for key in keys:
        remote = git_value(repo_dir, ["config", "--get", key])
        if remote:
            return remote
    return "origin"


def target_slug(repo_dir, target):
    """remote 名或 URL → GitHub (owner, repo)；不是 GitHub（huggingface、本地路径）→ None。"""
    url = git_value(repo_dir, ["remote", "get-url", "--push", target]) or target
    return github_slug(url)


def mask(email):
    """拦截文案进模型上下文：邮箱只露首字母和域名。"""
    local, _, domain = email.partition("@")
    return f"{local[:1]}***@{domain}"


def outgoing_hits(repo_dir, revs, head_moved):
    """要推的提交里不是 noreply 的身份 → ['<短 sha> author x***@y', …]。已在任一 remote-tracking 分支上的提交不算：
    上游别人的提交早已公开，fork 落后于上游时也不误拦。本条命令前面会新建 / 改写提交时，那些提交此刻还不存在，
    按仓里生效的 user.email 算。"""
    hits = []
    log = git_value(repo_dir, ["log", "--format=%h%x09%ae%x09%ce", *revs, "--not", "--remotes", "--"]) if revs else ""
    for line in log.splitlines():
        sha, author, committer = line.split("\t")
        hits += [f"{sha} {role} {mask(email)}" for role, email in (("author", author), ("committer", committer))
                 if not NOREPLY.fullmatch(email)]
    email = git_value(repo_dir, ["config", "user.email"]) if head_moved else ""
    if email and not NOREPLY.fullmatch(email):
        hits.append(f"本条命令里新建的提交（user.email {mask(email)}）")
    return hits


def visibility(slug):
    """GitHub 仓的可见性：'private' / 'public'；gh 查不到（未登录、断网、无权限）→ None。"""
    try:
        proc = subprocess.run(["gh", "api", f"repos/{slug[0]}/{slug[1]}", "--jq", ".private"],
                              capture_output=True, text=True, timeout=8, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    flag = proc.stdout.strip()
    if proc.returncode != 0 or flag not in ("true", "false"):
        return None
    return "private" if flag == "true" else "public"


def deny_text(slug, hits, seen):
    where = f"{slug[0]}/{slug[1]}" + ("（gh 查不到它的可见性，按公开处理）" if seen is None else "")
    listed = "；".join(hits[:MAX_LISTED]) + (f"，共 {len(hits)} 处" if len(hits) > MAX_LISTED else "")
    return (f"⛔ push-email-guard: 要推到公开仓 {where} 的提交带着非 GitHub noreply 邮箱：{listed}。"
            "公开仓的提交邮箱人人可见，推上去就收不回（Colar 2026-11-05 定：推到公开仓只用 noreply 身份）。"
            f"修法：git config user.name wangxuzhou666-arch && git config user.email {OWN_NOREPLY}，"
            "再 git commit --amend --no-edit --reset-author（多个提交：git rebase -r <基点> --exec "
            "'git commit --amend --no-edit --reset-author'）。确实要推别人的提交时，交给 Colar 自己推。")


def judge_push(push_args, repo_dir, head_moved):
    target, revs = push_plan(push_args)
    slug = target_slug(repo_dir, target or default_remote(repo_dir))
    if slug is None:
        return None
    hits = outgoing_hits(repo_dir, revs, head_moved)
    if not hits:
        return None
    seen = visibility(slug)
    return None if seen == "private" else deny_text(slug, hits, seen)


def judge_command(cmd, ctx):
    flat = [w.flat() for w in cmd.words]
    _, k = command_index(flat)
    if k >= len(flat):
        return None
    name, args = flat[k].rsplit("/", 1)[-1], cmd.words[k + 1:]
    if name in SHELLS:
        return judge_inline_script(shell_c_script(args), ctx.fork())
    if name != "git":
        return None
    repo_dir, i = git_target(args, ctx)
    if i >= len(args) or args[i].literal() != "push" or repo_dir is None:
        return None
    push_args = [w.literal() for w in args[i + 1:]]
    # 参数里有变量 / 命令替换：推向哪、推什么都推断不了，不猜，放行
    return None if None in push_args else judge_push(push_args, repo_dir, ctx.head_moved)


def judge_inline_script(script, ctx):
    if script is None:
        return None
    try:
        nodes, _ = Lexer(script).parse_script(0, in_subst=False)
    except ParseError:
        return None   # 包进去的脚本解析不了：不猜，放行
    return judge_script(nodes, ctx)


def judge_script(nodes, ctx):
    """逐条判定，返回第一个拦截原因；每条判完把它对后续命令的影响（cd、新建提交…）记进 ctx。"""
    for node in nodes:
        if node == "(":
            ctx.group_cwds.append(ctx.cwd)
            continue
        if node == ")":
            ctx.cwd = ctx.group_cwds.pop()
            continue
        reason = judge_command(node, ctx)
        if reason:
            return reason
        record_effects(node, ctx)
    return None


def main():
    payload = json.loads(sys.stdin.read())
    command = payload.get("tool_input", {}).get("command") or ""
    cwd = payload.get("cwd") or os.getcwd()
    ctx = Context(cwd if os.path.isdir(cwd) else None, os.environ.get("HOME", ""))
    try:
        nodes, _ = Lexer(command).parse_script(0, in_subst=False)
    except ParseError:
        return   # 引号 / 括号不平衡：shell 自己也会报错，不猜，放行
    reason = judge_script(nodes, ctx)
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}))


if __name__ == "__main__":
    main()
