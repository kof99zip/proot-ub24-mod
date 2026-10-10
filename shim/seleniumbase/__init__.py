"""
seleniumbase 兼容层 (DrissionPage 后端)
=====================================
在 proot 环境下 chromedriver 会 SIGSEGV，本模块用 DrissionPage(纯 CDP) 顶替，
对外保持 `from seleniumbase import SB` 的原 API，脚本无需修改。

支持的选择器:
  - CSS:      input[name='email']  /  div.react-responsive-modal-container
  - XPath:    //a[.//p[text()='Payments']]
  - contains: button:contains('Log in')      (自动转 XPath)
"""

import os
import re
import time

__version__ = "sbshim-1.0.0"
__all__ = ["SB"]


# --------------------------------------------------------------------------
# 选择器转换: SeleniumBase 风格 -> DrissionPage 定位符
# --------------------------------------------------------------------------
_CONTAINS_RE = re.compile(r":contains\(\s*(['\"])(.*?)\1\s*\)")


def _to_dp(selector):
    """把选择器转成 DrissionPage 定位符 (css: / xpath:)"""
    if not selector or not isinstance(selector, str):
        raise ValueError("选择器不能为空")

    s = selector.strip()
    if s.startswith("css:"):
        s = s[4:]
    elif s.startswith("xpath:"):
        return s

    # :contains('文本') -> xpath://tag[contains(., '文本')]
    m = _CONTAINS_RE.search(s)
    if m:
        text = m.group(2)
        head = s[: m.start()].strip()
        tag = "div"
        tm = re.match(r"^([a-zA-Z][a-zA-Z0-9]*)", head)
        if tm:
            tag = tm.group(1)
        safe = text.replace("'", "\\'")
        return "xpath://%s[contains(., '%s')]" % (tag, safe)

    # XPath
    if s.startswith("//") or s.startswith("(//") or s.startswith("./") or s.startswith("/"):
        return "xpath:" + s

    return "css:" + s


def _split_args(chromium_arg):
    if not chromium_arg:
        return []
    if isinstance(chromium_arg, (list, tuple)):
        return [str(a).strip() for a in chromium_arg if str(a).strip()]
    return [a.strip() for a in str(chromium_arg).split(",") if a.strip()]


