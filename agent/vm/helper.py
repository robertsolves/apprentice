"""apprentice's hands and eyes in the Linux VM.

The host's apprentice keeps one ssh connection open to this script and sends one JSON object per line.
Input ops (move, down, up, key, char, wheel) are played as they arrive, through XTest, the X server's
own input stream, so apps see them like a mouse and keyboard; the host keeps the timing. Query ops
(snap, focus, cursor, apps, launch, raise, ping) answer with one JSON line. A query names its app
(`app`, `pid`): Chromium is read as a web page, any other app as its window, in the same labels as the
macOS reader. Nothing here decides anything: approvals, pacing, budgets and logs all stay on the host.
"""

import base64
import json
import os
import subprocess
import sys
import time
import warnings
import zlib

warnings.simplefilter("ignore")


def load_env():
    try:
        with open("/tmp/apprentice-session.env") as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k:
                    os.environ[k] = v
    except OSError:
        pass


load_env()
# Qt apps build their accessibility tree only when asked to; GTK ones join the bus on their own.
os.environ.setdefault("QT_LINUX_ACCESSIBILITY_ALWAYS_ON", "1")

import gi  # noqa: E402

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402
from Xlib import X, XK, display  # noqa: E402
from Xlib.ext import xtest  # noqa: E402

dpy = display.Display(os.environ.get("DISPLAY", ":0"))
S = Atspi.StateType

# AT-SPI roles in apprentice's labels, the same ones the macOS reader prints.
CONTROLS = {
    "push button": "button", "button": "button", "toggle button": "button", "link": "link", "check box": "checkbox",
    "radio button": "radio", "page tab": "tab", "menu item": "menuitem", "check menu item": "menuitem",
    "radio menu item": "menuitem", "slider": "slider", "push button menu": "menubutton",
}
INPUTS = {"entry": "textbox", "password text": "password", "combo box": "combobox", "spin button": "textbox"}
# Roles only native toolkits (GTK, Qt) use; Chromium names the same things with the roles above.
NATIVE = {"menu": "menu", "list item": "cell", "table cell": "cell", "tree item": "cell", "icon": "button"}
BROWSERS = ("chromium", "google chrome", "chrome")
TOPLEVEL = ("frame", "dialog", "window", "alert", "file chooser")


def classify(a, role):
    if role in CONTROLS:
        return CONTROLS[role], "control"
    if role in NATIVE:
        return NATIVE[role], "control"
    if role == "terminal":
        return "terminal", "input"
    if role == "text":
        # A GTK text view: a field when it takes typing, else a block of text.
        return ("textarea", "input") if states(a).contains(S.EDITABLE) else ("text", "text")
    if role == "label" and (a.get_name() or "").strip():
        return "text", "text"
    if role in INPUTS:
        label = INPUTS[role]
        attrs = attributes(a)
        if label == "textbox":
            if attrs.get("xml-roles") == "searchbox" or attrs.get("text-input-type") == "search":
                label = "searchbox"
            elif states(a).contains(S.MULTI_LINE):
                label = "textarea"
        return label, "input"
    if role == "heading":
        return "heading", "heading"
    if role == "image":
        return "image", "image"
    if role == "static":
        return "text", "text"
    return None


def attributes(a):
    try:
        return a.get_attributes() or {}
    except Exception:
        return {}


def states(a):
    return a.get_state_set()


def clip(s, n):
    # Icon fonts draw with private-use characters, which read as nothing.
    s = "".join(c for c in (s or "") if not 0xE000 <= ord(c) <= 0xF8FF)
    flat = " ".join(s.replace('"', "'").split())
    return flat[:n] + "…" if len(flat) > n else flat


def text_of(a):
    try:
        if a.get_text_iface() is None:
            return None
        return Atspi.Text.get_text(a, 0, -1).replace("￼", "")
    except Exception:
        return None


def deep_text(a, budget=10):
    words, stack, seen = [], list(reversed(children(a))), 0
    while stack and len(words) < budget and seen < 200:
        el = stack.pop()
        seen += 1
        role = el.get_role_name()
        if role == "static":
            words += (el.get_name() or "").split()
        elif role == "image" and el.get_name():
            words.append(el.get_name())
        else:
            stack += list(reversed(children(el)))
    return " ".join(words[:budget])


