#!/usr/bin/env bash
# ============================================================================
# 大管家 · 自动备份脚本
# ----------------------------------------------------------------------------
# 监控目录：C:\Users\Administrator\Desktop\leipenglongworkbuddy
# 远端：    https://github.com/leipenglong/leipenglongworkbuddy.git (main)
#
# 执行逻辑（严格按规则）：
#   ① git status 扫描监控目录
#   ② 无变更 → 直接结束，不提交、不产生空 commit
#   ③ 有变更 → git add . → commit "auto-backup: YYYY-MM-DD HH:MM" → push origin main
#   ④ 记录备份日志（成功/失败、时间、变更文件清单）
#   ⑤ 异常兜底：push 失败重试 2 次；重试失败写告警日志，不反复推送
#
# 限制保护：
#   - 忽略项见 .gitignore（.git、缓存、临时、草稿、大二进制）
#   - 防刷屏：最短提交间隔 10 分钟，期内变动合并为一次提交
#   - 禁止 git push --force
#
# 用法：
#   bash 大管家备份.sh              # 正常备份
#   bash 大管家备份.sh --force-run  # 忽略 10 分钟节流（手动强制）
#   bash 大管家备份.sh --check      # 只检测不提交（dry-run）
# ============================================================================

set -u

# 统一 UTF-8 输出，避免被 PowerShell / 计划任务按 ANSI 读取时乱码
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONIOENCODING=utf-8

BASE="C:/Users/Administrator/Desktop/leipenglongworkbuddy/leipenglongworkbuddy"
REMOTE="https://github.com/leipenglong/leipenglongworkbuddy.git"
BRANCH="main"
MIN_INTERVAL=600           # 最短提交间隔：10 分钟 = 600 秒
MAX_RETRY=2                 # push 失败重试次数
LOG_DIR="$BASE/大管家/备份日志"
LOG_FILE="$LOG_DIR/备份日志.log"
ALERT_FILE="$LOG_DIR/告警.log"
STATE_FILE="$BASE/.大管家/last_commit_ts"

FORCE_RUN=0
CHECK_ONLY=0
[ "${1:-}" = "--force-run" ] && FORCE_RUN=1
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

cd "$BASE" 2>/dev/null || { echo "❌ 监控目录不存在: $BASE"; exit 1; }
mkdir -p "$LOG_DIR" "$BASE/.大管家"

NOW=$(date "+%Y-%m-%d %H:%M:%S")
TS=$(date "+%s")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M")

log() {
  local level="$1"; shift
  local line="[$NOW] [$level] $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE" 2>/dev/null
}

alert() {
  local line="[$NOW] [ALERT] $*"
  echo "$line"
  echo "$line" >> "$ALERT_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ① 扫描：git status 判断是否有变更
# ---------------------------------------------------------------------------
CHANGED=$(git status --porcelain 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ')
CHANGED_FILES=$(git status --porcelain 2>/dev/null | grep -v '^$')

if [ "$CHANGED" -eq 0 ]; then
  log INFO "无变更，跳过（不提交、不产生空 commit）"
  exit 0
fi

log INFO "检测到 $CHANGED 个变更项"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "--- 变更清单（dry-run）---"
  echo "$CHANGED_FILES"
  exit 0
fi

# ---------------------------------------------------------------------------
# 防高频刷屏：最短提交间隔 10 分钟
# ---------------------------------------------------------------------------
if [ "$FORCE_RUN" = "0" ] && [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null | tr -d ' ')
  if [ -n "$LAST" ] && [ $((TS - LAST)) -lt $MIN_INTERVAL ]; then
    REMAIN=$(( MIN_INTERVAL - (TS - LAST) ))
    log INFO "距上次提交不足 10 分钟（还剩 ${REMAIN} 秒），本次变动合并到下次提交"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# ③ 提交
# ---------------------------------------------------------------------------
git add . 2>/dev/null
STAGED=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')

if [ "$STAGED" -eq 0 ]; then
  log INFO "暂存区为空，跳过"
  exit 0
fi

# 变更文件清单（用于日志）
FILE_LIST=$(git diff --cached --name-only 2>/dev/null)

if git commit -m "auto-backup: ${TS_HUMAN}" >/dev/null 2>&1; then
  COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null)
  log INFO "已提交 auto-backup: ${TS_HUMAN} (${COMMIT_SHA})，共 $STAGED 个文件"
else
  log ERROR "commit 失败"
  alert "commit 失败，变更未提交"
  exit 1
fi

# 记录提交时间（节流依据）
date "+%s" > "$STATE_FILE" 2>/dev/null

# ---------------------------------------------------------------------------
# ③④ push + 异常兜底（重试 2 次）
# ---------------------------------------------------------------------------
PUSH_OK=0
ATTEMPT=0

while [ "$ATTEMPT" -le "$MAX_RETRY" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  if git -c http.sslVerify=false -c http.version=HTTP/1.1 push origin "$BRANCH:$BRANCH" >/dev/null 2>&1; then
    PUSH_OK=1
    log INFO "push 成功（第 ${ATTEMPT} 次尝试）"
    break
  fi
  if [ "$ATTEMPT" -le "$MAX_RETRY" ]; then
    log WARN "push 失败（第 ${ATTEMPT}/${MAX_RETRY} 次），等待后重试"
    sleep 5
  fi
done

if [ "$PUSH_OK" = "1" ]; then
  log OK "备份完成 | commit=${COMMIT_SHA} | 文件数=${STAGED} | 变更清单："
  echo "$FILE_LIST" | while read -r f; do [ -n "$f" ] && echo "    - $f" >> "$LOG_FILE"; done
  exit 0
fi

# 重试仍失败 → 告警，不继续推送
log ERROR "push 重试 $MAX_RETRY 次后仍失败"
alert "push 重试 ${MAX_RETRY} 次后仍失败 | commit=${COMMIT_SHA} | 分支=${BRANCH} | 变更文件数=${STAGED} —— 本地提交已保留，未强制推送，请检查网络或手动处理"
echo "--- 变更文件清单 ---" >> "$ALERT_FILE"
echo "$FILE_LIST" >> "$ALERT_FILE"
exit 1
