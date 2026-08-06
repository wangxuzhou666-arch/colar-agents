#!/usr/bin/env bash
# verify_and_open —— dev server 真健康才 open 浏览器(非 hook,供 AI ship 后调用)。
#
# Usage:   bash scripts/verify_and_open.sh [--no-open] [url]     # url 默认 http://localhost:3000
#          --no-open: 只验证不 open(测试/CI 用)
# Exit:    0 = 全部验证通过(已 open);1 = 任一验证失败(打印失败清单,不 open)
#
# 背景(feedback_dev_session_auto_open_browser.md):Next.js HMR 会出
#   "server 200 但 client chunks 404" 假象 → 页面永远卡"加载中",Colar 无法区分。
#   所以 open 前必须:① HTML 真 200;② 从 HTML 提取**真实引用**的 JS chunk 逐个验 200。
#   ⚠️ 绝不硬编码 chunk 名 —— webpack dev 是 main-app.js 等固定名,Turbopack 是哈希名
#   (如 _1anvha4._.js),硬编码判据在 Turbopack 项目实测全假阳性(2026-07-04 面料大王)。

set -u

NO_OPEN=0
if [ "${1:-}" = "--no-open" ]; then
    NO_OPEN=1
    shift
fi
URL="${1:-http://localhost:3000}"

# 127.0.0.1 与 localhost 是**不同 origin**:多数 dev 后端 CORS 白名单只写 localhost,
# 传 127.0.0.1 会让前端跨 origin 调 API 被 CORS 拦 → HTML/chunks 全 200 但页面永远卡"载入中"
# (2026-07-27 实测:某 FastAPI 后端 CORS allow_origins=["http://localhost:3000"])。
# 归一到 localhost(DNS 上等价解析到 127.0.0.1,本地健康验证不受影响),消除这类假 200。
URL=$(printf '%s' "$URL" | sed -E 's#://127\.0\.0\.1([:/]|$)#://localhost\1#')

# origin = scheme://host[:port],用于把相对 src 拼成绝对 URL
origin=$(printf '%s' "$URL" | sed -E 's#^(https?://[^/]+).*#\1#')
scheme="${URL%%:*}"

# ① 预热请求触发 dev server 初次编译(Next.js 首个请求才 compile),再取正式 HTML
curl -s -o /dev/null --max-time 20 "$URL" 2>/dev/null || true
sleep 3

html_file=$(mktemp)
trap 'rm -f "$html_file"' EXIT
# curl 失败时 -w 仍会输出 000,不要再 || echo 兜底(会双写成 000000)
code=$(curl -s -o "$html_file" -w '%{http_code}' --max-time 20 "$URL" 2>/dev/null || true)
code="${code:-000}"
if [ "$code" != "200" ]; then
    echo "✗ verify FAILED — HTML $URL → HTTP $code(server 没起/没 ready),不 open"
    exit 1
fi

# ② 从 HTML 提取真实引用的 JS(script src,单双引号都认;&amp; 还原成 &)
srcs=$(grep -oE 'src=["'"'"'][^"'"'"']+\.js[^"'"'"']*["'"'"']' "$html_file" 2>/dev/null \
    | sed -E 's/^src=.//; s/.$//; s/&amp;/\&/g' | sort -u)

if [ -z "$srcs" ]; then
    # 没有任何 script src → 不存在 chunk 404 卡加载问题(纯静态页),HTML 200 即可 open
    echo "⚠ HTML 中未发现 script src(纯静态页?)— 跳过 chunk 验证,仅按 HTML 200 放行"
else
    fails=""
    n=0
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        case "$src" in
            http://*|https://*) chunk_url="$src" ;;
            //*)                chunk_url="${scheme}:${src}" ;;
            /*)                 chunk_url="${origin}${src}" ;;
            *)                  chunk_url="${origin}/${src}" ;;
        esac
        n=$((n + 1))
        ccode=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$chunk_url" 2>/dev/null || true)
        ccode="${ccode:-000}"
        if [ "$ccode" != "200" ]; then
            fails="${fails}  HTTP ${ccode}  ${chunk_url}"$'\n'
        fi
    done <<< "$srcs"

    if [ -n "$fails" ]; then
        echo "✗ verify FAILED — HTML 200 但以下真实引用的 chunk 非 200(HMR chunk-emit 异常,页面会卡加载中):"
        printf '%s' "$fails"
        echo "  → 不 open。修法: nuke .next + 重启 dev server + 重新 verify"
        exit 1
    fi
    echo "✓ verified — HTML 200 + ${n} 个真实引用 JS chunk 全 200"
fi

if [ "$NO_OPEN" -eq 1 ]; then
    echo "(--no-open 指定,跳过 open)"
    exit 0
fi

if command -v open >/dev/null 2>&1; then
    open "$URL"
    echo "已 open $URL"
else
    echo "⚠ open 命令不可用(非 macOS?),请手动打开 $URL"
fi
exit 0
