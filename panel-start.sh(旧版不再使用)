#!/bin/sh
# ============================================================
# browser-panel 启动器（容器/proot 环境）
#
# 为什么必须有这个脚本:
#
# config.js 通过 process.env 读取 BROWSER_WORK_DIR / BROWSER_HOME 等变量,
# 读不到就退回 /home/<user>/browser-work。但在容器里 /home 是只读 overlay,
# 直接 `node server/index.js` 会退回只读路径并报 EACCES。
#
# 所以必须先 source .env.panel 把变量灌进环境, 再启动 node。
# systemd 能干这事(EnvironmentFile=), 但容器里通常没有 systemd。
# ============================================================

cd /opt/browser-panel || exit 1

set -a
[ -f .env.panel ] && . ./.env.panel
set +a

exec node server/index.js
