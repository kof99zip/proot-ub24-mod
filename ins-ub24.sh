#!/bin/bash
# ============================================================
# browser-panel 依赖安装器 — Ubuntu 24.04 / proot
#
# 参照 proot-ub24 的 stack.sh，改动集中在:
#   1. 增加路径可写性实测（proot 里权限位不可信，chmod 会被伪造）
#   2. 检测到工作区不可写时给出可执行的备选方案
#   3. 不再强制 chown 工作区（proot 下 chown 可能把目录永久锁死）
#
# 用法:  bash ins-ub24.sh
# ============================================================

set -e

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

APP="${PANEL_ROOT:-/opt/browser-panel}"
ENV_FILE="${PANEL_ENV:-$APP/.env.panel}"

BROWSER_USER="${BROWSER_USER:-root}"
BROWSER_HOME="${BROWSER_HOME:-/home/$BROWSER_USER}"
BROWSER_WORK="${BROWSER_WORK_DIR:-$BROWSER_HOME/browser-work}"
CHROME_DIR="${CHROME_DIR:-/opt/chrome}"
CHROME_PATH="$CHROME_DIR/chrome"
NODE_DIR="${NODE_DIR:-/opt/node22}"
NODE_VERSION="${NODE_VERSION:-v22.19.0}"
DISPLAY_NUM="${BROWSER_DISPLAY:-:1}"
SCREEN="${SCREEN:-1440x900x24}"

