#!/usr/bin/env bash
# 大管家 · 同步备份脚本（本地备份 + GitHub 推送 双操作）
#
# 触发命令：对大管家说「同步大管家备份」
# 手动执行：bash 同步大管家备份.sh [--log "变更说明"]
#
# 执行两个操作：
#   操作1 —— 备份到 桌面/leipenglongworkbuddy/
#   操作2 —— 推送到 GitHub 仓库 leipenglong/agent-workbuddy 的 agents/ 目录
#
# 已与用户确认的规则：
#   - 专家包备份完整包（plugin.json / agents / skills / avatars / README）
#   - 删除采用软删除：源目录移入 大管家/_archive/，备份目录保留
#   - 连接器配置令牌脱敏为 <TOKEN>

set -u

BASE="C:/Users/Administrator/Desktop/leipenglongworkbuddy"
EXPERTS_SRC="C:/Users/Administrator/.workbuddy/plugins/marketplaces/my-experts/plugins"
DESKTOP="C:/Users/Administrator/Desktop"
LOGNOTE=""
[ "${1:-}" = "--log" ] && LOGNOTE="${2:-}"

TS=$(date "+%Y-%m-%d %H:%M:%S")
FAIL=0

echo "════ 大管家 · 同步备份 ════"
echo "时间：$TS"
[ -n "$LOGNOTE" ] && echo "说明：$LOGNOTE"
echo

# ============ 操作 1：本地备份 ============
echo "━━━ 操作 1：本地备份 ━━━"

# 1.1 专家包
echo "【1.1】专家团 / 专家"
mkdir -p "$BASE/专家团和专家"
if [ -d "$EXPERTS_SRC" ]; then
  for d in "$EXPERTS_SRC"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    rm -rf "${BASE}/专家团和专家/$name"
    mkdir -p "${BASE}/专家团和专家/$name"
    cp -r "$d." "${BASE}/专家团和专家/$name/"
    echo "  ✅ $name"
  done
fi

# 1.2 技能
echo
echo "【1.2】技能（Skill）"
mkdir -p "$BASE/技能"
for sdir in "$EXPERTS_SRC"/*/skills/*/; do
  [ -d "$sdir" ] || continue
  sname=$(basename "$sdir")
  rm -rf "$BASE/技能/$sname"
  mkdir -p "$BASE/技能/$sname"
  cp -r "$sdir." "$BASE/技能/$sname/"
  echo "  ✅ $sname"
done

# 1.3 管家资料
echo
echo "【1.3】管家资料"
mkdir -p "$BASE/大管家/_archive"
for f in "大管家.html" "大管家角色设定.md"; do
  if [ -f "$DESKTOP/$f" ]; then
    cp "$DESKTOP/$f" "$BASE/大管家/$f"
    echo "  ✅ $f"
  fi
done

# 1.4 连接器配置（脱敏）
echo
echo "【1.4】连接器配置（令牌脱敏）"
mkdir -p "$BASE/连接器"
CREDS="C:/Users/Administrator/.workbuddy/git-credentials"
[ -f "$CREDS" ] && sed 's|https://[^:]*:\([^@]*\)@|https://leipenglong:<TOKEN>@|' "$CREDS" > "$BASE/连接器/git-credentials.template" && echo "  ✅ git-credentials.template"
MCPCFG="C:/Users/Administrator/.workbuddy/plugins/marketplaces/workbuddy-connector-plugins-official/connectors/github/mcp.json"
[ -f "$MCPCFG" ] && cp "$MCPCFG" "$BASE/连接器/github-mcp.json" && echo "  ✅ github-mcp.json"
git config --global --list > "$BASE/连接器/gitconfig-global.txt" 2>/dev/null && echo "  ✅ gitconfig-global.txt"
git config --show-origin --get-all credential.helper > "$BASE/连接器/credential-helper.txt" 2>/dev/null && echo "  ✅ credential-helper.txt"

# ============ 操作 2：GitHub 推送 ============
echo
echo "━━━ 操作 2：GitHub 推送 ━━━"
REPO="https://github.com/leipenglong/agent-workbuddy.git"
WORK="C:/Users/Administrator/.workbuddy/repos/agent-workbuddy"
GITOK=0

if ! command -v git >/dev/null 2>&1; then
  echo "  ⚠️ 未找到 git，跳过推送"
  FAIL=1
elif [ ! -f "$CREDS" ]; then
  echo "  ⚠️ 无 git 凭据，跳过推送"
  FAIL=1
