#!/usr/bin/env python3
"""/search skill 的检索引擎: 从 GitHub / HuggingFace / arXiv 三源拉结构化元数据，供选型 triage。

只用 stdlib，不装依赖。单源失败不拖垮其他源（各自 try 住，错误进 result.errors）。

用法:
    python3 scout.py --q "document layout analysis" --q "DLA" --out /tmp/scout.json
    python3 scout.py --q "speech enhancement" --sources gh,arxiv --limit 20

为什么拿这些字段: 见 SKILL.md § Step 3 硬事实体检。核心是 pushed_at / lastModified
这类"代码到底还有没有人动"的信号——它决定去留，而网页搜索拿不准。
"""

import argparse
import io
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

UA = "colar-tech-search/1.0 (personal research tool)"
TIMEOUT = 25


# ---------- SSL ----------
# python.org 装的 macOS Python 不读系统钥匙串，它认死
# /Library/Frameworks/Python.framework/Versions/X/etc/openssl/cert.pem —— 而这个文件
# 只有跑过 "Install Certificates.command" 才存在。没跑过 = 所有 stdlib HTTPS 请求
# 报 CERTIFICATE_VERIFY_FAILED（curl 照常能跑，因为 curl 走系统证书，最容易误判成"网络没问题"）。
# 这里用 certifi 自带的 CA bundle 兜住，不依赖机器修没修过。

def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


SSL_CTX = _ssl_context()


# ---------- 公共工具 ----------

def _curl(url, hdrs, origin):
    """urllib 走不通时的第二通道。

    受限沙箱里解释器的出站可能被直接 Connection refused，而 curl 照常通；
    curl 还走系统证书，顺带绕开 python.org Python 的证书缺失。两个毛病一个解。
    """
    cmd = ["curl", "-s", "-S", "--max-time", str(TIMEOUT), "-w", "\n%{http_code}"]
    for k, v in hdrs.items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT + 10)
    except Exception as e:
        raise RuntimeError(f"urllib failed ({origin}); curl fallback failed too: {e}")
    if p.returncode != 0:
        raise RuntimeError(
            f"urllib failed ({origin}); curl rc={p.returncode} {p.stderr[:150]}")
    body, _, code = p.stdout.rpartition("\n")
    code = code.strip()
    if code != "200":
        # 抛成 HTTPError，让上游的 401 降级逻辑照常生效（fp 必须可 read()）
        raise urllib.error.HTTPError(
            url, int(code) if code.isdigit() else 0,
            f"curl fallback HTTP {code}", None, io.BytesIO(body.encode()))
    return body


def _fetch(url, headers=None):
    hdrs = {"User-Agent": UA, **(headers or {})}
    req = urllib.request.Request(url, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=SSL_CTX) as r:
            return r.read().decode("utf-8")
    except urllib.error.HTTPError:
        # HTTP 状态码是业务信息（401 要降级、403 要看配额、429 要退避）——
        # 原样抛给调用方，绝不能被 curl 重试吞掉。
        raise
    except Exception as e:
        return _curl(url, hdrs, e)


def http_json(url, headers=None):
    return json.loads(_fetch(url, headers))


def http_text(url, headers=None):
    return _fetch(url, headers)


def days_since(iso):
    """距今天数。拿不准就返回 None，不猜。"""
    if not iso:
        return None
    try:
        s = iso.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - dt).days
    except Exception:
        return None


def github_token():
    """先看 env，再问 gh CLI。都没有就匿名（60 req/h）。"""
    for k in ("GITHUB_TOKEN", "GH_TOKEN"):
        if os.environ.get(k):
            return os.environ[k], k
    try:
        p = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip(), "gh-cli"
    except Exception:
        pass
    return None, None


# ---------- GitHub ----------

