#!/bin/bash
# ============================================================
# 进 proot 后的第一步：修好 apt
#
# 为什么需要: proot 里 apt 会报
#   Could not open file /var/cache/apt/archives/partial/xxx.deb
#   - open (13: Permission denied)
# 因为那个目录属主是真实 uid 42(_apt)、mode 700, 而 proot 里 `id` 报的 uid 0 是假的。
# chmod 也没用(proot 会伪造 chmod, 返回成功但 mode 不变)。
#
# 用法:
#   curl -o /root/fix-apt.sh -Ls <仓库地址>/fix-apt.sh
#   bash /root/fix-apt.sh
#   # 然后再跑你自己的:
#   echo "127.0.0.1 localhost" > /etc/hosts && apt update && apt install curl wget nano sudo bash nginx -y
# ============================================================
set -u

echo "[fix-apt] 开始..."

# ---------- 1. /etc/hosts ----------
if [ ! -s /etc/hosts ]; then
  printf '127.0.0.1 localhost\n127.0.0.1 %s\n' "$(hostname 2>/dev/null || echo localhost)" > /etc/hosts
  echo "[fix-apt] /etc/hosts 已创建 (127.0.0.1 localhost)"
elif ! grep -q 'localhost' /etc/hosts 2>/dev/null; then
  printf '127.0.0.1 localhost\n127.0.0.1 %s\n' "$(hostname 2>/dev/null || echo localhost)" >> /etc/hosts
  echo "[fix-apt] /etc/hosts 补上了 localhost"
else
  echo "[fix-apt] /etc/hosts 已有 localhost, 跳过"
fi

# ---------- 2. apt 下载缓存 ----------
if touch /var/cache/apt/archives/partial/.wtest 2>/dev/null; then
  rm -f /var/cache/apt/archives/partial/.wtest 2>/dev/null
  echo "[fix-apt] apt 缓存目录本来就可写, 无需处理"
elif [ -f /etc/apt/apt.conf.d/99proot-cache ] \
     && touch /var/cache/apt/archives2/partial/.wtest 2>/dev/null; then
  rm -f /var/cache/apt/archives2/partial/.wtest 2>/dev/null
  echo "[fix-apt] apt 缓存已重定向且可用, 跳过"
else
  rm -f /var/cache/apt/archives/partial/.wtest 2>/dev/null
  mkdir -p /var/cache/apt/archives2/partial
  if touch /var/cache/apt/archives2/partial/.wtest 2>/dev/null; then
    rm -f /var/cache/apt/archives2/partial/.wtest
    echo 'Dir::Cache::archives "/var/cache/apt/archives2";' > /etc/apt/apt.conf.d/99proot-cache
    echo "[fix-apt] apt 缓存已重定向到 /var/cache/apt/archives2"
  else
    echo "[fix-apt] ✗ 新缓存目录也不可写, 请手动指定一个可写路径" >&2
    exit 1
  fi
fi

# ---------- 3. apt 沙箱 ----------
if grep -rqs 'APT::Sandbox::User' /etc/apt/apt.conf.d/ 2>/dev/null; then
  echo "[fix-apt] apt 沙箱已配置, 跳过"
else
  echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99proot-nosandbox
  echo "[fix-apt] 已关闭 apt 的 _apt 沙箱"
fi

echo
echo "[fix-apt] ✓ 完成。现在可以正常跑:"
echo "  apt update && apt install -y curl wget nano sudo bash nginx"
echo
echo "  装完 nginx 如果 nginx -t 报 error.log Permission denied:"
echo "    rm -f /var/log/nginx/access.log /var/log/nginx/error.log"
echo "    touch /var/log/nginx/access.log /var/log/nginx/error.log"
