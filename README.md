# bp-panel-ub24（Ubuntu 24.04 + proot 修复版）

Ubuntu 24.04 上 browser-panel 的一键安装 / 启动脚本，面向 **proot** 容器环境。

参考：
- <https://github.com/kuisa/proot-ub24> —— 你的 Ubuntu proot 环境
- <https://github.com/kuisa/bp-panel-alpine> —— Alpine 原版（跨发行版问题参照）

---

## ⚠️ 验证到什么程度了

**已在真机（Ubuntu 24.04 proot，summerhosting 那台，Chrome 154）验证的部分：**

- ✅ chromedriver 崩溃的完整定位（见下方「0. Chrome 脚本跑不起来」，逐条实验过）
- ✅ Chrome 本身可用（有头 :1 / 无头 / CDP 都正常）
- ✅ **SeleniumBase 兼容层（DrissionPage 后端）**——真机端到端跑通**两个真实脚本**：
  - `craftserve.py`：启动 Chrome → 登录成功 → 进续期页 → 判定冷却中 → TG 推送成功
  - `skymc.py`（含 Cloudflare Turnstile）：CF 挑战 → 点验证码 → 登录 → 进面板 →
    点「Expires in」菜单 → **续期成功（57m → 60m）** → TG 推送成功
  - 确定性页面测试：输入框 / 密码框 / `button:contains('Log in')` 点击 /
    XPath 兄弟节点 / `execute_script` / 截图，全通过
  - **干净环境（`env -i PATH=/usr/bin:/bin`）下依然加载**，说明面板怎么 spawn 都生效
  - `BP_NO_SHIM=1` 时正确回退到原生 SeleniumBase 4.54.12
- ✅ `.pth` 加载机制（见下方第 3 点，`sitecustomize` 会被系统那个屏蔽）
- ✅ X11 XTEST 真实鼠标点击（含视口偏移换算，见上方第 2 点）

**尚未在真机验证的部分：**

- ⚠️ `ins-ub24.sh` 的完整重装流程（面板本来就在跑，没推倒重来）
- ⚠️ `browser-launcher.js` 的 proot 补丁在这台 Ubuntu 上的实际效果（Alpine 上验证过）

`isProot` 作用域做过 AST 级验证；shell / JS 语法都检查过。

**⚠️ 内存提醒**：这台容器**只有 773MB 内存**。Chrome 跑起来会吃掉大部分，
曾经把容器里的 `cloudflared` 挤掉导致隧道断（页面 Error 1033 / curl HTTP 530）。
跑浏览器任务时建议限制并发，别同时开多个 Chrome。

**结论**：Chrome 跑不起来这个核心问题已解决并在真机端到端验证通过。

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

### 0. Chrome 脚本跑不起来 —— 真凶是 chromedriver（最重要）

**症状**：面板里 SeleniumBase 脚本一律失败，报

```
urllib3.exceptions.ProtocolError: ('Connection aborted.',
RemoteDisconnected('Remote end closed connection without response'))
```

**排查过程**（在真机上逐条验证过）：

| 检查项 | 结果 |
|---|---|
| Chrome 本身能跑吗 | ✅ 能。有头(:1)/无头/CDP 全正常，进程树 zygote+renderer 齐全 |
| chromedriver 能起吗 | ✅ 能，`GET /status`、`GET /sessions` 都正常 |
| `POST /session` 呢 | ❌ **必崩，退出码 139 = SIGSEGV** |
| 换 chromedriver 版本 | ❌ 换到与 Chrome 精确匹配的 154.0.8037.57 照样崩 |
| 非 root 用户跑 | ❌ 一样崩 |
| `binary=/bin/false` | ❌ **还是崩** —— 说明崩在启动 Chrome **之前** |
| 空 capabilities `{}` | ❌ **还是崩** |

结论：**chromedriver 在这套 proot 下不兼容**（proot 拦了某个 syscall，chromedriver 段错误）。
不是版本问题、不是权限问题、不是 Chrome 问题。系统里没有 `strace`/`gdb`，没法再往下挖。

**解决办法：绕开 chromedriver。**

`shim/seleniumbase/__init__.py` 是一个 **SeleniumBase 兼容层**，底层换成 **DrissionPage（纯 CDP，不用 chromedriver）**。
装好之后 `from seleniumbase import SB` 自动走这个后端，**你的脚本一行都不用改**。