def search_github(queries, limit, out, errors):
    tok, src = github_token()
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    out["_auth"] = f"token via {src}" if tok else "ANONYMOUS (60/h core, 10/min search)"

    # search 配额：带 token 30/min，匿名 10/min。按实际鉴权状态定间隔，
    # 别一律按匿名的保守值等（3 个 query 会白等 14s）。
    gap = 2 if tok else 7

    seen = {}
    for i, q in enumerate(queries):
        if i:
            time.sleep(gap)
        url = ("https://api.github.com/search/repositories?q="
               + urllib.parse.quote(q)
               + f"&sort=stars&order=desc&per_page={min(limit, 50)}")
        try:
            d = http_json(url, headers)
        except urllib.error.HTTPError as e:
            # `gh auth token` 会吐出一个 token 即使 `gh auth status` 说它 invalid
            # ——拿到 token ≠ token 有效。401/403 时脱掉 Authorization 头匿名重试一次，
            # 否则一个过期凭证会让整轮检索静默归零（比没 token 还糟）。
            if e.code in (401, 403) and "Authorization" in headers:
                errors.append(f"github[{q}]: HTTP {e.code} with token → 降级匿名重试")
                headers.pop("Authorization", None)
                out["_auth"] = "ANONYMOUS (token 被拒，已降级)"
                gap = 7  # 降级后配额掉到 10/min，间隔要跟着放慢
                try:
                    d = http_json(url, headers)
                except Exception as e2:
                    errors.append(f"github[{q}] anon retry: {type(e2).__name__}: {e2}")
                    continue
            else:
                body = e.read()[:200].decode("utf-8", "replace")
                errors.append(f"github[{q}]: HTTP {e.code} {body}")
                continue
        except Exception as e:
            errors.append(f"github[{q}]: {type(e).__name__}: {e}")
            continue

        for r in d.get("items", []):
            name = r["full_name"]
            if name in seen:
                seen[name]["matched_queries"].append(q)
                continue
            lic = (r.get("license") or {}).get("spdx_id")
            seen[name] = {
                "source": "github",
                "id": name,
                "url": r["html_url"],
                "desc": (r.get("description") or "")[:300],
                "stars": r.get("stargazers_count"),
                "forks": r.get("forks_count"),
                "open_issues": r.get("open_issues_count"),
                # pushed_at = 最后一次代码推送；updated_at 会被改描述/改 topics 刷新，
                # 拿它判活跃度会把死仓看成活的。判去留只信 pushed_at。
                "last_push": r.get("pushed_at"),
                "days_since_push": days_since(r.get("pushed_at")),
                "created": r.get("created_at"),
                "license": lic,
                # NOASSERTION = 有 LICENSE 文件但 SPDX 认不出（自定义/研究限定协议）。
                # 商用前必须人工打开看，不能当成 "没协议" 也不能当成 "开源"。
                "license_needs_review": lic in (None, "NOASSERTION", "NONE"),
                "language": r.get("language"),
                "topics": r.get("topics", [])[:10],
                "archived": r.get("archived"),
                "matched_queries": [q],
            }
    out["items"] = sorted(seen.values(), key=lambda x: -(x["stars"] or 0))[:limit]


# ---------- HuggingFace ----------

def _hf_one(kind, q, limit, headers, bucket, errors):
    url = (f"https://huggingface.co/api/{kind}?search={urllib.parse.quote(q)}"
           f"&sort=downloads&direction=-1&limit={limit}&full=true")
    try:
        d = http_json(url, headers)
    except Exception as e:
        errors.append(f"hf[{kind}][{q}]: {type(e).__name__}: {e}")
        return
    for m in d:
        mid = m.get("modelId") or m.get("id")
        if not mid:
            continue
        if mid in bucket:
            bucket[mid]["matched_queries"].append(q)
            continue
        tags = m.get("tags", [])
        lic = next((t.split(":", 1)[1] for t in tags if t.startswith("license:")), None)
        bucket[mid] = {
            "source": f"hf-{kind}",
            "id": mid,
            "url": f"https://huggingface.co/{'datasets/' if kind == 'datasets' else ''}{mid}",
            "desc": "",
            "downloads": m.get("downloads"),
            "likes": m.get("likes"),
            "license": lic,
            "license_needs_review": lic is None,
            "last_modified": m.get("lastModified"),
            "days_since_push": days_since(m.get("lastModified")),
            "pipeline_tag": m.get("pipeline_tag"),
            # gated=True 要点同意条款才能下权重，脚本流程里会卡住 —— 提前标出来
            "gated": m.get("gated", False),
            "private": m.get("private", False),
            "tags": [t for t in tags if not t.startswith("license:")][:12],
            "matched_queries": [q],
        }


def search_hf(queries, limit, out, errors):
    tok = os.environ.get("HF_TOKEN")
    if not tok:
        p = os.path.expanduser("~/.cache/huggingface/token")
        if os.path.exists(p):
            try:
                tok = open(p).read().strip()
            except Exception:
                tok = None
    headers = {"Authorization": f"Bearer {tok}"} if tok else {}
    out["_auth"] = "token" if tok else "anonymous"

    bucket = {}
    # HF 的 search 是子串匹配，连字符/空格是两个不同的世界：
    # "a b" 和 "a-b" 这类变体命中集合几乎不重叠。两种都打。
    variants = []
    for q in queries:
        variants.append(q)
        if " " in q:
            variants.append(q.replace(" ", "-"))
    for q in dict.fromkeys(variants):
        _hf_one("models", q, limit, headers, bucket, errors)
    out["items"] = sorted(bucket.values(), key=lambda x: -(x.get("downloads") or 0))[:limit]


