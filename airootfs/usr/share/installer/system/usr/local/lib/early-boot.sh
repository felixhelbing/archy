#!/bin/sh
set -eu

if [ -d /sys/class/backlight ] && ls /sys/class/backlight/* >/dev/null 2>&1; then
  for d in /sys/class/backlight/*; do
    if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
      max="$(cat "$d/max_brightness" 2>/dev/null || true)"
      [ -n "${max:-}" ] && echo "$max" > "$d/brightness" 2>/dev/null || true
    fi
  done
fi
