# Nur einmal pro Boot ausführen (verhindert Loops)
if [ -e /run/installer-ran ]; then
  return
fi
touch /run/installer-ran

# Nicht exec! Sonst endet die Shell bei Fehler -> getty loop
/usr/local/bin/install.sh || {
  echo
  echo "Installer failed. Dropping to shell."
  echo "Run: /usr/local/bin/install.sh"
}
