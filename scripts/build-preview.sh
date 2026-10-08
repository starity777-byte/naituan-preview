#!/usr/bin/env bash
# 奶团小屋分支预览生成器（GitHub Actions 和本地共用）。
#
# 做的事：
#   1. 读取 starity777-byte/naituan 所有「打开中」的 PR（只要同仓库分支的 PR，fork 来的不做）；
#   2. 每个 PR 的 head 分支 -> 本仓库 /<分支名>/ 目录，做成存档隔离的试玩副本；
#      只有分支最新提交（或本脚本）变了才重建，已构建的提交记在 <目录>/preview-info.txt；
#   3. PR 已合并/关闭、分支没了的预览目录直接删掉；
#   4. 重新生成根目录 index.html（预览列表）、robots.txt、.nojekyll。
# 本脚本只改本仓库的工作区，不提交、不推送（由 workflow 或 preview.sh 负责）。
# 对 naituan 仓库只做只读操作（API 读取 + git fetch），绝不修改它。
#
# 用法：bash scripts/build-preview.sh          （FORCE=1 时全部重建）
# 依赖：bash、git、perl、node、gh（需要 GH_TOKEN 或已登录；公开仓库只读即可）
set -euo pipefail

SRC_REPO=${SRC_REPO:-starity777-byte/naituan}
OWNER=${SRC_REPO%%/*}
SRC_URL="https://github.com/$SRC_REPO"
LIVE_URL="https://$OWNER.github.io/${SRC_REPO#*/}/"
SUFFIX=-preview
FORCE=${FORCE:-0}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF="$ROOT/scripts/build-preview.sh"
BUILDER=$(sha256sum "$SELF" | cut -c1-12)
EXCLUDE=(.git .github .gitignore tests tools docs CNAME assets/vendor/51la)
RESERVED=" scripts assets "

log() { echo "==> $*"; }
die() { echo "错误：$*" >&2; exit 1; }
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
dirname_for() { printf '%s' "$1" | sed -E 's#[^A-Za-z0-9._-]+#-#g; s#^[.-]+##'; }
info_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
SRCGIT=$WORK/src
src_ready=0
ensure_src() {
  (( src_ready )) && return 0
  git init --quiet "$SRCGIT"
  git -C "$SRCGIT" remote add origin "$SRC_URL.git"
  src_ready=1
}