def children(a):
    try:
        return [a.get_child_at_index(i) for i in range(a.get_child_count())]
    except Exception:
        return []


def extents(a):
    try:
        e = a.get_extents(Atspi.CoordType.SCREEN)
        return [e.x, e.y, e.width, e.height]
    except Exception:
        return None


def intersects(f, b):
    return f[2] > 0 and f[3] > 0 and f[0] < b[0] + b[2] and f[0] + f[2] > b[0] and f[1] < b[1] + b[3] and f[1] + f[3] > b[1]


# apprentice's own question window (ask.py): never a session's app, so the agent cannot answer it.
OWN = ("apprentice-ask",)


def apps_on_bus():
    desk = Atspi.get_desktop(0)
    return [a for a in children(desk) if a is not None and (a.get_name() or "").lower() not in OWN]


def pid_of(app):
    try:
        return app.get_process_id()
    except Exception:
        return 0


def is_browser(name):
    return (name or "").lower() in BROWSERS


def find_app(req):
    """The app a query names: its pid first (two windows of one name stay apart), then its name."""
    want = (req.get("app") or "chromium").lower()
    pid = int(req.get("pid") or 0)
    found = apps_on_bus()
    if is_browser(want):
        return next((a for a in found if is_browser(a.get_name())), None)
    if pid:
        hit = next((a for a in found if pid_of(a) == pid), None)
        if hit is not None:
            return hit
    return next((a for a in found if (a.get_name() or "").lower() == want), None) \
        or next((a for a in found if want in (a.get_name() or "").lower()), None)


def frame_of(app):
    """The app's window that is showing, the active one first. A nameless window (an open menu) is
    taken only when there is nothing else: it takes the focus but is not the page."""
    best = None
    for named in (True, False):
        for w in children(app):
            if w.get_role_name() not in TOPLEVEL or bool((w.get_name() or "").strip()) != named:
                continue
            st = states(w)
            f = extents(w)
            if f and st.contains(S.SHOWING) and (best is None or st.contains(S.ACTIVE)):
                best = (w, f)
        if best:
            return best
    return best


def document(window):
    """The web page in the tab in front: the showing document whose box is largest."""
    found = []
    stack = [(window, 0)]
    while stack:
        a, depth = stack.pop()
        role = a.get_role_name()
        if role == "document web":
            if states(a).contains(S.SHOWING):
                f = extents(a)
                if f and f[2] > 0 and f[3] > 0:
                    found.append((f[2] * f[3], a, f))
            continue
        if depth < 30:
            stack += [(c, depth + 1) for c in children(a)]
    if not found:
        return None
    found.sort(key=lambda x: -x[0])
    return found[0][1], found[0][2]


def url_of(doc):
    try:
        return doc.get_document_iface() and Atspi.Document.get_document_attribute_value(doc, "URI") or None
    except Exception:
        return None


def hit_box(a, f, bounds):
    """Where to click a link or button. Its box can span a whole result card (title, address, blank
    space) while only its text takes clicks, so aim at a heading inside it, else its first text."""
    first = None
    stack, seen = list(reversed(children(a))), 0
    while stack and seen < 60:
        el = stack.pop()
        seen += 1
        role = el.get_role_name()
        if role in ("heading", "static", "image"):
            e = extents(el)
            if e and e[2] > 2 and e[3] > 2 and intersects(e, bounds):
                if role == "heading":
                    return e
                if first is None and (role != "static" or (el.get_name() or "").strip()):
                    first = e
            if role != "heading":
                continue
        stack += list(reversed(children(el)))
    return first or f


