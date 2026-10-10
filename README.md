# bp-panel-ub24（Ubuntu 24.04 + proot 修复版）

Ubuntu 24.04 上 browser-panel 的一键安装 / 启动脚本，面向 **proot** 容器环境。

参考：
- <https://github.com/kuisa/proot-ub24> —— 你的 Ubuntu proot 环境
- <https://github.com/kuisa/bp-panel-alpine> —— Alpine 原版（跨发行版问题参照）

---

## ⚠️ 先说清楚：这份包我没能在真机上验证

webttyd 权限已收回，我**没有 Ubuntu 24.04 proot 环境可测**。

- ✅ 已做：shell / JS 语法检查、`isProot` 作用域 AST 级验证
- ❌ 未做：真机安装、真机跑任务
- Alpine 版是在真机上逐步验证出来的；这份的 Ubuntu 特有部分是**按 proot-ub24 的实际配置推导**的，请按 README 的排查顺序逐步确认。

---

## 与 proot-ub24 的关系

`proot-ub24` 里你已经有的东西，这份**不重复造**：

| proot-ub24 | 本包 |
|---|---|
| `toor.sh` — 建 proot rootfs | 沿用，不含在本包里 |
| `install-web.sh` — web 相关 | 沿用，不含在本包里 |
| `stack.sh` — 依赖安装 | 由 `ins-ub24.sh` 替代（见下方差异） |
| `bp.sh` — 面板安装 | **沿用原版**（它从 debbide/browser-panel 拉 release） |
| `fix_browser.sh` — 补丁脚本 | **已并入 `browser-launcher.js`，不必再单独跑** |
| `panel-start.sh` | 由本包 `panel.sh` 替代 |

---

## 本包做了什么

### 1. PRoot 跳过降权 —— 烙进 launcher，不用再跑 fix_browser.sh

`fix_browser.sh` 用 Python 脚本改写 `browser-launcher.js`，插入 `isProot` 判断。这份直接把同样的逻辑**内置**进 `browser-launcher.js`：

```js
const isProot =
  process.env.PROOT_ENV === '1' ||
  process.env.PROOT_NO_SECCOMP === '1' ||
  process.env.PROOT_TMP_DIR === '/tmp/proot';
```

两处生效点：跳过 `setpriv`/`su-exec` 包装，以及**禁止 Node 自己设 `spawnOpts.uid/gid`**（`fix_browser.sh` 两处都改了，这里同样两处）。

**好处**：不用再维护"先装面板、再跑补丁"的顺序；面板升级覆盖 launcher 后不会丢补丁。

### 2. 路径可写性实测（不信权限位）

proot 里 `chmod` 会被**伪造** —— 返回成功、权限不变。所以判断一个目录能不能用，只能 `touch`：

```bash
if touch "$BROWSER_WORK/.wtest" 2>/dev/null; then ... fi
```

`ins-ub24.sh` 装完会实测一次，并且 **chown 之后再测一次**。

### 3. chown 之后的二次确认

Alpine 那台上踩过：面板启动时 `chown -R browser` 把工作区变成 `1000:1000`，之后**谁也改不回来**（`chmod` 被伪造、`su browser` 也删不掉自己的文件）。

`ins-ub24.sh` 会在 chown 之后复测；一旦发现变不可写，直接提示改用 `BROWSER_USER=root`。

### 4. `panel.sh` 适配 Ubuntu

- **Node 查找顺序**：`/opt/node22/bin/node` → `/usr/local/bin/node` → `/usr/bin/node` → `PATH`
  （你的 node 是 `stack.sh` 装的 portable，`/usr/bin/node` 可能没有或是旧版）
- **自动加载 `.env.panel`**：Ubuntu 上同样没有 systemd 的 `EnvironmentFile=`
- **`setsid` 启动**：容器/tty 里 `nohup ... &` 起的进程会随父 shell 退出被连带杀掉
- 5 个子命令：`start` / `stop` / `restart` / `status` / `logs`

### 5. Ubuntu 24.04 特有的包名

`t64` 过渡后缀必须用对，否则 apt 找不到包：

```
libgtk-3-0t64   libatk1.0-0t64   libatk-bridge2.0-0t64
libatspi2.0-0t64  libasound2t64  libcups2t64
```

另外两点：

- **`chromium-browser` 在 Ubuntu 24.04 是 snap 转接壳，容器里跑不了** → 用 Chrome for Testing portable 装到 `/opt/chrome`
- **pip 需要 `--break-system-packages`**（PEP 668）

### 6. systemd 挡住

proot 里 systemd 会被 apt 顺带装进来然后炸。`ins-ub24.sh` 用 `apt-mark hold` 锁住，并且**装完复查**是否被装进来了（只警告不退出，避免在某些精简环境里卡死流程）。

---

## 使用步骤

前提：已经在 proot Ubuntu 24.04 环境里（跑过 `toor.sh`）。

```bash
# 1. 装依赖
curl -o /root/ins-ub24.sh -Ls https://raw.githubusercontent.com/kof99zip/proot-ub24-mod/main/ins-ub24.sh
bash /root/ins-ub24.sh

# 2. 装面板（用你 proot-ub24 里那份原版 bp.sh 即可）
curl -o /root/bp.sh -Ls https://raw.githubusercontent.com/kuisa/proot-ub24/main/bp.sh
bash /root/bp.sh

# 3. 放 launcher（已内置 proot 补丁）
mkdir -p /opt/browser-panel/server/runtime
curl -fLs https://raw.githubusercontent.com/kof99zip/proot-ub24-mod/main/browser-launcher.js \
  -o /opt/browser-panel/server/runtime/browser-launcher.js

# 4. 启动
curl -o /root/panel.sh -Ls https://raw.githubusercontent.com/kof99zip/proot-ub24-mod/main/panel.sh
sh /root/panel.sh
sh /root/panel.sh status
```

**Firefox / ruyipage**（如果要用）按 proot-ub24 的 README 装，`fix_browser.sh` 里的 Marionette 2828 那部分仍需要跑 —— 本包只覆盖 Chrome 侧的 proot 降权问题。

---

## 排查顺序

装完按这个顺序确认，每步都有明确判据：

```bash
# 1. node / chrome 在不在
node -v && /opt/chrome/chrome --version

# 2. 工作区到底能不能写（别看权限位）
touch /home/browser/browser-work/.t && echo 可写 && rm /home/browser/browser-work/.t

# 3. env 有没有被加载
cd /opt/browser-panel && set -a && . ./.env.panel && set +a
node -e "console.log(require('./config').browser.workDir)"

# 4. 目录结构对不对（多套一层 server/ 会报 Cannot find module '../config'）
ls /opt/browser-panel/server/index.js && ls /opt/browser-panel/config.js

# 5. 面板起来没有
sh /root/panel.sh status
```

---

## 已知风险 / 边界

| 项 | 说明 |
|---|---|
| **未在真机验证** | 见开头。这份的 Ubuntu 特有部分是推导出来的 |
| **进程匹配写死** | `pgrep -f "node server/index.js"`，只在上游默认启动方式下有效 |
| **`BROWSER_USER` 默认 `browser`** | 沿用你现有配置。只有真的撞上 chown 锁死才改 `root` |
| **Playwright 浏览器不下载** | `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`，用系统 Chrome |
| **`ff.sh` 不含** | Firefox + ruyipage 在 proot 下要单独处理 |

---

## 许可

沿用原项目许可。browser-panel 版权归 [debbide/browser-panel](https://github.com/debbide/browser-panel) 所有。
