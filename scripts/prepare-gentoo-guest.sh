#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${USER_NAME:-reina}"
VNC_PASSWORD="${VNC_PASSWORD:-gentoo42}"

if [[ "$(id -u)" != "0" ]]; then
  echo "Run as root."
  exit 1
fi

if ! command -v emerge >/dev/null 2>&1; then
  echo "This script must run inside Gentoo."
  exit 1
fi

emerge --ask=n --verbose \
  app-admin/sudo \
  net-misc/openssh \
  net-misc/tigervnc \
  xfce-base/xfce4-meta \
  xfce-base/thunar \
  x11-terms/xfce4-terminal \
  app-misc/neofetch \
  www-client/firefox-bin \
  media-video/ffmpeg

if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -G wheel,audio,video,users -s /bin/bash "$USER_NAME"
fi

install -d -m 0755 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/90-wheel-nopasswd
chmod 0440 /etc/sudoers.d/90-wheel-nopasswd

runuser -u "$USER_NAME" -- mkdir -p "/home/$USER_NAME/.config/tigervnc"
printf '%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" n |
  runuser -u "$USER_NAME" -- vncpasswd "/home/$USER_NAME/.config/tigervnc/passwd"
chmod 0600 "/home/$USER_NAME/.config/tigervnc/passwd"

cat >"/home/$USER_NAME/.config/tigervnc/xsession" <<'EOF'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- startxfce4
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/tigervnc/xsession"
chmod +x "/home/$USER_NAME/.config/tigervnc/xsession"

cat >/etc/systemd/system/vncserver-"$USER_NAME".service <<EOF
[Unit]
Description=TigerVNC desktop for $USER_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=$USER_NAME
PAMName=login
PIDFile=/home/$USER_NAME/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -geometry 1366x768 -localhost no -alwaysshared
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

systemctl enable sshd
systemctl enable "vncserver-$USER_NAME.service"
systemctl set-default multi-user.target

echo "Prepared Gentoo guest for ez gentoo."
echo "VNC user: $USER_NAME"
echo "VNC display: :1"
echo "VNC password: $VNC_PASSWORD"