def walk(a, path, depth, bounds, out, offscreen, field=None, seen=None):
    seen[0] += 1
    if seen[0] > 40000 or depth > 90:
        return
    role = a.get_role_name()
    f = extents(a)
    if field is not None and role == "static":
        t = a.get_name() or ""
        if t and t in field:
            return
    onscreen = f is not None and intersects(f, bounds)
    kind = classify(a, role)
    if kind:
        label, k = kind
        if k == "text":
            name = clip(a.get_name() or "", 100)
        elif k == "input":
            name = clip(a.get_name() or attributes(a).get("placeholder-text", ""), 60)
        else:
            name = clip(a.get_name() or "", 60) or clip(deep_text(a), 60)
        if (name or k == "input") and (onscreen or offscreen) and f:
            value = None
            if k == "input" and label not in ("password", "terminal"):
                value = clip(text_of(a) or "", 40)
            if k == "control" and label in ("link", "button"):
                f = hit_box(a, f, bounds)
            if label in ("checkbox", "radio", "tab"):
                st = states(a)
                value = "on" if st.contains(S.CHECKED) or st.contains(S.SELECTED) or st.contains(S.PRESSED) else "off"
            out.append({"path": path, "label": label, "name": name, "value": value, "frame": f,
                        "offscreen": not onscreen, "kind": k})
            if label == "terminal":
                terminal_lines(a, f, path, out)
                return
        # A named button or link owns its subtree: its text is already in its name.
        if k != "input" and label != "menubutton":
            return
    if not offscreen and f and f[2] > 0 and f[3] > 0 and not intersects(f, bounds):
        return
    sub = (text_of(a) or "") if kind and kind[1] == "input" else field
    for n, c in enumerate(children(a)):
        if c is not None:
            walk(c, path + [n], depth + 1, bounds, out, offscreen, sub, seen)


def page(req):
    app = find_app(req)
    name = req.get("app") or "Chromium"
    if app is None:
        raise RuntimeError("%s is not running in the VM" % name)
    win = frame_of(app)
    if win is None:
        raise RuntimeError("%s has no window" % name)
    window, wframe = win
    doc = document(window) if is_browser(app.get_name()) else None
    return app, window, wframe, doc


def popups(app, window):
    """The app's other showing windows: open menus, dialogs, suggestion lists."""
    out = []
    for n, w in enumerate(children(app)):
        if w is None or w is window:
            continue
        f = extents(w)
        if f and f[2] > 0 and f[3] > 0 and states(w).contains(S.SHOWING):
            out.append((n, w, f))
    return out


def terminal_lines(a, f, path, out):
    """A terminal's last screenful, as text lines under it, so `read` and the diff show its output."""
    text = text_of(a) or ""
    lines = [l for l in text.splitlines() if l.strip()][-30:]
    for n, line in enumerate(lines):
        out.append({"path": path + [-1 - n], "label": "text", "name": clip(line, 160), "value": None,
                    "frame": f, "offscreen": False, "kind": "text"})


def snap(req):
    app, window, wframe, doc = page(req)
    title = window.get_name() or ""
    if title.endswith(" - Chromium"):
        title = title[: -len(" - Chromium")]
    if not is_browser(app.get_name()):
        out = []
        walk(window, [], 0, wframe, out, bool(req.get("offscreen")), None, [0])
        for n, w, f in popups(app, window):
            walk(w, [1000 + n], 0, f, out, bool(req.get("offscreen")), None, [0])
        return {"url": None, "title": title, "scope": "window", "bounds": wframe, "elements": out,
                "busy": states(window).contains(S.BUSY)}
    if doc is None:
        return {"url": None, "title": title, "scope": "window", "bounds": wframe, "elements": [], "busy": True}
    root, dframe = doc
    # The intersection of the page and the window: edges first, then the size between them.
    left, top = max(dframe[0], wframe[0]), max(dframe[1], wframe[1])
    right = min(dframe[0] + dframe[2], wframe[0] + wframe[2])
    bottom = min(dframe[1] + dframe[3], wframe[1] + wframe[3])
    bounds = [left, top, max(right - left, 0), max(bottom - top, 0)]
    out = []
    walk(root, [], 0, bounds, out, bool(req.get("offscreen")), None, [0])
    # Chromium marks the page busy while it loads.
    busy = states(root).contains(S.BUSY)
    return {"url": url_of(root), "title": title, "scope": "web", "bounds": bounds, "elements": out, "busy": busy}