# --------------------------------------------------------------------------
# SB — 兼容 SeleniumBase 的上下文管理器
# --------------------------------------------------------------------------
class SB(object):
    def __init__(self, uc=False, test=False, headed=False, headless=False,
                 xvfb=False, chromium_arg="", browser="chrome",
                 user_data_dir=None, binary_location=None, locale=None,
                 proxy=None, incognito=False, guest_mode=False,
                 maximize=False, **kwargs):
        self._uc = uc
        self._headed = headed or (not headless and not self._is_ci_headless())
        self._headless = bool(headless)
        self._chromium_arg = chromium_arg
        self._browser = browser
        self._user_data_dir = user_data_dir
        self._binary_location = binary_location
        self._locale = locale
        self._proxy = proxy
        self._incognito = incognito
        self._maximize = maximize or ("--start-maximized" in _split_args(chromium_arg))
        self._extra = kwargs
        self._default_timeout = 10
        self.page = None
        self._started = False

    # ---------------- 内部工具 ----------------
    @staticmethod
    def _is_ci_headless():
        return bool(os.environ.get("SBSHIM_HEADLESS"))

    def _browser_binary(self):
        for cand in (self._binary_location,
                     os.environ.get("BROWSER_PATH"),
                     os.environ.get("CHROME_BIN"),
                     "/opt/chrome/chrome",
                     "/usr/local/bin/google-chrome",
                     "/usr/bin/google-chrome",
                     "/usr/bin/chromium",
                     "/usr/bin/chromium-browser"):
            if cand and os.path.exists(cand):
                return cand
        return None

    def _build_options(self):
        from DrissionPage import ChromiumOptions
        co = ChromiumOptions()
        binary = self._browser_binary()
        if binary:
            co.set_browser_path(binary)
        if self._user_data_dir:
            co.set_user_data_path(self._user_data_dir)
        if self._incognito:
            co.set_argument("--incognito")

        args = []
        args += _split_args(self._chromium_arg)
        for a in ("--no-sandbox",
                  "--disable-dev-shm-usage",
                  "--disable-gpu",
                  "--no-first-run",
                  "--no-default-browser-check",
                  "--disable-blink-features=AutomationControlled",
                  "--disable-background-networking",
                  "--disable-sync",
                  "--metrics-recording-only",
                  "--disable-popup-blocking"):
            if a not in args:
                args.append(a)
        if self._headless:
            if "--headless=new" not in args and "--headless" not in args:
                args.append("--headless=new")
        if self._maximize and "--start-maximized" not in args:
            args.append("--start-maximized")
        for a in args:
            co.set_argument(a)
        if self._proxy:
            co.set_proxy(self._proxy)
        if self._locale:
            co.set_argument("--lang=%s" % self._locale)
        try:
            co.auto_port()
        except Exception:
            pass
        return co

    def _launch(self):
        if self._started:
            return
        os.environ.setdefault("DISPLAY", ":1")
        xauth = os.environ.get("XAUTHORITY")
        if not xauth and os.path.exists("/home/headless/.Xauthority"):
            os.environ["XAUTHORITY"] = "/home/headless/.Xauthority"
        from DrissionPage import ChromiumPage
        self.page = ChromiumPage(self._build_options())
        self._started = True

    # ---------------- 上下文管理 ----------------
    def __enter__(self):
        self._launch()
        return self

    def __exit__(self, exc_type, exc, tb):
        try:
            self.quit()
        except Exception:
            pass
        return False

    def quit(self):
        if self.page is not None:
            try:
                self.page.quit()
            except Exception:
                pass
            self.page = None
        self._started = False

    def __getattr__(self, name):
        # 未实现的方法 -> 转发给 page (best effort)
        if name.startswith("_"):
            raise AttributeError(name)
        page = self.__dict__.get("page")
        if page is not None and hasattr(page, name):
            return getattr(page, name)
        raise AttributeError("SB 兼容层未实现: %s" % name)

    # ---------------- 元素查找 ----------------
    def _find(self, selector, timeout=None, index=1):
        loc = _to_dp(selector)
        wait = 0.1 if timeout is None else float(timeout)
        try:
            el = self.page.ele(loc, timeout=wait, index=index)
        except Exception:
            return None
        # DrissionPage 找不到元素时返回 NoneElement —— 不是 None 但为假值，必须用真值判断
        if el is None or not el:
            return None
        return el

    def _require(self, selector, timeout=None):
        el = self._find(selector, timeout)
        if el is None:
            raise Exception("元素未找到: %s" % selector)
        return el

    def find_element(self, selector, by=None, **kwargs):
        """返回单个元素（找不到返回 None，不抛异常）"""
        return self._find(selector, kwargs.get("timeout"))

    def find_elements(self, selector, by=None, **kwargs):
        """返回元素列表（找不到返回空列表）"""
        loc = _to_dp(selector)
        try:
            els = self.page.eles(loc, timeout=kwargs.get("timeout") or 0.1)
        except Exception:
            return []
        if not els:
            return []
        return [e for e in els if e]

    # ---------------- 导航 ----------------
    def open(self, url, **kwargs):
        self.page.get(url)
        return self.page

    def uc_open_with_reconnect(self, url, reconnect_time=None, **kwargs):
        self.page.get(url)
        if reconnect_time:
            time.sleep(min(float(reconnect_time), 5))
        return self.page

    def uc_open_with_cdp_mode(self, url, **kwargs):
        self.page.get(url)
        return self.page

    def get(self, url):
        self.page.get(url)
        return self.page

    def get_current_url(self):
        return self.page.url

    def get_page_source(self):
        return self.page.html

    def refresh(self):
        self.page.refresh()

    def go_back(self):
        self.page.back()

    # ---------------- 交互 ----------------
    def _do_click(self, el, by_js=False):
        """稳健点击：普通点击失败(元素无位置/大小、被遮挡)时回退 JS 点击"""
        if not by_js:
            try:
                el.click()
                return el
            except Exception:
                pass
        # JS 点击（对隐藏元素、option、无布局元素都有效）
        for attempt in ("by_js", "run_js", "dispatch"):
            try:
                if attempt == "by_js":
                    el.click(by_js=True)
                elif attempt == "run_js":
                    el.run_js("this.click();")
                else:
                    el.run_js(
                        "this.dispatchEvent(new MouseEvent('click',"
                        "{bubbles:true,cancelable:true,view:window}));"
                    )
                return el
            except Exception:
                continue
        return el

    def type(self, selector, text, timeout=None, **kwargs):
        el = self._require(selector, timeout)
        try:
            el.clear()
        except Exception:
            pass
        el.input(str(text))
        return el

    def click(self, selector, timeout=None, **kwargs):
        el = self._require(selector, timeout)
        return self._do_click(el)

    def slow_click(self, selector, timeout=None, **kwargs):
        """拟人化点击：先滚动到可见，稍作停顿再点"""
        el = self._require(selector, timeout)
        try:
            el.scroll.to_see()
        except Exception:
            pass
        time.sleep(0.15)
        return self._do_click(el)

    def js_click(self, selector, timeout=None, **kwargs):
        """强制用 JS 触发点击"""
        el = self._require(selector, timeout)
        return self._do_click(el, by_js=True)

    def hover(self, selector, timeout=None, **kwargs):
        el = self._require(selector, timeout)
        try:
            el.hover()
        except Exception:
            pass
        return el

    def click_if_visible(self, selector, **kwargs):
        el = self._find(selector)
        if el is not None:
            try:
                return self._do_click(el) and True
            except Exception:
                return False
        return False

    def clear(self, selector, **kwargs):
        self._require(selector).clear()

    def press_key(self, selector, key, **kwargs):
        el = self._require(selector)
        el.input("\n" if key in ("\n", "Enter", "ENTER") else str(key))

    def select_option_by_text(self, selector, text, **kwargs):
        self.page.run_js(
            "(function(){var s=document.querySelector(%r);if(!s)return;"
            "for(var i=0;i<s.options.length;i++){if(s.options[i].text.indexOf(%r)>=0){"
            "s.selectedIndex=i;s.dispatchEvent(new Event('change',{bubbles:true}));break;}}})()"
            % (selector, text)
        )

    def execute_script(self, script, *args):
        return self.page.run_js(script)

    def execute_async_script(self, script, *args):
        return self.page.run_js(script)

    def scroll_to(self, selector=None, **kwargs):
        if selector:
            el = self._find(selector)
            if el is not None:
                try:
                    el.scroll.to_see()
                except Exception:
                    pass
        else:
            self.page.run_js("window.scrollTo(0, document.body.scrollHeight);")

    def sleep(self, seconds):
        time.sleep(float(seconds))

    # ---------------- 读取 ----------------
    def get_text(self, selector, timeout=None, **kwargs):
        el = self._require(selector, timeout)
        return el.text

    def get_attribute(self, selector, attribute, timeout=None, **kwargs):
        el = self._require(selector, timeout)
        return el.attr(attribute)

    def get_value(self, selector, timeout=None, **kwargs):
        el = self._require(selector, timeout)
        try:
            return el.value
        except Exception:
            return el.attr("value")

    def get_title(self):
        return self.page.title

    def get_html(self):
        return self.page.html

    # ---------------- 状态判断 ----------------
    def is_element_present(self, selector, timeout=None, **kwargs):
        try:
            return self._find(selector, timeout) is not None
        except Exception:
            return False

    def is_element_visible(self, selector, timeout=None, **kwargs):
        try:
            el = self._find(selector, timeout)
            if el is None:
                return False
            return bool(el.states.is_displayed)
        except Exception:
            return False

    def is_element_clickable(self, selector, timeout=None, **kwargs):
        try:
            el = self._find(selector, timeout)
            if el is None:
                return False
            return bool(el.states.is_enabled) and bool(el.states.is_displayed)
        except Exception:
            return False

    def is_element_enabled(self, selector, timeout=None, **kwargs):
        try:
            el = self._find(selector, timeout)
            return bool(el is not None and el.states.is_enabled)
        except Exception:
            return False

    def is_text_visible(self, text, selector="body", **kwargs):
        try:
            return str(text) in (self.page.ele("css:" + selector).text or "")
        except Exception:
            return False

    # ---------------- 等待 ----------------
    def wait_for_element(self, selector, timeout=None, **kwargs):
        """SeleniumBase 语义：等元素出现且可见，返回元素"""
        return self.wait_for_element_visible(selector, timeout, **kwargs)

    def wait_for_element_visible(self, selector, timeout=None, **kwargs):
        t = float(timeout or self._default_timeout)
        end = time.time() + t
        while time.time() < end:
            if self.is_element_visible(selector):
                return self._find(selector)
            time.sleep(0.25)
        raise Exception("等待元素可见超时: %s" % selector)

    def wait_for_element_present(self, selector, timeout=None, **kwargs):
        t = float(timeout or self._default_timeout)
        end = time.time() + t
        while time.time() < end:
            if self.is_element_present(selector):
                return self._find(selector)
            time.sleep(0.25)
        raise Exception("等待元素出现超时: %s" % selector)

    def wait_for_element_not_visible(self, selector, timeout=None, **kwargs):
        t = float(timeout or self._default_timeout)
        end = time.time() + t
        while time.time() < end:
            if not self.is_element_visible(selector):
                return True
            time.sleep(0.25)
        return False

    def wait_for_element_absent(self, selector, timeout=None, **kwargs):
        t = float(timeout or self._default_timeout)
        end = time.time() + t
        while time.time() < end:
            if not self.is_element_present(selector):
                return True
            time.sleep(0.25)
        return False

    def wait_for_text_visible(self, text, selector="body", timeout=None, **kwargs):
        t = float(timeout or self._default_timeout)
        end = time.time() + t
        while time.time() < end:
            if self.is_text_visible(text, selector):
                return True
            time.sleep(0.25)
        return False

    # ---------------- 反检测 / 验证码 ----------------
    def _click_xy(self, x, y):
        """优先用 X11 XTEST 发真实鼠标事件（Cloudflare 能识别 CDP 合成事件，XTEST 更接近真人）"""
        if self._xtest_click(x, y):
            return True
        for t in ("mouseMoved", "mousePressed", "mouseReleased"):
            try:
                self.page.run_cdp("Input.dispatchMouseEvent", type=t,
                                  x=float(x), y=float(y),
                                  button="left", clickCount=1)
            except Exception:
                pass
            time.sleep(0.05)
        return False

    @staticmethod
    def _xtest_click(x, y):
        """用 python-xlib 的 XTEST 扩展在 X 服务器层面发真实鼠标点击"""
        try:
            from Xlib import X
            from Xlib import display as _xd
            from Xlib.ext import xtest

            d = _xd.Display(os.environ.get("DISPLAY", ":1"))
            try:
                root = d.screen().root
                root.warp_pointer(int(x), int(y))
                d.sync()
                time.sleep(0.12)
                xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
                d.sync()
                time.sleep(0.08)
                xtest.fake_input(d, X.ButtonPress, 1)
                d.sync()
                time.sleep(0.06)
                xtest.fake_input(d, X.ButtonRelease, 1)
                d.sync()
                time.sleep(0.12)
                return True
            finally:
                try:
                    d.close()
                except Exception:
                    pass
        except Exception:
            return False

    def uc_gui_click_captcha(self, retry=False, **kwargs):
        """点击 Cloudflare Turnstile / hCaptcha 复选框。

        CF 的复选框在跨域 iframe + closed shadow DOM 里，JS 点不到；
        标准做法是按 iframe 的屏幕坐标点真实鼠标（SeleniumBase 用 pyautogui，
        这里用 X11 XTEST，效果一致且不需要 tkinter）。
        """
        sels = [
            'iframe[src*="challenges.cloudflare.com"]',
            'iframe[title*="Cloudflare"]',
            'iframe[src*="turnstile"]',
            'iframe[src*="hcaptcha"]',
        ]
        for sel in sels:
            iframe = self._find(sel)
            if iframe is None:
                continue
            # 取视口在屏幕上的偏移。
            # 坑: window.screenY 给的是「窗口」位置, 不含浏览器工具栏;
            # 视口顶部还要加上 (outerHeight - innerHeight)。
            try:
                off = self.page.run_js(
                    "return [window.screenX||0,"
                    " (window.screenY||0)"
                    " + ((window.outerHeight||0) - (window.innerHeight||0))];"
                )
                ox, oy = (float(off[0]), float(off[1])) if off else (0.0, 0.0)
            except Exception:
                ox, oy = 0.0, 0.0
            # 1) 真实鼠标点击 iframe 左侧的复选框位置
            try:
                loc = iframe.rect.location
                size = iframe.rect.size
                if size[1] > 0:
                    self._click_xy(ox + loc[0] + 30, oy + loc[1] + size[1] / 2.0)
                    time.sleep(0.4)
                    return True
            except Exception:
                pass
            # 2) 退回：尝试进 iframe 直接点 checkbox
            try:
                frame = self.page.get_frame(iframe)
                for csel in ('css:input[type="checkbox"]', 'css:.cb-lb',
                             'css:label', 'css:#checkbox'):
                    box = frame.ele(csel, timeout=0.5)
                    if box:
                        self._do_click(box)
                        time.sleep(0.3)
                        return True
            except Exception:
                pass
        return False

    def uc_gui_handle_captcha(self, **kwargs):
        return self.uc_gui_click_captcha(**kwargs)

    def uc_gui_click_cf(self, **kwargs):
        return self.uc_gui_click_captcha(**kwargs)

    # ---------------- 其它常用 ----------------
    def goto(self, url, **kwargs):
        return self.open(url)

    def set_window_size(self, width, height, **kwargs):
        try:
            self.page.set.window.size(int(width), int(height))
        except Exception:
            pass

    def maximize_window(self, **kwargs):
        try:
            self.page.set.window.max()
        except Exception:
            pass

    def get_user_agent(self):
        try:
            return self.page.run_js("return navigator.userAgent;")
        except Exception:
            return None

    def add_cookie(self, cookie_dict, **kwargs):
        try:
            self.page.set.cookies(cookie_dict)
        except Exception:
            pass

    def delete_all_cookies(self, **kwargs):
        try:
            self.page.set.cookies.clear()
        except Exception:
            pass

    def get_text_content(self, selector, **kwargs):
        el = self._require(selector, kwargs.get("timeout"))
        try:
            return el.raw_text
        except Exception:
            return el.text

    def is_element_displayed(self, selector, **kwargs):
        return self.is_element_visible(selector, **kwargs)

    def open_new_tab(self, url=None, **kwargs):
        tab = self.page.new_tab()
        if url:
            tab.get(url)
        return tab

    def switch_to_window(self, index=0, **kwargs):
        try:
            tabs = self.page.tabs
            if tabs:
                self.page = self.page.get_tab(tabs[index])
        except Exception:
            pass
        return self.page

    def switch_to_frame(self, selector, **kwargs):
        try:
            iframe = self._require(selector)
            return self.page.get_frame(iframe)
        except Exception:
            return None

    def switch_to_default_content(self, **kwargs):
        return None

    def get_new_driver(self, **kwargs):
        return self.page

    # ---------------- 截图 ----------------
    def save_screenshot(self, name="screenshot.png", **kwargs):
        folder = os.path.dirname(os.path.abspath(name))
        if folder and not os.path.exists(folder):
            os.makedirs(folder, exist_ok=True)
        self.page.get_screenshot(path=name, full_page=kwargs.get("full_page", False))
        return os.path.abspath(name)

    # ---------------- 兼容桩 ----------------
    @property
    def driver(self):
        return self.page

    def activate_cdp_mode(self, url=None, **kwargs):
        if url:
            self.page.get(url)
        return self.page

    def reconnect(self, *args, **kwargs):
        return None

    def bring_to_front(self):
        return None


# --------------------------------------------------------------------------
# 便捷函数 (部分脚本会用)
# --------------------------------------------------------------------------
def sb_cdp(url=None, **kwargs):
    sb = SB(uc=True, headed=True, **kwargs)
    sb._launch()
    if url:
        sb.page.get(url)
    return sb