# ---------- arXiv ----------

ATOM = "{http://www.w3.org/2005/Atom}"


def search_arxiv(queries, limit, out, errors):
    bucket = {}
    for i, q in enumerate(queries):
        if i:
            time.sleep(3)  # arXiv 官方要求请求间隔 >=3s
        terms = f'all:"{q}"' if " " in q else f"all:{q}"
        # 必须 https —— http://export.arxiv.org 会直接连接失败（实测 HTTP 000）
        url = ("https://export.arxiv.org/api/query?search_query="
               + urllib.parse.quote(terms)
               + f"&start=0&max_results={limit}&sortBy=submittedDate&sortOrder=descending")
        try:
            xml = http_text(url)
            root = ET.fromstring(xml)
        except Exception as e:
            errors.append(f"arxiv[{q}]: {type(e).__name__}: {e}")
            continue

        for e in root.findall(f"{ATOM}entry"):
            def txt(tag):
                n = e.find(f"{ATOM}{tag}")
                return " ".join(n.text.split()) if n is not None and n.text else ""

            aid = txt("id")
            if not aid:
                continue
            short = aid.rsplit("/", 1)[-1]
            if short in bucket:
                bucket[short]["matched_queries"].append(q)
                continue
            pdf = next((l.get("href") for l in e.findall(f"{ATOM}link")
                        if l.get("title") == "pdf"), aid.replace("/abs/", "/pdf/"))
            bucket[short] = {
                "source": "arxiv",
                "id": short,
                "url": aid,
                "pdf": pdf,
                "title": txt("title"),
                "desc": txt("summary")[:400],
                "published": txt("published"),
                "updated": txt("updated"),
                "days_since_update": days_since(txt("updated")),
                "authors": [a.find(f"{ATOM}name").text
                            for a in e.findall(f"{ATOM}author")][:6],
                "categories": [c.get("term") for c in e.findall(f"{ATOM}category")][:6],
                "matched_queries": [q],
            }
    out["items"] = sorted(bucket.values(),
                          key=lambda x: x.get("published", ""), reverse=True)[:limit]


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--q", action="append", required=True,
                    help="查询词，可重复传多个变体（强烈建议 2-4 个）")
    ap.add_argument("--sources", default="gh,hf,arxiv")
    ap.add_argument("--limit", type=int, default=15)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    src = [s.strip() for s in args.sources.split(",") if s.strip()]
    res = {"queries": args.q, "ran_at": datetime.now(timezone.utc).isoformat(), "errors": []}
    errors = res["errors"]
    threads = []

    for key, fn in (("gh", search_github), ("hf", search_hf), ("arxiv", search_arxiv)):
        if key not in src:
            continue
        res[key] = {"items": []}
        t = threading.Thread(target=fn, args=(args.q, args.limit, res[key], errors))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

    if args.out:
        with open(args.out, "w") as f:
            json.dump(res, f, ensure_ascii=False, indent=2)

    # stdout 摘要：只够判断"检索本身成不成立"，详细评估读 JSON
    for key, label in (("gh", "GitHub"), ("hf", "HuggingFace"), ("arxiv", "arXiv")):
        if key not in res:
            continue
        items = res[key]["items"]
        auth = res[key].get("_auth", "")
        print(f"\n=== {label} ({len(items)} 条){' | auth: ' + auth if auth else ''} ===")
        for it in items[:12]:
            if key == "gh":
                age = it["days_since_push"]
                flag = " [ARCHIVED]" if it.get("archived") else ""
                lic = it["license"] or "?"
                if it["license_needs_review"]:
                    lic += "(!)"
                print(f"  {it['id']}{flag} | ★{it['stars']} | {age}d ago | {lic} | {it['language']}")
            elif key == "hf":
                g = " [GATED]" if it.get("gated") else ""
                print(f"  {it['id']}{g} | ↓{it['downloads']} ♥{it['likes']} | "
                      f"{it['days_since_push']}d ago | {it['license'] or '?'}")
            else:
                print(f"  {it['id']} | {it['published'][:10]} | {it['title'][:68]}")
    if errors:
        print("\n=== ERRORS ===")
        for e in errors:
            print("  " + e)
    if args.out:
        print(f"\n→ 完整结果: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