else
  # 拉取或克隆
  if [ -d "$WORK/.git" ]; then
    git -C "$WORK" -c http.sslVerify=false -c http.version=HTTP/1.1 pull --ff-only origin main >/dev/null 2>&1 \
      || { git -C "$WORK" -c http.sslVerify=false -c http.version=HTTP/1.1 fetch origin main >/dev/null 2>&1 && git -C "$WORK" reset --hard origin/main >/dev/null 2>&1; }
  else
    rm -rf "$WORK"
    git -c http.sslVerify=false -c http.version=HTTP/1.1 clone "$REPO" "$WORK" >/dev/null 2>&1
  fi

  if [ ! -d "$WORK/.git" ]; then
    echo "  ⚠️ 仓库克隆失败，跳过推送"
    FAIL=1
  else
    git -C "$WORK" config user.name "leipenglong"
    git -C "$WORK" config user.email "leipenglong@users.noreply.github.com"

    # 同步专家包到 agents/<专家名>/（镜像：先清空再拷，确保已删除文件被带走）
    for d in "$EXPERTS_SRC"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      rm -rf "$WORK/agents/$name"
      mkdir -p "$WORK/agents/$name"
      cp -r "$d." "$WORK/agents/$name/"
      rm -f "$WORK/agents/$name/.gitkeep"
    done

    # 同步管家资料到 管家/
    mkdir -p "$WORK/管家"
    for f in "大管家.html" "大管家角色设定.md" "管家工作手册.md" "变更日志.md" "同步大管家备份.sh"; do
      [ -f "$BASE/大管家/$f" ] && cp "$BASE/大管家/$f" "$WORK/管家/$f"
    done

    # 同步备份体系说明到 备份说明/
    mkdir -p "$WORK/备份说明"
    rm -rf "$WORK/备份说明/技能"
    [ -d "$BASE/技能" ] && cp -r "$BASE/技能" "$WORK/备份说明/技能" 2>/dev/null
    [ -f "$BASE/连接器/配置说明.md" ] && cp "$BASE/连接器/配置说明.md" "$WORK/备份说明/" 2>/dev/null

    git -C "$WORK" add -A
    if git -C "$WORK" diff --cached --quiet; then
      echo "  ℹ️ 无变更，无需推送"
    else
      MSG="chore(butler): 同步大管家备份 ${TS}"
      [ -n "$LOGNOTE" ] && MSG="chore(butler): 同步大管家备份 ${TS} —— ${LOGNOTE}"
      git -C "$WORK" commit -m "$MSG" >/dev/null 2>&1
      if git -C "$WORK" -c http.sslVerify=false -c http.version=HTTP/1.1 push origin main >/dev/null 2>&1; then
        echo "  ✅ 已推送到 GitHub main 分支"
        git -C "$WORK" log --oneline -1 | sed 's/^/     /'
        GITOK=1
      else
        echo "  ❌ 推送失败（凭据或网络问题）"
        FAIL=1
      fi
    fi
  fi
fi

# ============ 校验 ============
echo
echo "━━━ 校验 ━━━"
if grep -rqE "gh[po]_[A-Za-z0-9]{20,}" "$BASE" 2>/dev/null; then
  echo "  ❌ 发现明文令牌："
  grep -rlE "gh[po]_[A-Za-z0-9]{20,}" "$BASE" | sed 's/^/     /'
  FAIL=1
else
  echo "  ✅ 无明文令牌泄漏"
fi
for d in "$EXPERTS_SRC"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  s=$(find "$d" -type f | wc -l)
  b=$(find "$BASE/专家团和专家/$name" -type f 2>/dev/null | wc -l)
  if [ "$s" = "$b" ]; then echo "  ✅ $name 文件数一致（$s）"; else echo "  ❌ $name 源 $s / 备份 $b"; FAIL=1; fi
done
for f in "大管家.html" "大管家角色设定.md"; do
  if [ -f "$BASE/大管家/$f" ] && [ -f "$DESKTOP/$f" ]; then
    a=$(sha1sum "$BASE/大管家/$f" | cut -d' ' -f1); b=$(sha1sum "$DESKTOP/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  ✅ $f 与桌面源一致" || { echo "  ❌ $f 与桌面源不一致"; FAIL=1; }
  fi
done

# ============ 变更日志 ============
if [ -n "$LOGNOTE" ]; then
  cat >> "$BASE/大管家/变更日志.md" <<EOF

### 同步大管家备份：$TS

| 项 | 内容 |
|---|---|
| 动作 | 双操作同步（本地备份 + GitHub 推送） |
| 说明 | $LOGNOTE |
| 本地备份 | 专家团/专家、技能、管家资料、连接器配置（脱敏） |
| GitHub | $([ "$GITOK" = "1" ] && echo "已推送 main 分支" || echo "未推送（无变更或推送失败）") |
| 校验 | $([ "$FAIL" = "0" ] && echo "全部通过" || echo "存在失败项，见上方输出") |
EOF
  echo
  echo "  ✅ 变更日志已追加"
fi

echo
if [ "$FAIL" = "0" ]; then echo "✅ 同步完成，两个操作均已执行"; else echo "⚠️ 同步完成，但存在失败项"; fi
exit $FAIL
