#!/bin/sh
# Turns a plain Debian guest into apprentice's Linux VM. Run as root by `apprentice vm setup` and
# `vm install`, with the files of agent/vm in /tmp/apprentice-vm. Safe to run again.
set -eu
user="$1"
password="$2"
zone="$3"
lang="${4:-en-US}"
src=/tmp/apprentice-vm

if ! command -v chromium >/dev/null || ! command -v Xvfb >/dev/null || ! command -v openbox >/dev/null \
  || ! ls /usr/lib/*/girepository-1.0/Gtk-3.0.typelib >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # No desktop: a virtual display, VNC, a window manager, Chromium, a terminal, and what reads their
  # accessibility trees and types into them. Other apps are one `apt-get install` away, over ssh.
  apt-get install -y -qq --no-install-recommends xvfb x11vnc openbox wmctrl xfce4-terminal chromium \
    at-spi2-core gir1.2-atspi-2.0 python3-gi python3-xlib dbus-bin dbus-x11 \
    gir1.2-gtk-3.0 fonts-dejavu-core fonts-noto-color-emoji ca-certificates >/dev/null
  apt-get clean
fi

install -d /opt/apprentice
# The screen restarts only when its own script changed, so an update to the helper keeps the pages open.
restart=1
cmp -s "$src/session.sh" /opt/apprentice/session.sh && systemctl is-active -q apprentice-browser.service && restart=0
install -m 755 "$src/session.sh" /opt/apprentice/session.sh
install -m 644 "$src/helper.py" /opt/apprentice/helper.py
install -m 644 "$src/ask.py" /opt/apprentice/ask.py

# Credentials and payment details stay the user's: the agent has a shell in this guest as the same user,
# so Chromium here saves no passwords or cards for it to read back or fill in. Sign-ins live on in cookies.
install -d /etc/chromium/policies/managed
printf '{"PasswordManagerEnabled": false, "AutofillCreditCardEnabled": false}\n' > /etc/chromium/policies/managed/apprentice.json

home="$(getent passwd "$user" | cut -d: -f6)"
install -d -o "$user" "$home/.vnc"
su "$user" -c "x11vnc -storepasswd '$password' '$home/.vnc/passwd' >/dev/null 2>&1"

unit=/etc/systemd/system/apprentice-browser.service
old="$(cat "$unit" 2>/dev/null || true)"
cat > "$unit" <<EOF
[Unit]
Description=apprentice browser screen
After=network-online.target

[Service]
User=$user
Environment=HOME=$home
Environment=APPRENTICE_LANG=$lang
ExecStart=/usr/bin/dbus-run-session -- /opt/apprentice/session.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
[ "$old" = "$(cat "$unit")" ] || restart=1
systemctl daemon-reload
systemctl enable apprentice-browser.service >/dev/null 2>&1
[ "$restart" = 1 ] && systemctl restart apprentice-browser.service

# The same time zone as the host, so pages see the same zone as the user's usual browser (SPEC.md,
# Consistency); the language comes in through APPRENTICE_LANG.
timedatectl set-timezone "$zone" 2>/dev/null || true

# Plain ssh commands reach the screen, so a GUI app started from the terminal shows there.
grep -q '^DISPLAY=' /etc/environment 2>/dev/null || echo 'DISPLAY=:0' >> /etc/environment
grep -q '^QT_LINUX_ACCESSIBILITY_ALWAYS_ON=' /etc/environment || echo 'QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1' >> /etc/environment
echo provisioned