def focus(req):
    app, window, wframe, doc = page(req)
    stack = [(window, 0)] + [(w, 0) for _, w, _ in popups(app, window)]
    while stack:
        a, depth = stack.pop()
        st = states(a)
        if st.contains(S.FOCUSED):
            role = a.get_role_name()
            kind = classify(a, role)
            secret = role == "password text"
            return {"found": True, "label": kind[0] if kind else role, "name": a.get_name() or "",
                    "value": None if secret else text_of(a), "frame": extents(a), "secret": secret,
                    "editable": st.contains(S.EDITABLE)}
        if depth < 60 and st.contains(S.SHOWING):
            stack += [(c, depth + 1) for c in children(a) if c is not None]
    return {"found": False}


def cursor(req):
    p = dpy.screen().root.query_pointer()
    return {"x": p.root_x, "y": p.root_y}


# Key names as apprentice writes them, in X keysym names.
NAMES = {
    "return": "Return", "enter": "Return", "tab": "Tab", "space": "space", "backspace": "BackSpace",
    "delete": "BackSpace", "forwarddelete": "Delete", "esc": "Escape", "escape": "Escape", "home": "Home",
    "end": "End", "pageup": "Prior", "pagedown": "Next", "left": "Left", "right": "Right", "up": "Up",
    "down": "Down", "-": "minus", "=": "equal", "[": "bracketleft", "]": "bracketright", ";": "semicolon",
    "'": "apostrophe", ",": "comma", ".": "period", "/": "slash", "\\": "backslash", "`": "grave",
}
MODS = {"ctrl": "Control_L", "shift": "Shift_L", "alt": "Alt_L", "super": "Super_L"}
spare = []
remapped = {}  # keysym -> spare keycode mapped to it
held = {}


def keycode_for(keysym):
    """A keycode and whether it needs shift; a character with no key gets a spare keycode mapped to it."""
    for code, index in dpy.keysym_to_keycodes(keysym):
        if index in (0, 1):
            return code, index == 1
    if keysym in remapped:
        return remapped[keysym], False
    if not spare:
        first = dpy.display.info.min_keycode
        count = dpy.display.info.max_keycode - first + 1
        mapping = dpy.get_keyboard_mapping(first, count)
        spare.extend(first + i for i, syms in enumerate(mapping) if not any(syms))
    if not spare and remapped:
        # All spare keys are in use: the longest-held mapping is the one least likely to be typed again.
        spare.append(remapped.pop(next(iter(remapped))))
    if not spare:
        return None, False
    # A spare key, once mapped, is kept for its character: it is not handed out again for another one.
    code = spare.pop(0)
    dpy.change_keyboard_mapping(code, [(keysym,) * 2])
    dpy.sync()
    remapped[keysym] = code
    return code, False


def char_keysym(ch):
    if ch == "\n":
        return XK.string_to_keysym("Return")
    o = ord(ch)
    return o if o < 0x100 else 0x01000000 | o


def fake(kind, code):
    xtest.fake_input(dpy, kind, code)


def play(req):
    op = req["op"]
    if op == "move":
        xtest.fake_input(dpy, X.MotionNotify, x=int(round(req["x"])), y=int(round(req["y"])))
    elif op in ("down", "up"):
        fake(X.ButtonPress if op == "down" else X.ButtonRelease, int(req.get("b", 1)))
    elif op == "wheel":
        # Buttons 4/5 scroll up/down and 6/7 left/right; a negative n is down or right.
        if req.get("sideways"):
            button = 7 if req["n"] < 0 else 6
        else:
            button = 5 if req["n"] < 0 else 4
        for _ in range(abs(int(req["n"]))):
            fake(X.ButtonPress, button)
            fake(X.ButtonRelease, button)
    elif op == "key":
        # One key with its modifiers, pressed or released.
        name = req["key"]
        sym = XK.string_to_keysym(NAMES.get(name, name))
        code, _ = keycode_for(sym) if sym else (None, False)
        if code is None:
            return
        mods = [dpy.keysym_to_keycode(XK.string_to_keysym(MODS[m])) for m in req.get("mods", []) if m in MODS]
        if req["down"]:
            for m in mods:
                fake(X.KeyPress, m)
            fake(X.KeyPress, code)
        else:
            fake(X.KeyRelease, code)
            for m in reversed(mods):
                fake(X.KeyRelease, m)
    elif op == "char":
        ch = req["c"]
        if req["down"]:
            code, shift = keycode_for(char_keysym(ch))
            if code is None:
                return
            held[ch] = (code, shift)
            if shift:
                fake(X.KeyPress, dpy.keysym_to_keycode(XK.string_to_keysym("Shift_L")))
            fake(X.KeyPress, code)
        else:
            code, shift = held.pop(ch, (None, False))
            if code is None:
                return
            fake(X.KeyRelease, code)
            if shift:
                fake(X.KeyRelease, dpy.keysym_to_keycode(XK.string_to_keysym("Shift_L")))
    dpy.flush()