已实测通过（真机跑通两个真实脚本）：`uc_open_with_reconnect` / `open` / `type` / `click` /
`slow_click` / `js_click` / `hover` / `get_text` / `get_value` / `get_attribute` /
`execute_script` / `is_element_visible` / `is_element_present` / `is_element_clickable` /
`wait_for_element` / `wait_for_element_visible` / `wait_for_element_not_visible` /
`find_element` / `find_elements` / `get_page_source` / `get_current_url` / `get_title` /
`save_screenshot` / `uc_gui_click_captcha`，以及 CSS / XPath / `:contains('文字')` 三种选择器。

**两个必须知道的实现细节**（都在兼容层里处理好了）：

1. **点击会自动降级**。DrissionPage 对隐藏/未布局元素（折叠菜单里的 `<button>`、
   `<option>` 等）调 `el.click()` 会抛 `NoRectError`（该元素没有位置及大小）。
   兼容层会自动回退到 JS 点击（`by_js` → `this.click()` → dispatch MouseEvent）。
   否则脚本会在一个**明明能点**的元素上崩掉。

2. **验证码点击走真实鼠标**。Cloudflare Turnstile 能区分 CDP 合成事件和真实 X11 输入，
   而且它的复选框在跨域 iframe + closed shadow DOM 里，JS 够不着。兼容层用
   **X11 XTEST**（`python-xlib`）按 iframe 的屏幕坐标点真实鼠标 —— 和 SeleniumBase 用
   pyautogui 是一个原理，但不依赖 pyautogui（它需要 `tkinter`/`python3-tk`，通常没装，
   一 import 就炸）。

   > 踩过的坑：`window.screenY` 给的是**窗口**位置，不是视口位置 —— 浏览器工具栏在视口上方。
   > 视口的屏幕 Y = `screenY + (outerHeight - innerHeight)`（实测 Chrome 是 87px）。
   > 差这 87px 点击就落在工具栏上，**不报错**，就是验证码永远过不去。

安装方式（`ins-ub24.sh` 会自动做）：

```
/opt/browser-panel/shim/seleniumbase/__init__.py   ← 兼容层
```

并且通过三个地方保证能被加载（任一生效即可）：

1. `.env.panel` 里 `PYTHONPATH=/opt/browser-panel/shim`
2. `/etc/profile.d/browser-panel.sh` 里 export 同一个变量
3. **`bp-shim.pth`**（写在 dist-packages 里）—— 这样**任何** python 进程都会优先加载它，
   不依赖环境变量有没有传到子进程

> ⚠️ 第 3 点**不能用 `sitecustomize.py`**。Python 只会加载 `sys.path` 上**第一个**
> `sitecustomize`，而 Ubuntu 在 `/usr/lib/python3.12/sitecustomize.py` 放了一个 apport 钩子，
> 路径优先级高于 dist-packages —— 写在 dist-packages 里的会被**静默屏蔽**（不报错，就是不生效）。
> `.pth` 则是每个 site 目录都会被处理，不会被屏蔽。这是实测踩过的坑。

想临时关掉兼容层用原生 SeleniumBase：`BP_NO_SHIM=1 python3 xxx.py`

> 为什么不用原生 SeleniumBase：它内部就是靠 chromedriver 的，没法绕。
> DrissionPage 直接用 CDP 协议驱动 Chrome，而 Chrome 的 CDP 在这个环境里是好的。

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
# 1. 装依赖 + SeleniumBase 兼容层
#    注意: shim/ 目录必须和 ins-ub24.sh 放一起(仓库里保持这个层级)
curl -o /root/ins-ub24.sh -Ls https://raw.githubusercontent.com/kof99zip/proot-ub24-mod/main/ins-ub24.sh
curl -o /root/shim-seleniumbase.py -Ls https://raw.githubusercontent.com/kof99zip/proot-ub24-mod/main/shim/seleniumbase/__init__.py
mkdir -p /root/shim/seleniumbase && mv /root/shim-seleniumbase.py /root/shim/seleniumbase/__init__.py
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

# 5. 验证 Chrome 脚本能跑（关键一步）
python3 -c "from seleniumbase import SB; import seleniumbase; print(seleniumbase.__version__)"
#   应输出 sbshim-1.0.0；若输出 4.x.x 说明兼容层没加载上
```

**验证兼容层真的生效**（跑一个最小用例）：

```bash
cd /tmp && python3 - <<'PY'
from seleniumbase import SB
with SB(uc=True, headed=True) as sb:
    sb.uc_open_with_reconnect("https://example.com", reconnect_time=3)
    print("标题:", sb.get_title())
    print("可见:", sb.is_element_visible("p"))
    sb.save_screenshot("/tmp/ok.png")
print("OK")
PY
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
