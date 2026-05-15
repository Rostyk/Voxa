#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SRC="${ROOT}/build/VoxaMicDevice/VoxaMic.driver"
HAL="/Library/Audio/Plug-Ins/HAL"

if [[ ! -d "${DRIVER_SRC}" ]]; then
  echo "Missing ${DRIVER_SRC} — run ./build.sh first"
  exit 1
fi

echo "Removing old SinewaveDevice / VoxaMic if present"
rm -rf "${HAL}/SinewaveDevice.driver" "${HAL}/VoxaMic.driver"

echo "Installing VoxaMic.driver"
cp -R "${DRIVER_SRC}" "${HAL}/"
chown -R root:wheel "${HAL}/VoxaMic.driver"

echo "Restarting coreaudiod"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true

echo "Done. Look for \"Voxa Virtual Microphone\" in Sound settings."
echo "Keep Voxa.app running so it can capture your physical mic into the virtual device."
