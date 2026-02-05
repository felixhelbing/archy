# ~/.bash_profile

# Notausgang: bei Problemen einfach diese Datei anlegen
[ -f "$HOME/.no-hyprland" ] && return

# Nur auf der ersten TTY automatisch starten
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec Hyprland
fi

