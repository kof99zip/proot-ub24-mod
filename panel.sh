#!/bin/sh
# ============================================================
# browser-panel 容器启动脚本（不依赖 systemd / OpenRC）
#
# 适用于 Pterodactyl + proot 这类没有 init 系统的容器环境。
# 一次搞定: 加载环境变量 -> 起 Xvfb -> 起面板。
#
# 用法:
#   sh panel.sh            # 启动(默认)
#   sh panel.sh start
#   sh panel.sh stop
#   sh panel.sh restart
#   sh panel.sh status
#   sh panel.sh logs       # 跟踪面板日志
#
# 为什么必须加载 .env.panel:
#   config.js 通过 process.env 读取 BROWSER_WORK_DIR / BROWSER_HOME / BROWSER_DISPLAY,
#   读不到就退回 /home/<user>/browser-work。容器里 /home 是只读 overlay,
#   直接 node server/index.js 会报 EACCES。systemd 能用 EnvironmentFile= 解决,
#   容器里没有 systemd, 只能自己 source。
# ============================================================

APP="${PANEL_ROOT:-/opt/browser-panel}"
ENV_FILE="${PANEL_ENV:-$APP/.env.panel}"
LOG_DIR="$APP/logs"

# ---------- 加载环境变量 ----------
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
else
  echo "[BP] 警告: 找不到 $ENV_FILE, 将使用默认路径(容器里通常会失败)"
fi

PORT="${PORT:-3210}"
HOST="${HOST:-0.0.0.0}"
# BROWSER_DISPLAY 形如 :1 或 :1.0; Xvfb 只认 :1
DISP_RAW="${BROWSER_DISPLAY:-:1}"
DISP_NUM="${DISP_RAW%%.*}"          # :1.0 -> :1
export DISPLAY="$DISP_RAW"

# Node 查找顺序：显式指定 > proot-ub24 的 portable 路径 > /usr/bin > PATH
# Ubuntu 24.04 上 node 由 stack.sh 装成 portable（/opt/node22），
# /usr/bin/node 可能不存在，或者是个旧版本。
NODE_BIN="${NODE_BIN:-}"
if [ -z "$NODE_BIN" ]; then
  for c in /opt/node22/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$c" ] && NODE_BIN="$c" && break
  done
fi
[ -z "$NODE_BIN" ] && NODE_BIN="$(command -v node)"
[ -n "$NODE_BIN" ] || { echo "[BP] 找不到 node，请先跑 ins-ub24.sh"; exit 1; }

# ---------- 子命令 ----------
do_status() {
  echo "--- 面板进程 ---"
  pgrep -af "node server/index.js" 2>/dev/null || echo "  (未运行)"
  echo "--- 监听 ---"
  (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep ":$PORT" || echo "  (端口 $PORT 未监听)"
  echo "--- Xvfb ---"
  pgrep -af "Xvfb $DISP_NUM" 2>/dev/null || echo "  (未运行)"
  echo "--- 工作区 ---"
  echo "  BROWSER_WORK_DIR=${BROWSER_WORK_DIR:-<未设置>}"
  if [ -n "$BROWSER_WORK_DIR" ]; then
    if touch "$BROWSER_WORK_DIR/.wp" 2>/dev/null; then
      rm -f "$BROWSER_WORK_DIR/.wp"
      ls -ldn "$BROWSER_WORK_DIR" 2>/dev/null | sed 's/^/  /'
    else
      echo "  ⚠ 该目录不可写 —— 容器里请指向可写卷, 例如 /home/container/xxx"
    fi
  fi
}

do_stop() {
  echo "[BP] 停止面板..."
  pkill -f "node server/index.js" 2>/dev/null && sleep 2
  pkill -f "Xvfb $DISP_NUM" 2>/dev/null && sleep 1
  echo "[BP] 已停止"
}

do_start() {
  mkdir -p "$LOG_DIR" 2>/dev/null

  # 清理旧进程
  pkill -f "node server/index.js" 2>/dev/null && sleep 2
  pkill -f "Xvfb $DISP_NUM" 2>/dev/null && sleep 1

  # Xvfb
  XVFB_BIN="${XVFB_BIN:-/usr/bin/Xvfb}"
  [ -x "$XVFB_BIN" ] || XVFB_BIN="$(command -v Xvfb)"
  echo "[BP] 启动 Xvfb ($DISP_NUM)..."
  # setsid: 必须完全脱离当前会话。容器/tty 里 `nohup ... &` 起的进程
  # 会在父 shell 退出时被连带杀掉（日志里没有任何报错，进程就是凭空消失）。
  setsid "$XVFB_BIN" "$DISP_NUM" -screen 0 1440x900x24 -ac +extension GLX +render -noreset \
    >>"$LOG_DIR/xvfb.log" 2>&1 < /dev/null &
  sleep 2

  # 面板
  echo "[BP] 启动面板..."
  cd "$APP" || { echo "[BP] 找不到 $APP"; exit 1; }
  NODE_ENV=production setsid "$NODE_BIN" server/index.js \
    >>"$LOG_DIR/panel.log" 2>&1 < /dev/null &

  sleep 8
  if pgrep -f "node server/index.js" >/dev/null 2>&1; then
    echo "[BP] 已启动 -> http://$HOST:$PORT"
    echo "[BP] 日志: $LOG_DIR/panel.log"
  else
    echo "[BP] 启动失败, 最后 10 行日志:"
    tail -10 "$LOG_DIR/panel.log" 2>/dev/null
    exit 1
  fi
}

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  logs)    tail -f "$LOG_DIR/panel.log" ;;
  *)       echo "用法: $0 {start|stop|restart|status|logs}"; exit 1 ;;
esac
