#!/usr/bin/env python3
"""
sync_repos.py — 一键同步 colar-agents + colar-memory 双 repo

用法:
    python3 scripts/sync_repos.py "feat: 加 idea max mode"
    python3 scripts/sync_repos.py                    # 默认 message
    python3 scripts/sync_repos.py --dry              # 只看 status 不 commit
    python3 scripts/sync_repos.py --yes              # 跳过 public confirm

环境变量(Windows 必配):
    COLAR_AGENCY_REPO   默认 ~/Desktop/colar-agents
    COLAR_MEMORY_REPO   默认 ~/Desktop/colar-memory
"""
import os
import sys
import socket
import shutil
import subprocess
from datetime import date
from pathlib import Path

HOME = Path.home()
AGENCY = Path(os.environ.get("COLAR_AGENCY_REPO", HOME / "Desktop" / "colar-agents"))
MEMORY = Path(os.environ.get("COLAR_MEMORY_REPO", HOME / "Desktop" / "colar-memory"))
HOSTNAME = socket.gethostname().split(".")[0].lower()

# (路径, remote 必含子串, 期望可见性, add 策略)
REPOS = [
    {
        "name": "colar-agents",
        "path": AGENCY,
        "remote_match": "colar-agents",
        "visibility": "PUBLIC",
        "add_paths": ["soul/", "scripts/", "agents/", "skills/", ".claude/",
                       "CLAUDE.md", "README.md", ".gitattributes", ".gitleaks.toml",
                       ".gitignore"],
    },
    {
        "name": "colar-memory",
        "path": MEMORY,
        "remote_match": "colar-memory",
        "visibility": "PRIVATE",
        "add_paths": ["*.md", "agents/", "transcripts/"],
    },
]


def run(cmd, cwd=None, check=True, capture=True):
    res = subprocess.run(cmd, cwd=cwd, capture_output=capture, text=True)
    if check and res.returncode != 0:
        print(f"\n[FAIL] {' '.join(cmd)}\n{res.stderr}", file=sys.stderr)
        sys.exit(res.returncode)
    return res


def ok(msg): print(f"  ✓ {msg}")
def info(msg): print(f"  · {msg}")
def fail(msg):
    print(f"  ✗ {msg}", file=sys.stderr); sys.exit(1)


def guard_remote(repo):
    if not repo["path"].exists():
        fail(f"{repo['name']} 路径不存在: {repo['path']}\n"
             f"    Windows 首次跑请先: git clone https://github.com/wangxuzhou666-arch/{repo['name']}.git {repo['path']}\n"
             f"    或 export COLAR_{'AGENCY' if 'agency' in repo['name'] else 'MEMORY'}_REPO=<实际路径>")
    res = run(["git", "remote", "get-url", "origin"], cwd=repo["path"])
    url = res.stdout.strip()
    if repo["remote_match"] not in url:
        fail(f"{repo['name']} remote 不匹配,期望含 '{repo['remote_match']}',实际 {url}")
    ok(f"{repo['name']} remote 校验通过")

    # 可见性校验(gh 可选,缺 gh 跳过 — 不阻断)
    if shutil.which("gh"):
        res = run(["gh", "repo", "view", "--json", "visibility", "-q", ".visibility"],
                  cwd=repo["path"], check=False)
        vis = res.stdout.strip().upper()
        if vis and vis != repo["visibility"]:
            fail(f"🚨 {repo['name']} GitHub 可见性={vis},期望={repo['visibility']}")
        if vis:
            ok(f"{repo['name']} 可见性={vis}")


def pull_rebase(repo):
    info(f"{repo['name']} fetch + rebase...")
    run(["git", "fetch", "origin"], cwd=repo["path"])
    # 自动判断默认分支
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo["path"]).stdout.strip()
    res = run(["git", "rebase", "--autostash", f"origin/{branch}"], cwd=repo["path"], check=False)
    if res.returncode != 0:
        fail(f"{repo['name']} rebase 冲突,请手动解决后重跑\n{res.stdout}\n{res.stderr}")
    ok(f"{repo['name']} 已与 origin/{branch} 同步")


def stage(repo):
    for p in repo["add_paths"]:
        # 显式列表 add,逐项忽略不存在的
        run(["git", "add", "--", p], cwd=repo["path"], check=False)
    res = run(["git", "diff", "--cached", "--name-only"], cwd=repo["path"])
    return [l for l in res.stdout.strip().split("\n") if l]


def gitleaks_check(repo):
    if not shutil.which("gitleaks"):
        info(f"{repo['name']} 跳过 gitleaks (未安装,建议: brew install gitleaks)")
        return
    res = run(["gitleaks", "protect", "--staged", "--no-banner", "-v"],
              cwd=repo["path"], check=False)
    if res.returncode != 0:
        fail(f"🚨 {repo['name']} gitleaks 命中 secret,已阻止 commit\n{res.stdout}")
    ok(f"{repo['name']} gitleaks 通过")


def commit_push(repo, msg, yes_flag, dry):
    staged = stage(repo)
    if not staged:
        info(f"{repo['name']} 无改动,跳过")
        return
    print(f"  · 拟 commit {len(staged)} 个文件:")
    for f in staged[:10]:
        print(f"      - {f}")
    if len(staged) > 10:
        print(f"      ... 还有 {len(staged)-10} 个")

    if dry:
        info(f"{repo['name']} --dry 模式,只看不动")
        # 撤销 staging
        run(["git", "reset", "HEAD"], cwd=repo["path"], check=False)
        return

    gitleaks_check(repo)

    # public repo 二次确认
    if repo["visibility"] == "PUBLIC" and not yes_flag:
        ans = input(f"  ? 推送到 PUBLIC repo {repo['name']}? (y/N) ").strip().lower()
        if ans != "y":
            info("用户取消,撤销 staging")
            run(["git", "reset", "HEAD"], cwd=repo["path"], check=False)
            return

    # 构建带上下文的 message
    sample = " ".join(Path(f).name for f in staged[:2])
    full_msg = f"{msg} [{HOSTNAME}: {sample}{'...' if len(staged)>2 else ''}]"

    run(["git", "commit", "-m", full_msg], cwd=repo["path"])
    ok(f"{repo['name']} commit 成功")

    # push,失败 retry 一次(rebase 后)
    res = run(["git", "push", "origin", "HEAD"], cwd=repo["path"], check=False)
    if res.returncode != 0:
        info(f"{repo['name']} push 被拒,尝试 rebase 后重试...")
        run(["git", "fetch", "origin"], cwd=repo["path"])
        branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo["path"]).stdout.strip()
        run(["git", "rebase", "--autostash", f"origin/{branch}"], cwd=repo["path"])
        run(["git", "push", "origin", "HEAD"], cwd=repo["path"])
    ok(f"{repo['name']} push 成功")


def main():
    args = sys.argv[1:]
    dry = "--dry" in args
    yes = "--yes" in args
    args = [a for a in args if not a.startswith("--")]
    msg = args[0] if args else f"chore: sync {date.today().isoformat()}"

    print(f"\n=== sync_repos @ {HOSTNAME} ===")
    print(f"message: {msg}\n")

    # 阶段 1: 全部 guard + pull
    for repo in REPOS:
        print(f"[guard] {repo['name']}")
        guard_remote(repo)
        if not dry:
            pull_rebase(repo)

    # 阶段 2: 串行 stage + push
    for repo in REPOS:
        print(f"\n[sync] {repo['name']}")
        commit_push(repo, msg, yes, dry)

    print("\n=== done ===")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n中断"); sys.exit(130)
