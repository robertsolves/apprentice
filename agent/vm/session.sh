#!/bin/sh
# The Linux VM's screen, run by apprentice-browser.service inside its own D-Bus session: a virtual
# display, VNC so the user can step in, a window manager, the accessibility bus, and Chromium kept running.
export DISPLAY=:0
rm -f /tmp/.X0-lock
Xvfb :0 -screen 0 1280x800x24 -nolisten tcp &
for _ in $(seq 50); do [ -e /tmp/.X11-unix/X0 ] && break; sleep 0.1; done

# Only inside the guest: the user's Mac reaches it through an ssh tunnel (`apprentice vm look`).
x11vnc -display :0 -localhost -forever -shared -rfbport 5900 -rfbauth "$HOME/.vnc/passwd" -quiet -bg -o /tmp/x11vnc.log

# Windows get a frame, focus and a front; apps started over ssh or by the helper join this screen.
openbox >/tmp/openbox.log 2>&1 &
export QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1

# Chromium only builds its accessibility tree when the bus says a reader is on.
/usr/libexec/at-spi-bus-launcher --launch-immediately &
sleep 0.5
dbus-send --session --dest=org.a11y.Bus /org/a11y/bus org.freedesktop.DBus.Properties.Set \
  string:org.a11y.Status string:IsEnabled variant:boolean:true

# The helper reads this to join the same session. This user only: other users and apps in the guest
# have no business reading the session bus address (BOT_DETECTION V9).
(umask 077 && printf 'DBUS_SESSION_BUS_ADDRESS=%s\nDISPLAY=:0\n' "$DBUS_SESSION_BUS_ADDRESS" > /tmp/apprentice-session.env.new)
chmod 600 /tmp/apprentice-session.env.new
mv /tmp/apprentice-session.env.new /tmp/apprentice-session.env

# The host's language, so pages see the same languages as in the user's usual browser.
lang="${APPRENTICE_LANG:-en-US}"
export LANGUAGE="$(echo "$lang" | tr - _)"
while true; do
  ACCESSIBILITY_ENABLED=1 chromium --lang="$lang" --accept-lang="$lang,${lang%%-*}" --force-renderer-accessibility --no-first-run --no-default-browser-check \
    --password-store=basic --hide-crash-restore-bubble --disable-features=TranslateUI \
    --window-position=0,0 --window-size=1280,800 >/tmp/chromium.log 2>&1
  sleep 1
done