log()  { echo "[+] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请在 proot 内以 root 运行"
grep -qi ubuntu /etc/os-release 2>/dev/null || warn "看起来不是 Ubuntu"

echo
echo "============================================"
echo " browser-panel 依赖安装 (Ubuntu 24.04/proot)"
echo "============================================"
echo

# ------------------------------------------------------------
# 1. 挡住 systemd —— proot 里它会被 apt 顺带装进来然后炸
# ------------------------------------------------------------
log "1/8 锁定 systemd 相关包..."
apt-mark hold systemd systemd-dev systemd-sysv udev \
  systemd-resolved systemd-timesyncd networkd-dispatcher \
  libpam-systemd 2>/dev/null || true

# 清掉 NodeSource 残留（它在 proot 里会拖 systemd 进来）
rm -f /etc/apt/sources.list.d/nodesource.list \
      /etc/apt/sources.list.d/node*.list \
      /etc/apt/keyrings/nodesource.gpg \
      /usr/share/keyrings/nodesource.gpg 2>/dev/null || true

# ------------------------------------------------------------
# 2. 基础包
# ------------------------------------------------------------
# proot 里 /etc/hosts 常常是空的, 会导致 localhost 解析失败(apt/pip/nginx 都可能受影响)。
# 注意只补不覆盖: 有些环境里 /etc/hosts 还有 IPv6 之类的条目。
if [ ! -s /etc/hosts ]; then
  printf '127.0.0.1 localhost\n127.0.0.1 %s\n' "$(hostname 2>/dev/null || echo localhost)" > /etc/hosts
  log "/etc/hosts 已创建 (127.0.0.1 localhost)"
elif ! grep -q 'localhost' /etc/hosts 2>/dev/null; then
  printf '127.0.0.1 localhost\n127.0.0.1 %s\n' "$(hostname 2>/dev/null || echo localhost)" >> /etc/hosts
  log "/etc/hosts 补上了 localhost"
fi

# proot 陷阱: /var/cache/apt/archives/partial 的真实属主是 uid 42(_apt)、mode 700,
# 而 proot 里 `id` 显示的 uid 0 是假的 —— 真实 uid 不是 42, 连 root 也写不进去,
# 报 "Could not open file .../partial/xxx.deb - open (13: Permission denied)"。
# 而且 chmod 在 proot 下会被伪造(返回成功、mode 不变), 硬改权限没用。
# 对策: 把下载缓存整个指到可写的新目录。
APT_CACHE_OK=1
if ! touch /var/cache/apt/archives/partial/.wtest 2>/dev/null; then
  APT_CACHE_OK=0
fi
rm -f /var/cache/apt/archives/partial/.wtest 2>/dev/null || true

if [ "$APT_CACHE_OK" = "0" ]; then
  warn "apt 下载缓存目录不可写, 重定向到 /var/cache/apt/archives2"
  mkdir -p /var/cache/apt/archives2/partial
  echo 'Dir::Cache::archives "/var/cache/apt/archives2";' \
    > /etc/apt/apt.conf.d/99proot-cache
  if touch /var/cache/apt/archives2/partial/.wtest 2>/dev/null; then
    rm -f /var/cache/apt/archives2/partial/.wtest
    log "apt 缓存已重定向, 且新目录实测可写"
  else
    die "新缓存目录也不可写, 请手动指定一个可写路径"
  fi
fi

# apt 的 _apt 沙箱在 proot 下也会挡路(降权后写不进任何地方)
if ! grep -rqs 'APT::Sandbox::User' /etc/apt/apt.conf.d/ 2>/dev/null; then
  echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99proot-nosandbox
  log "已关闭 apt 的 _apt 沙箱"
fi

log "2/8 apt update..."
apt-get update -qq

log "3/8 安装基础包..."
apt-get install -y --no-install-recommends \
    ca-certificates curl wget unzip xz-utils nano sudo \
    python3 python3-pip python3-dev python3-setuptools python3-wheel \
    build-essential procps \
    xvfb xauth xdotool \
    libnss3 libnspr4 libgbm1 libdrm2 libx11-xcb1 libxcb-dri3-0 \
    libxcomposite1 libxdamage1 libxrandr2 libxfixes3 libxi6 libxcursor1 \
    libpango-1.0-0 libcups2t64 libatk1.0-0t64 libatk-bridge2.0-0t64 \
    libatspi2.0-0t64 libgtk-3-0t64 libgdk-pixbuf-2.0-0 \
    libcairo2 libcairo-gobject2 libpangocairo-1.0-0 \
    libfontconfig1 libasound2t64 libxkbcommon0 libxshmfence1 \
    fonts-liberation fonts-noto-cjk fonts-noto-color-emoji

# ------------------------------------------------------------
# 4. systemd 没被顺带装进来？
# ------------------------------------------------------------
for p in systemd systemd-dev udev; do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
    warn "$p 被装进来了 —— proot 里可能出问题，请检查"
  fi
done

# ------------------------------------------------------------
# 5. Node 22（portable，不走 apt/NodeSource）
# ------------------------------------------------------------
log "4/8 安装 Node.js ${NODE_VERSION} (portable)..."
if [ -x "$NODE_DIR/bin/node" ]; then
  log "已存在，跳过"
else
  mkdir -p "$NODE_DIR"
  tmp="$(mktemp -d)"
  curl -fL --retry 5 --connect-timeout 20 -o "$tmp/node.tar.xz" \
    "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz"
  # 直接解到目标目录 —— 不要"先解压、再 cp"。
  # node 的 tarball 顶层目录是 1000:1000 且 mode 700; tar 默认保留归档属主,
  # proot 里真实 uid 不是 1000, 连读都读不了, cp 会报
  #   cp: cannot stat '.../node-vXX-linux-x64/.': Permission denied
  # --no-same-owner  让解出的文件归当前 uid
  # --strip-components=1  跳过那个 700 的顶层目录
  tar -xJf "$tmp/node.tar.xz" -C "$NODE_DIR" --strip-components=1 --no-same-owner
  chmod -R u+rwX,go+rX "$NODE_DIR"
  rm -rf "$tmp"
fi
ln -sf "$NODE_DIR/bin/node" /usr/local/bin/node
ln -sf "$NODE_DIR/bin/npm"  /usr/local/bin/npm
ln -sf "$NODE_DIR/bin/npx"  /usr/local/bin/npx
export PATH="$NODE_DIR/bin:$PATH"

# ------------------------------------------------------------
# 6. Chrome（Chrome for Testing portable）
#    Ubuntu 24.04 的 chromium-browser 是 snap 转接壳，容器里跑不了
# ------------------------------------------------------------
log "5/8 安装 Chrome (Chrome for Testing portable)..."
if [ -x "$CHROME_PATH" ]; then
  log "已存在，跳过"
else
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/ver.json" \
    "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
  ver="$(python3 -c "import json;print(json.load(open('$tmp/ver.json'))['channels']['Stable']['version'])")"
  log "Chrome 版本: $ver"
  curl -fL --retry 5 --connect-timeout 30 -o "$tmp/chrome.zip" \
    "https://storage.googleapis.com/chrome-for-testing-public/${ver}/linux64/chrome-linux64.zip"
  unzip -q "$tmp/chrome.zip" -d "$tmp"
  rm -rf "$CHROME_DIR"
  mv "$tmp/chrome-linux64" "$CHROME_DIR"
  rm -rf "$tmp"
fi
chmod +x "$CHROME_PATH"
ln -sf "$CHROME_PATH" /usr/local/bin/google-chrome

# ------------------------------------------------------------
# 7. Python 自动化栈（PEP 668 需要 --break-system-packages）
# ------------------------------------------------------------
log "6/8 安装 Python 自动化栈..."
REQ=""
for f in "$APP/requirements-dp.txt" "$APP/requirements-sb.txt"; do
  [ -f "$f" ] && REQ="$REQ $f"
done

# 先看关键包是不是已经齐了。齐了就整段跳过 ——
# 下面那条 pip 带 --ignore-installed，会强制重装全部依赖(几百 MB),
# 在已经能正常跑的环境上重装不但白费时间, 中途失败还会把环境搞坏。
# 实测踩过: 在已经跑通的面板上重跑安装, pip 这步是最大的风险来源。
PY_STACK_OK=1
for mod in DrissionPage selenium seleniumbase requests; do
  python3 -c "import $mod" 2>/dev/null || PY_STACK_OK=0
done

if [ "$PY_STACK_OK" = "1" ] && [ "${BP_FORCE_PIP:-0}" != "1" ]; then
  log "Python 自动化栈已就绪 (DrissionPage/selenium/seleniumbase/requests 均可导入), 跳过 pip"
  log "  需要强制重装时: BP_FORCE_PIP=1 bash ins-ub24.sh"
else
python3 -m pip install \
  --break-system-packages --ignore-installed --disable-pip-version-check \
  --no-cache-dir \
  $REQ \
  "requests>=2.31.0" "urllib3>=2.0.0" "Pillow>=10.0.0" \
  "DrissionPage>=4.1.0" "selenium>=4.20.0" "seleniumbase>=4.30.0" \
  "playwright>=1.40.0" \
  "pyrogram>=2.0.0" "TgCrypto>=1.2.0" \
  "SpeechRecognition>=3.10.0" "pydub>=0.25.0" "numpy>=1.24.0" \
  || warn "pip 安装失败 —— 如果之前装过, 可能仍然可用; 缺什么补什么"
fi

# ------------------------------------------------------------
# 7.5 SeleniumBase 兼容层 —— proot 下 chromedriver 收到 /session 就 SIGSEGV
#     (Chrome 本身没问题, DrissionPage 走纯 CDP 完全正常)
#     装好后 `from seleniumbase import SB` 自动走 DrissionPage 后端, 脚本无需改
# ------------------------------------------------------------
log "6.5/8 安装 SeleniumBase 兼容层 (DrissionPage 后端)..."
SHIM_DIR="$APP/shim/seleniumbase"
mkdir -p "$SHIM_DIR"
SHIM_SRC="$(cd "$(dirname "$0")" && pwd)/shim/seleniumbase/__init__.py"
if [ -f "$SHIM_SRC" ]; then
  cp "$SHIM_SRC" "$SHIM_DIR/__init__.py"
  log "兼容层已装: $SHIM_DIR/__init__.py"
else
  warn "找不到 $SHIM_SRC —— 请把 shim/ 目录和本脚本放一起再跑"
fi

# 让任何 python 进程都优先加载兼容层。
# 用 .pth 而不是 sitecustomize: sitecustomize 只会加载 sys.path 上第一个,
# 通常是 /usr/lib/python3.X/sitecustomize.py (Ubuntu 的 apport 钩子),
# 写在 dist-packages 里的会被静默屏蔽。.pth 每个 site 目录都会被处理, 不会被屏蔽。
PYSITE="$(python3 -c 'import site;print(site.getsitepackages()[0])' 2>/dev/null)"
if [ -n "$PYSITE" ] && [ -d "$PYSITE" ]; then
  cat >"$PYSITE/bp-shim.pth" <<EOF
import os,sys; sys.path.insert(0,"$APP/shim") if (os.path.isdir("$APP/shim") and not os.environ.get("BP_NO_SHIM")) else None
EOF
  log "已装 .pth: $PYSITE/bp-shim.pth"
  # 清掉早期版本误写的 sitecustomize（会被系统那个屏蔽，留着只会误导）
  rm -f "$PYSITE/sitecustomize.py" 2>/dev/null || true
else
  warn "找不到 site-packages 目录，兼容层可能不会被自动加载"
fi

# ------------------------------------------------------------
# 6.7 nginx（可选；proot 下需要修日志文件属主）
#     不需要就设 BP_NGINX=0 跳过
# ------------------------------------------------------------
if [ "${BP_NGINX:-1}" = "1" ]; then
  log "6.7/8 安装 nginx..."
  apt-get install -y nginx 2>/dev/null || warn "nginx 安装失败, 跳过"
  if command -v nginx >/dev/null 2>&1; then
    # proot 陷阱: nginx 的日志文件属主是 www-data(33)、mode 640,
    # 伪造的 root 写不进去 -> `nginx -t` 报 open() error.log Permission denied。
    # 目录本身可写, 删掉重建即可。
    if ! touch /var/log/nginx/error.log 2>/dev/null; then
      rm -f /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null
      touch /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null
      log "nginx 日志文件已重建（属主修正）"
    fi
    if nginx -t >/dev/null 2>&1; then
      log "nginx 配置检查通过"
    else
      warn "nginx 配置检查未通过（通常是上面那个日志属主问题）"
    fi
  fi
fi

# ------------------------------------------------------------
# 8. 工作区 —— 关键: 实测可写，不信权限位
# ------------------------------------------------------------
log "7/8 准备浏览器工作区..."
mkdir -p "$APP/logs" "$APP/pids" 2>/dev/null || true

if ! id "$BROWSER_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$BROWSER_HOME" --shell /bin/bash "$BROWSER_USER" 2>/dev/null || true
fi

# --- 挑一个真正可写的工作区 ---
# 不能只信默认值: proot 里 /home/<user> 常被真实 uid 1000 拥有, 我们(伪造的 root)
# 写不进去。而且 `set -e` 会让随后的 mkdir 直接终止脚本 —— 连下面的提示都看不到。
# 所以先探测父目录, 再决定用哪个路径。
probe_writable() {
  _parent="$(dirname "$1")"
  [ -d "$_parent" ] || return 1
  if touch "$_parent/.bp_wtest" 2>/dev/null; then
    rm -f "$_parent/.bp_wtest" 2>/dev/null
    return 0
  fi
  return 1
}

CHOSEN_WORK=""
for cand in "$BROWSER_WORK" /home/container/browser-work "$APP/browser-work" /root/browser-work /tmp/browser-work; do
  if probe_writable "$cand"; then
    CHOSEN_WORK="$cand"
    break
  fi
done

[ -n "$CHOSEN_WORK" ] || die "找不到可写的工作区, 请手动指定 BROWSER_WORK_DIR=/可写路径"

if [ "$CHOSEN_WORK" != "$BROWSER_WORK" ]; then
  warn "默认工作区不可写: $BROWSER_WORK"
  warn "  已自动改用:   $CHOSEN_WORK"
  BROWSER_WORK="$CHOSEN_WORK"
  BROWSER_HOME="$(dirname "$BROWSER_WORK")"
  BROWSER_USER_DATA_DIR="$BROWSER_WORK/persistent"
fi

mkdir -p "$BROWSER_WORK"/{persistent,profiles,screenshots,task-results,downloaded_files,assets,archived_files} 2>/dev/null || true

WRITABLE=0
if touch "$BROWSER_WORK/.wtest" 2>/dev/null; then
  rm -f "$BROWSER_WORK/.wtest"
  WRITABLE=1
fi

if [ "$WRITABLE" = "1" ]; then
  log "工作区可写: $BROWSER_WORK"
  # ⚠ proot 下**绝对不要** chown。
  # chown 之后目录属主变成真实 uid 1000(browser)，而 proot 里伪造的 root 不是 1000
  # —— 工作区会**永久不可写**：连 rm -rf 都删不掉(删除需要父目录写权限)，
  # 只能靠 `mv <dir> <dir>-poisoned` 挪走再重建。实测踩过，见 README 问题 3。
  # 这些容器里面板本来就以 root 跑，chown 没有任何收益。需要时设 BP_CHOWN=1 强制。
  if [ "${BP_CHOWN:-0}" = "1" ]; then
    chown -R "$BROWSER_USER:$BROWSER_USER" "$BROWSER_WORK" 2>/dev/null \
      && log "已 chown 给 $BROWSER_USER (BP_CHOWN=1)" \
      || warn "chown 失败，保持当前属主"
    if ! touch "$BROWSER_WORK/.wtest" 2>/dev/null; then
      rm -f "$BROWSER_WORK/.wtest" 2>/dev/null
      warn "⚠ chown 之后工作区不可写了 —— 这就是 proot 的 uid 映射问题"
      warn "  补救: mv $BROWSER_WORK ${BROWSER_WORK}-poisoned && mkdir -p $BROWSER_WORK"
    fi
  else
    log "跳过 chown（proot 安全默认；需要时 BP_CHOWN=1）"
  fi
else
  warn "⚠ 工作区不可写: $BROWSER_WORK"
  warn "  proot 里 /home 有时落在只读层。换一个可写路径，例如:"
  warn "    BROWSER_WORK_DIR=/home/container/browser-work bash ins-ub24.sh"
fi

# Xauthority 放在能写的地方
XAUTH="$BROWSER_HOME/.Xauthority"
if ! touch "$XAUTH" 2>/dev/null; then
  XAUTH="$APP/.Xauthority"
  touch "$XAUTH"
  warn ".Xauthority 落在 $XAUTH"
fi

# ------------------------------------------------------------
# 9. 环境文件
# ------------------------------------------------------------
log "8/8 写环境文件..."
cat >"$ENV_FILE" <<EOF
PORT=${PORT:-3210}
HOST=${HOST:-0.0.0.0}
BROWSER_DISPLAY=$DISPLAY_NUM
BROWSER_CHROME_PATH=$CHROME_PATH
PLAYWRIGHT_CHROME_PATH=$CHROME_PATH
PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$CHROME_PATH
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
BROWSER_USER=$BROWSER_USER
BROWSER_HOME=$BROWSER_HOME
BROWSER_WORK_DIR=$BROWSER_WORK
BROWSER_XAUTHORITY=$XAUTH
BROWSER_USER_DATA_DIR=$BROWSER_WORK/persistent
# SeleniumBase 兼容层: 让 seleniumbase.SB 走 DrissionPage 后端
# (proot 下 chromedriver 会 SIGSEGV, 详见 README「0. Chrome 脚本跑不起来」)
PYTHONPATH=$APP/shim:$APP/shim/pylibs
# PRoot: 让 browser-launcher.js 跳过降权（该补丁已内置在 launcher 里）
PROOT_ENV=1
PROOT_NO_SECCOMP=1
EOF
chmod 644 "$ENV_FILE"

# proot 全局标记
cat >/etc/profile.d/browser-panel-proot.sh <<'EOF'
export PROOT_NO_SECCOMP=1
export PROOT_ENV=1
EOF
chmod 644 /etc/profile.d/browser-panel-proot.sh

cat >/etc/profile.d/browser-panel.sh <<EOF
export DISPLAY=$DISPLAY_NUM
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export BROWSER_CHROME_PATH=$CHROME_PATH
export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$CHROME_PATH
export PYTHONPATH=$APP/shim\${PYTHONPATH:+:\$PYTHONPATH}
EOF
chmod 644 /etc/profile.d/browser-panel.sh

# ------------------------------------------------------------
# 10. 总结
# ------------------------------------------------------------
echo
echo "============================================"
echo " 安装完成"
echo "============================================"
echo
echo "Node:    $(node -v)"
echo "Chrome:  $CHROME_PATH"
echo "Python:  $(python3 --version)"
echo "工作区:  $BROWSER_WORK  (可写=$WRITABLE)"
echo "env:     $ENV_FILE"
echo
echo "下一步:"
echo "  1) 装面板:  bash bp.sh"
echo "  2) 放 launcher: cp browser-launcher.js $APP/server/runtime/"
echo "  3) 启动:    sh panel.sh"
echo "  4) 体检:    sh panel.sh status"
echo
echo "systemd: 已 hold（proot 用不到）"
echo "============================================"
echo