# ---------------------------------------------------------------------------
build_one() {  # $1=PR号 $2=分支 $3=PR标题 $4=目录
  local num=$1 branch=$2 title=$3 dir=$4
  local OUT=$WORK/out-$num REPORT=$WORK/report-$num.txt
  ensure_src
  timeout 600 git -C "$SRCGIT" fetch --quiet --depth=1 origin "+refs/pull/$num/head:refs/preview/$num" || die "取不到 PR #$num 的代码"
  local sha subject
  sha=$(git -C "$SRCGIT" rev-parse "refs/preview/$num") || die "rev-parse 失败"
  subject=$(git -C "$SRCGIT" log -1 --format=%s "$sha")
  log "构建 PR #$num $branch @ ${sha:0:7}（$subject）"

  rm -rf "$OUT"; mkdir -p "$OUT"
  git -C "$SRCGIT" archive "$sha" | tar -x -C "$OUT" || die "导出 PR #$num 失败"
  local x; for x in "${EXCLUDE[@]}"; do rm -rf "${OUT:?}/$x"; done
  [[ -f $OUT/index.html ]] || { echo "    跳过：分支里没有 index.html"; return 1; }

  local -a APPFILES
  mapfile -t APPFILES < <(cd "$OUT" && find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.html' \) \
      -not -path './assets/vendor/*' -not -path './node_modules/*' | sed 's#^\./##' | sort)

  # ---- 1) 找出所有存储名（localStorage / sessionStorage 键、IndexedDB 库名、Cache Storage 名） ----
  local KEYS=$WORK/keys-$num.txt
  (cd "$OUT" && perl -e '
    local $/; my $all = ""; for my $f (@ARGV) { open my $h, "<", $f or next; $all .= <$h> . "\n"; }
    my (%ids, %out);
    my $q = qr/([\x27"])([^\x27"\n]+)\1/;
    while ($all =~ /\b(?:local|session)Storage\s*\.\s*(?:getItem|setItem|removeItem)\(\s*$q/g) { $out{$2} = 1 }
    while ($all =~ /\bindexedDB\s*\.\s*(?:open|deleteDatabase)\(\s*$q/g) { $out{$2} = 1 }
    while ($all =~ /\bcaches\s*\.\s*(?:open|delete|has)\(\s*$q/g) { $out{$2} = 1 }
    # 用变量当名字：localStorage.getItem(KEY) / indexedDB.open(DB_NAME) / caches.open(CACHE)
    while ($all =~ /\b(?:(?:local|session)Storage\s*\.\s*(?:getItem|setItem|removeItem)|indexedDB\s*\.\s*(?:open|deleteDatabase)|caches\s*\.\s*(?:open|delete|has))\(\s*([A-Za-z_\$][\w\$]*)/g) { $ids{$1} = 1 }
    for my $id (keys %ids) { while ($all =~ /(?<![\w\$.])\Q$id\E\s*[=:]\s*$q/g) { $out{$2} = 1 } }
    # 常见命名的常量：KEY / STORAGE_KEY / DB_NAME / CACHE_NAME / storageKey ...
    while ($all =~ /\b([A-Z0-9_]*(?:KEY|DB_NAME|CACHE_NAME|CACHE)[A-Z0-9_]*|[a-z][A-Za-z0-9]*(?:Storage|Save|Store)Key)\s*[=:]\s*$q/g) { $out{$3} = 1 }
    print "$_\n" for sort keys %out;
  ' "${APPFILES[@]}") > "$KEYS" || die "查找存储名失败"

  # ---- 2) 改名：每个名字加 -preview 后缀，逐处记录 文件:行 旧 -> 新 ----
  : > "$REPORT"
  local key
  while IFS= read -r key; do
    [[ -n $key && $key != *"$SUFFIX"* ]] || continue
    (cd "$OUT" && KEY="$key" SFX="$SUFFIX" perl -i -pe '
      my $line = $_;
      while ($line =~ /([\x27"])\Q$ENV{KEY}\E\1/g) { print STDERR "$ARGV:$.: $1$ENV{KEY}$1 -> $1$ENV{KEY}$ENV{SFX}$1\n" }
      s/([\x27"])\Q$ENV{KEY}\E\1/$1$ENV{KEY}$ENV{SFX}$1/g;
      close ARGV if eof;
    ' "${APPFILES[@]}") 2>> "$REPORT"
  done < "$KEYS"
  # 派生键（例如 KEY + '-backup'）只记录，不用改：前缀已经带了 -preview
  (cd "$OUT" && perl -ne '
    print "（派生）$ARGV:$.: $1 + $2$3$2\n" while /\b([A-Z0-9_]*KEY[A-Z0-9_]*)\s*\+\s*([\x27"])([^\x27"\n]+)\2/g; close ARGV if eof
  ' "${APPFILES[@]}") >> "$REPORT" || true
  sed 's/^/    /' "$REPORT"
  # 提醒：属性方式访问 localStorage.foo / localStorage["x"] 不会被上面的改名覆盖（运行时保险垫片会兜底）
  (cd "$OUT" && perl -ne 'print "    注意 $ARGV:$.: $_" if /\b(?:local|session)Storage\s*(?:\[|\.(?!getItem|setItem|removeItem|clear|key\b|length\b)\w)/; close ARGV if eof' "${APPFILES[@]}") || true

  # ---- 3) 去掉 51.LA 统计 ----
  if [[ -f $OUT/stats.js ]]; then
    cat > "$OUT/stats.js" <<'JS'
// 预览版：已移除访问统计，这里只留空实现，游戏里调用 NaituanStats 不会有任何效果。
window.NaituanStats = { page: function () {}, enter: function () {}, leave: function () {} };
JS
  fi

  # ---- 4) 每个 HTML：noindex；index.html 另加保险垫片 + 顶部条 ----
  local branch_html; branch_html=$(printf '%s' "$branch" | esc)
  local SHIM BANNER
  SHIM=$(cat <<'SHIMEOF'
<script>/* naituan-preview 运行时保险：漏网的存储名也自动加 -preview 后缀；禁止注册 Service Worker */
(function(){var X='-preview';function k(n){n=String(n);return n.indexOf(X)>=0?n:n+X;}
try{var S=Storage.prototype,g=S.getItem,s=S.setItem,r=S.removeItem,kk=S.key;
S.getItem=function(n){return g.call(this,k(n));};S.setItem=function(n,v){return s.call(this,k(n),v);};
S.removeItem=function(n){return r.call(this,k(n));};
S.clear=function(){for(var i=this.length-1;i>=0;i--){var n=kk.call(this,i);if(n&&n.indexOf(X)>=0)r.call(this,n);}};}catch(e){}
try{if(window.indexedDB){var I=Object.getPrototypeOf(indexedDB),o=I.open,d=I.deleteDatabase;
I.open=function(n,v){return v===undefined?o.call(this,k(n)):o.call(this,k(n),v);};I.deleteDatabase=function(n){return d.call(this,k(n));};}}catch(e){}
try{if(window.caches){var C=Object.getPrototypeOf(caches);['open','delete','has'].forEach(function(m){var f=C[m];C[m]=function(n){return f.call(this,k(n));};});}}catch(e){}
try{if(navigator.serviceWorker){navigator.serviceWorker.register=function(){return Promise.reject(new Error('预览版不注册 Service Worker'));};}}catch(e){}
})();</script>
SHIMEOF
)
  BANNER="<div id=\"naituanPreviewBar\" aria-hidden=\"true\" style=\"position:fixed;top:0;left:0;right:0;z-index:2147483647;pointer-events:none;box-sizing:border-box;padding:env(safe-area-inset-top,0px) 8px 0;background:#c62828;color:#fff;font:600 12px/18px -apple-system,system-ui,'PingFang SC',sans-serif;text-align:center;letter-spacing:.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;box-shadow:0 1px 3px rgba(0,0,0,.25)\">预览版 · $branch_html</div>"
  local h
  for h in "${APPFILES[@]}"; do
    [[ $h == *.html ]] || continue
    perl -0777 -pi -e '
      unless (/<meta\s+name=["\x27]robots["\x27]/i) {
        s/(<meta\s+charset=[^>]*>)/$1\n<meta name="robots" content="noindex">/i
          or s/(<head[^>]*>)/$1\n<meta name="robots" content="noindex">/i;
      }' "$OUT/$h"
  done
  SHIM="$SHIM" BANNER="$BANNER" BR="$branch" perl -0777 -pi -e '
    s/(<meta\s+name="robots"[^>]*>)/$1\n$ENV{SHIM}/i;
    s/^[^\n]*Anonymous visit statistics[^\n]*-->\n//mg;
    s/^[^\n]*window\.LA\s*=[^\n]*\n//mg;
    s/^[^\n]*<script[^>]*51la[^>]*>\s*<\/script>[^\n]*\n//mgi;
    s/<title>([^<]*)<\/title>/<title>$1（预览版 · $ENV{BR}）<\/title>/i;
    s/(apple-mobile-web-app-title"\s+content=")([^"]*)"/$1$2·预览"/i;
    s/<\/body>/$ENV{BANNER}\n<\/body>/i;
  ' "$OUT/index.html"

  # ---- 5) manifest 只覆盖预览目录；Service Worker 文件换成自注销空壳 ----
  local m sw
  for m in "$OUT"/*.webmanifest "$OUT"/manifest.json; do
    [[ -f $m ]] || continue
    BR="$branch" node -e '
      const fs=require("fs"),f=process.argv[1],j=JSON.parse(fs.readFileSync(f,"utf8"));
      j.start_url="."; j.scope=".";
      if(j.name) j.name+="（预览版 · "+process.env.BR+"）"; if(j.short_name) j.short_name+="·预览";
      fs.writeFileSync(f, JSON.stringify(j,null,2)+"\n");' "$m"
  done
  for sw in "$OUT"/sw.js "$OUT"/service-worker.js; do
    [[ -f $sw ]] || continue
    echo "self.addEventListener('install',()=>self.skipWaiting());self.addEventListener('activate',()=>self.registration.unregister());" > "$sw"
    echo "    $(basename "$sw") 已换成自注销空壳"
  done

  # ---- 6) 自检 ----
  grep -q 'naituan-preview 运行时保险' "$OUT/index.html" || die "保险垫片没插进 index.html"
  grep -q naituanPreviewBar "$OUT/index.html" || die "顶部条没插进 index.html"
  while IFS= read -r key; do
    [[ -n $key && $key != *"$SUFFIX"* ]] || continue
    if (cd "$OUT" && KEY="$key" perl -ne 'if (/([\x27"])\Q$ENV{KEY}\E\1/) { print "    残留 $ARGV:$.\n"; $f=1 } close ARGV if eof; END { exit($f?0:1) }' "${APPFILES[@]}"); then
      die "存储名 $key 仍有没加后缀的地方"
    fi
  done < "$KEYS"
  if grep -rIil -e '51\.la' -e '51la' "$OUT" ; then die "副本里还有 51.LA 相关内容（见上面的文件）"; fi

  {
    echo "branch=$branch"
    echo "pr=$num"
    echo "title=$title"
    echo "commit=$sha"
    echo "subject=$subject"
    echo "builder=$BUILDER"
    echo "built=$(TZ=America/Los_Angeles date '+%Y-%m-%d %H:%M') PT"
  } > "$OUT/preview-info.txt"
  { echo "# 存储名改动（文件:行 旧 -> 新）"; cat "$REPORT"; } > "$OUT/preview-storage-keys.txt"

  rm -rf "${ROOT:?}/$dir"
  mv "$OUT" "$ROOT/$dir"
}

# ---------------------------------------------------------------------------
log "读取 $SRC_REPO 打开中的 PR"
PRS=$WORK/prs.tsv
gh api --paginate "repos/$SRC_REPO/pulls?state=open&per_page=100" \
  --jq '.[] | [.number, .head.ref, .head.sha, (.head.repo.full_name // ""), .title] | @tsv' > "$PRS"

declare -A WANT=()
changed=0
while IFS=$'\t' read -r num branch sha headrepo title; do
  [[ -n $num ]] || continue
  if [[ $headrepo != "$SRC_REPO" ]]; then
    echo "    跳过 PR #$num：来自其他仓库（$headrepo），为安全起见不做预览"; continue
  fi
  dir=$(dirname_for "$branch")
  if [[ -z $dir || $RESERVED == *" $dir "* ]]; then echo "    跳过 PR #$num：分支名 $branch 不能当目录名"; continue; fi
  if [[ -n ${WANT[$dir]:-} ]]; then echo "    跳过 PR #$num：目录 $dir 已被 PR #${WANT[$dir]} 占用"; continue; fi
  WANT[$dir]=$num
  info="$ROOT/$dir/preview-info.txt"
  if [[ $FORCE != 1 && -f $info && $(info_get "$info" commit) == "$sha" && $(info_get "$info" builder) == "$BUILDER" ]]; then
    if [[ $(info_get "$info" title) != "$title" ]]; then
      TITLE="$title" perl -pi -e 's/^title=.*/title=$ENV{TITLE}/' "$info"; changed=1
    fi
    echo "    PR #$num $branch 没变（${sha:0:7}），不用重建"
    continue
  fi
  if build_one "$num" "$branch" "$title" "$dir"; then changed=1; else unset 'WANT[$dir]'; fi
done < "$PRS"

# 清理：PR 已不再打开的预览目录
for info in "$ROOT"/*/preview-info.txt; do
  [[ -f $info ]] || continue
  d=$(basename "$(dirname "$info")")
  if [[ -z ${WANT[$d]:-} ]]; then
    log "删除预览 $d（PR #$(info_get "$info" pr) 已关闭/合并或分支已不存在）"
    rm -rf "${ROOT:?}/$d"; changed=1
  fi
done

# ---------------------------------------------------------------------------
touch "$ROOT/.nojekyll"
printf 'User-agent: *\nDisallow: /\n' > "$ROOT/robots.txt"
{
  cat <<HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="robots" content="noindex">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>奶团小屋 · 分支预览</title>
<style>
body{font:16px/1.6 -apple-system,system-ui,"PingFang SC","Noto Sans SC",sans-serif;max-width:640px;margin:0 auto;padding:20px;color:#3b2f2a;background:#f3ebde}
ul{padding:0}li{margin:12px 0;padding:10px 12px;background:#fffaf2;border-radius:10px;list-style:none}
a{color:#b05a2c}li>a{font-weight:600;font-size:18px}small{color:#7a6a60;display:block}
</style>
</head>
<body>
<h1>奶团小屋 · 分支预览</h1>
<p>这里是还没合并的改动的试玩版，<b>不是正式版</b>。预览里的存档和正式版完全分开，随便玩不会影响正式存档。</p>
<p>正式版：<a href="$LIVE_URL">$LIVE_URL</a></p>
<h2>可以试玩的预览</h2>
<ul>
HTML
  n=0
  for info in "$ROOT"/*/preview-info.txt; do
    [[ -f $info ]] || continue
    n=$((n+1))
    d=$(basename "$(dirname "$info")")
    b=$(info_get "$info" branch | esc); p=$(info_get "$info" pr); t=$(info_get "$info" title | esc)
    c=$(info_get "$info" commit | cut -c1-7); when=$(info_get "$info" built | esc)
    echo "<li><a href=\"./$d/\">$b</a>"
    echo "<small><a href=\"$SRC_URL/pull/$p\">PR #$p</a> $t</small>"
    echo "<small>提交 $c · 更新于 $when</small></li>"
  done
  (( n )) || echo "<li>现在没有打开中的 PR，所以没有预览。</li>"
  cat <<'HTML'
</ul>
<p><small>每 10 分钟左右自动检查一次：PR 有新提交会自动更新，PR 合并或关闭后预览会自动删除。</small></p>
</body>
</html>
HTML
} > "$ROOT/index.html"

log "完成（有构建/删除：$changed）"
