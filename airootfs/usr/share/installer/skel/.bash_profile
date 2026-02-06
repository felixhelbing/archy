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

if [ ! -f "$HOME/.no-hyprland" ]; then
  if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec Hyprland
  fi
fi

