"""apprentice's little window, inside the VM: a question, choices or a text field, on the VM's own screen.

The helper runs this for a session that lives in the VM, so the user answers where the work is, as on
the Mac. It reads one JSON object on stdin (question, choices, multi, withText, timeout, sendTitle,
checked, placeholder, initialText) and prints one: {"chosen": [...], "text": "...", "skipped": bool},
or {"timeout": true}.
"""

import json
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib  # noqa: E402

# Its own name on the accessibility bus, so the helper never lets a session bind this window and
# answer apprentice's own question with the agent's clicks (the Mac's window is not an app to bind either).
GLib.set_prgname("apprentice-ask")
from gi.repository import Gtk  # noqa: E402

req = json.loads(sys.stdin.read() or "{}")
result = {"timeout": True}

win = Gtk.Window(title="apprentice")
win.set_keep_above(True)
win.set_position(Gtk.WindowPosition.CENTER)
win.set_default_size(420, -1)
win.set_border_width(14)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
win.add(box)

label = Gtk.Label(label=req.get("question", ""))
label.set_line_wrap(True)
label.set_max_width_chars(60)
label.set_xalign(0)
box.pack_start(label, False, False, 0)

choices = req.get("choices") or []
multi = bool(req.get("multi"))
checked = set(req.get("checked") or [])
with_text = bool(req.get("withText"))
checks = []
entry = None


def finish(chosen, skipped=False):
    global result
    result = {"chosen": chosen, "text": entry.get_text() if entry else "", "skipped": skipped}
    Gtk.main_quit()


if multi:
    for c in choices:
        cb = Gtk.CheckButton(label=c)
        cb.set_active(c in checked)
        box.pack_start(cb, False, False, 0)
        checks.append(cb)
elif choices and not with_text:
    # One click answers, as the Mac window's choice buttons do.
    row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    for c in choices:
        b = Gtk.Button(label=c)
        b.connect("clicked", lambda _b, c=c: finish([c]))
        row.pack_start(b, False, False, 0)
    box.pack_start(row, False, False, 0)
elif choices:
    # GTK always selects one radio of a group; a hidden one holds that, so no choice is made for the user.
    group = Gtk.RadioButton.new_with_label_from_widget(None, "")
    for c in choices:
        rb = Gtk.RadioButton.new_with_label_from_widget(group, c)
        rb.set_active(c in checked)
        box.pack_start(rb, False, False, 0)
        checks.append(rb)

if with_text:
    entry = Gtk.Entry()
    entry.set_placeholder_text(req.get("placeholder") or "")
    entry.set_text(req.get("initialText") or "")
    entry.connect("activate", lambda _e: send())
    box.pack_start(entry, False, False, 0)


def send():
    finish([c.get_label() for c in checks if c.get_active()])


buttons = Gtk.Box(spacing=8)
skip = Gtk.Button(label="Skip")
skip.connect("clicked", lambda _b: finish([], skipped=True))
buttons.pack_end(skip, False, False, 0)
if multi or with_text or (choices and with_text) or not choices:
    ok = Gtk.Button(label=req.get("sendTitle") or "Send")
    ok.connect("clicked", lambda _b: send())
    buttons.pack_end(ok, False, False, 0)
box.pack_end(buttons, False, False, 0)

win.connect("delete-event", lambda *_: finish([], skipped=True) or True)
GLib.timeout_add(int(float(req.get("timeout", 120)) * 1000), lambda: Gtk.main_quit() or False)
win.show_all()
win.present()
Gtk.main()
print(json.dumps(result))