def apps(req):
    """The apps on the accessibility bus that show a window."""
    out = []
    for a in apps_on_bus():
        win = frame_of(a)
        if win is not None:
            out.append({"name": a.get_name() or "", "pid": pid_of(a), "title": win[0].get_name() or ""})
    return {"apps": out}


def launch(req):
    """Starts a program by name, without a shell, in the screen's session."""
    proc = subprocess.Popen([req["cmd"]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    return {"pid": proc.pid}


def raise_window(req):
    """Brings the app's window to the front, as the Mac's session window is brought forward."""
    app = find_app(req)
    if app is None:
        return {"raised": False}
    # A dialog open over the app (a file chooser) is where a person acts, so it keeps the keyboard.
    d = dialog(req)
    if d.get("open"):
        if not d.get("active"):
            subprocess.run(["wmctrl", "-i", "-a", hex(d["wid"])], timeout=3)
            return {"raised": True}
        return {"raised": False}
    win = frame_of(app)
    if win is not None and states(win[0]).contains(S.ACTIVE):
        return {"raised": False}
    pid = str(pid_of(app))
    try:
        listing = subprocess.run(["wmctrl", "-lp"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {"raised": False}
    for row in listing.splitlines():
        cols = row.split(None, 4)
        if len(cols) >= 3 and cols[2] == pid:
            subprocess.run(["wmctrl", "-i", "-a", cols[0]], timeout=3)
            return {"raised": True}
    return {"raised": False}


def shot(req):
    """The whole screen, as raw deflated BGRX rows; the host turns it into an image for `shot` and `ocr`."""
    root = dpy.screen().root
    g = root.get_geometry()
    raw = root.get_image(0, 0, g.width, g.height, X.ZPixmap, 0xFFFFFFFF).data
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    data = c.compress(raw) + c.flush()
    return {"w": g.width, "h": g.height, "data": base64.b64encode(data).decode()}


def dialog(req):
    """Whether a dialog window is open, such as the file chooser for an upload or a save. Asked of the
    window manager: Chromium's GTK file chooser is not on the accessibility bus."""
    root = dpy.screen().root
    atom = dpy.intern_atom
    clients = root.get_full_property(atom("_NET_CLIENT_LIST"), X.AnyPropertyType)
    dialog_type = atom("_NET_WM_WINDOW_TYPE_DIALOG")
    active = root.get_full_property(atom("_NET_ACTIVE_WINDOW"), X.AnyPropertyType)
    active = active.value[0] if active and len(active.value) else 0
    for wid in clients.value if clients else []:
        w = dpy.create_resource_object("window", wid)
        try:
            types = w.get_full_property(atom("_NET_WM_WINDOW_TYPE"), X.AnyPropertyType)
            transient = w.get_wm_transient_for()
            if (types and dialog_type in types.value) or transient:
                name = w.get_full_property(atom("_NET_WM_NAME"), X.AnyPropertyType)
                g = w.get_geometry()
                # python-xlib translates (0, 0) of `root` into w's space, i.e. minus w's origin: negated below.
                at = w.translate_coords(root, 0, 0)
                box = [-at.x, -at.y, g.width, g.height]
                # `active`: it has the keyboard, so keys typed now land in it.
                return {"open": True, "active": wid == active, "wid": wid, "frame": box, "title": name.value.decode("utf-8", "replace") if name else ""}
        except Exception:
            continue
    return {"open": False}


def waitclick(req):
    """For `show`: waits for the person, in the VM's screen, to press the mouse, and says where."""
    root = dpy.screen().root
    deadline = time.time() + float(req.get("timeout", 120))
    while time.time() < deadline:
        p = root.query_pointer()
        if p.mask & X.Button1Mask:
            while root.query_pointer().mask & X.Button1Mask and time.time() < deadline:
                time.sleep(0.01)
            return {"x": p.root_x, "y": p.root_y}
        time.sleep(0.02)
    return {"timeout": True}


def ask(req):
    """apprentice's little window on the VM's own screen (ask.py), for a session that lives here."""
    timeout = float(req.get("timeout", 120))
    try:
        p = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "ask.py")],
                           input=json.dumps(req), capture_output=True, text=True, timeout=timeout + 10)
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError) as e:
        return {"error": "the VM's window failed: %s" % e}


