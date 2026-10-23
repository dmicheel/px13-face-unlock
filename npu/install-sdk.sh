#!/usr/bin/env bash
# Installs AMD's Ryzen AI SDK for Gaze's NPU backend on Arch/CachyOS, then switches
# Gaze to the NPU (use-npu.sh). Run as a regular user; requests sudo when required.
#   bash npu/install-sdk.sh ~/Downloads/ryzen_ai-1.8.0.tgz
#
# The tarball needs an AMD account to download (see README). The SDK goes to
# /opt/ryzen-ai (~25 GB): gazed cannot see /home. Passes -a yes to AMD's installer,
# which accepts AMD's EULAs. Re-running skips the SDK install if it is in place.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK=/opt/ryzen-ai
SP=$SDK/venv/lib/python3.12/site-packages
ORT=$SDK/venv/onnxruntime/lib/libonnxruntime.so
LIMITS=/etc/security/limits.d/99-amdxdna.conf

die() { echo "Error: $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your regular user"
if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  [ -f "$ORT" ] || die "usage: bash npu/install-sdk.sh <path to ryzen_ai-1.8.0.tgz>"
fi
TARBALL="$(realpath "${1:-/dev/null}")"
[ -e /dev/accel/accel0 ] || die "no NPU at /dev/accel/accel0 (amdxdna driver not loaded)"

echo "==> 1/4 NPU runtime (XRT) and memlock limit (requires sudo)"
# Arch's XRT is enough; AMD's XRT .debs are not needed.
sudo pacman -S --needed xrt xrt-plugin-amdxdna patchelf uv
# For xrt-smi and the SDK's quicktest after the next login; gazed gets its own limit.
printf '* soft memlock unlimited\n* hard memlock unlimited\n' | sudo tee "$LIMITS" >/dev/null
NPU_ROW="$(sudo prlimit --memlock=unlimited:unlimited xrt-smi examine 2>/dev/null | grep -E '^\|\[' || true)"
[ -n "$NPU_ROW" ] || die "xrt-smi does not see the NPU"
echo "    ${NPU_ROW%%$'\n'*}"

echo "==> 2/4 Ryzen AI SDK in $SDK"
if [ -f "$ORT" ]; then
  echo "    already installed (to reinstall: sudo rm -rf $SDK)"
else
  # AMD's installer needs Python 3.12; take a standalone one from uv.
  sudo install -d -o "$USER" -g "$(id -gn)" "$SDK"
  uv python install 3.12 --install-dir "$SDK/python" --no-bin
  PY_BIN="$(find "$SDK/python" -maxdepth 2 -path '*/cpython-3.12.*-linux-x86_64-gnu/bin' | head -n1)"
  [ -n "$PY_BIN" ] || die "uv did not install Python 3.12 under $SDK/python"
  rm -rf "$SDK/_src"
  mkdir "$SDK/_src"
  tar -xzf "$TARBALL" -C "$SDK/_src"
  # It ends with dpkg errors for linux-libc-dev and zip (Arch has linux-api-headers, zip
  # is unused), so check the result instead of the exit code.
  (cd "$SDK/_src" && PATH="$PY_BIN:$PATH" bash ./install_ryzen_ai.sh -a yes -p "$SDK/venv") || true
  rm -rf "$SDK/_src"
  [ -f "$ORT" ] || die "SDK install failed, $ORT missing (see the output above)"
  echo "    Installed"
fi

echo "==> 3/4 Arch compatibility fixes (requires sudo)"
# glibc >= 2.41 refuses libraries flagged with an executable stack.
sudo patchelf --clear-execstack "$SP/onnxruntime/capi/onnxruntime_pybind11_state.so" \
  "$SP/lib/lnx64.o/libsystemc.so"
# Arch ships only the wide-char ncurses; the SDK wants libncurses.so.6.
sudo mkdir -p "$SDK/compat/lib"
sudo ln -sfn /usr/lib/libncursesw.so.6 "$SDK/compat/lib/libncurses.so.6"
echo "    Cleared executable-stack flags, linked libncurses.so.6"

echo "==> 4/4 Switching Gaze to the NPU"
exec sh "$HERE/use-npu.sh"
