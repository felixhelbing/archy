# ~/.bash_profile

path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}

path_prepend "$HOME/.local/bin"
path_prepend "$HOME/bin"

. ~/.bashrc

export PATH

# Notausgang: bei Problemen einfach diese Datei anlegen
[ -f "$HOME/.no-hyprland" ] && return

# Nur auf der ersten TTY automatisch starten
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec Hyprland
fi

