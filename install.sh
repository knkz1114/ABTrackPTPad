#!/bin/zsh
# Builds ABTrackPTPad.app, installs it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-install}" in
  install)
    ./build.sh
    osascript -e 'tell application "ABTrackPTPad" to quit' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/ABTrackPTPad.app
    cp -R build/ABTrackPTPad.app /Applications/
    open /Applications/ABTrackPTPad.app
    echo "installed /Applications/ABTrackPTPad.app"
    echo "Grant Accessibility and Input Monitoring when prompted (System Settings > Privacy & Security)."
    ;;
  uninstall)
    osascript -e 'tell application "ABTrackPTPad" to quit' 2>/dev/null || true
    rm -rf /Applications/ABTrackPTPad.app
    echo "removed."
    ;;
  *)
    echo "usage: $0 [install|uninstall]"; exit 1 ;;
esac