# The app's own accessibility events tell when the screen has settled, so the host reads it once
# instead of polling. Events wait on the bus while this script blocks on its input, so each line
# first takes them in (`hear`), and `mark` forgets the ones from before an action.
EVENTS = ("object:children-changed", "object:state-changed", "object:text-changed", "object:property-change",
          "document:load-complete", "object:selection-changed")
heard = {"last": 0.0, "count": 0}


def on_event(event):
    heard["last"] = time.monotonic()
    heard["count"] += 1


listener = Atspi.EventListener.new(on_event)
for name in EVENTS:
    listener.register(name)


def hear():
    ctx = GLib.MainContext.default()
    for _ in range(10000):
        if not ctx.pending():
            break
        ctx.iteration(False)


def mark():
    hear()
    heard["count"] = 0
    heard["last"] = 0.0


def quiet(req):
    """Waits for the app to go quiet: no event for `quiet` s after the last one, or none at all in the
    first `first` s (`fresh`: counting from now). Gives up at `max` s (a page that animates never goes quiet)."""
    if req.get("fresh"):
        mark()
    start = time.monotonic()
    first, still, most = float(req.get("first", 0.3)), float(req.get("quiet", 0.25)), float(req.get("max", 2))
    while True:
        hear()
        now = time.monotonic()
        if now - start >= most:
            return {"events": heard["count"], "quiet": False}
        if heard["count"] == 0 and now - start >= first:
            return {"events": 0, "quiet": True}
        if heard["count"] > 0 and now - max(heard["last"], start) >= still:
            return {"events": heard["count"], "quiet": True}
        time.sleep(0.01)


QUERIES = {"quiet": quiet, "ask": ask, "shot": shot, "dialog": dialog, "waitclick": waitclick, "snap": snap, "focus": focus, "cursor": cursor, "apps": apps, "launch": launch, "raise": raise_window,
           "ping": lambda r: {"pong": True, "hears": True}}


def env_stamp():
    """Changes when the screen session restarts or this script is updated (`vm install`)."""
    stamp = []
    for path in ("/tmp/apprentice-session.env", os.path.abspath(__file__)):
        try:
            stamp.append(os.stat(path).st_mtime)
        except OSError:
            stamp.append(0)
    return stamp


def main():
    started = env_stamp()
    pending = os.environ.pop("APPRENTICE_PENDING", None)
    while True:
        line = pending if pending is not None else sys.stdin.readline()
        pending = None
        if not line:
            break
        # The screen session restarted or this script was updated: start again, on the new bus and code,
        # with the same pipes, and handle this line there.
        if env_stamp() != started:
            os.environ["APPRENTICE_PENDING"] = line
            os.execv(sys.executable, [sys.executable, "-u"] + sys.argv)
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        op = req.get("op")
        if op == "mark":
            mark()
            continue
        hear()
        if op in QUERIES:
            try:
                reply = QUERIES[op](req)
            except Exception as e:  # The host turns this into an error for the command.
                reply = {"error": str(e)}
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()
        else:
            try:
                play(req)
            except Exception as e:
                sys.stderr.write("apprentice helper: %s: %s\n" % (op, e))
                sys.stderr.flush()


if __name__ == "__main__":
    main()
