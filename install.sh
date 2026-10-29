#!/usr/bin/env bash
# ProArt PX13 face unlock with Gaze (RGB + IR camera).
# Run as a regular user; requests sudo when required.
#   bash install.sh [--no-greeter] [--no-overlay]
#   bash install.sh uninstall
#
# Installs gaze-bin, points it at the PX13 webcam, adds face auth to the
# Noctalia lock screen, noctalia-greeter and TTY login (sudo and polkit come
# with the package) and installs the Face ID-style overlay. Idempotent.
# NPU acceleration is separate: npu/install-sdk.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMERA=3277:0059
GAZE_CONFIG=/etc/gaze/config.toml
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
NOCTALIA_CONFIG="$CONFIG_HOME/noctalia/config.toml"
GREETER_CONFIG=/var/lib/noctalia-greeter/greeter.toml
OVERLAY_BIN="$HOME/.local/bin/gaze-overlay"
OVERLAY_UNIT="$CONFIG_HOME/systemd/user/gaze-overlay.service"
ORC_DROPIN=/etc/systemd/system/gazed.service.d/orc.conf
# Same lines gaze-bin puts into sudo and polkit-1, inserted after pam_nologin.
PAM_FAILLOCK='-auth       requisite     pam_faillock.so preauth'
PAM_GAZE='auth        sufficient    pam_gaze.so'

ACTION=install GREETER=1 OVERLAY=1 CHANGED=0
for arg in "$@"; do
  case "$arg" in
    uninstall) ACTION=uninstall ;;
    --no-greeter) GREETER=0 ;;
    --no-overlay) OVERLAY=0 ;;
    *) echo "usage: bash install.sh [--no-greeter] [--no-overlay] | uninstall" >&2; exit 2 ;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then
  echo "Error: run as your regular user (the overlay and Noctalia config are per user)." >&2
  exit 1
fi

# Prints FILE with KEY = VALUE in [SECTION]: replaces the key's first
# uncommented assignment there, else adds it below the section header, else
# appends the section. Reads the file twice (first pass: does the key exist).
# shellcheck disable=SC2016
TOML_SET='
  BEGIN { keyre = "^[[:space:]]*" key "[[:space:]]*=" }
  FNR == 1 { pass++ }
  /^[[:space:]]*\[/ { insec = ($0 ~ "^[[:space:]]*\\[" sec "\\]") }
  pass == 1 { if (insec) { seen = 1; if ($0 ~ keyre) has = 1 }; next }
  insec && !done && $0 ~ keyre { print key " = " val; done = 1; next }
  { print }
  insec && !done && !has && /^[[:space:]]*\[/ { print key " = " val; done = 1 }
  END { if (!seen) printf "%s[%s]\n%s = %s\n", (NR ? "\n" : ""), sec, key, val }'

# toml_set FILE SECTION KEY VALUE [sudo] -- sets CHANGED=1 if the file changed.
# cp onto the existing file keeps its owner and mode.
toml_set() {
  local file=$1 sec=$2 key=$3 val=$4 run=${5:-} tmp
  tmp="$(mktemp)"
  $run awk -v sec="$sec" -v key="$key" -v val="$val" "$TOML_SET" "$file" "$file" > "$tmp"
  if ! $run cmp -s "$tmp" "$file"; then
    $run cp "$tmp" "$file"
    CHANGED=1
  fi
  rm -f "$tmp"
}

toml_get() {  # FILE SECTION KEY -- prints the raw value
  sudo awk -v sec="$2" -v key="$3" '
    /^[[:space:]]*\[/ { insec = ($0 ~ "^[[:space:]]*\\[" sec "\\]") }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$1"
}

pam_add() {
  local file=$1
  if grep -q 'pam_gaze\.so' "$file"; then
    echo "    $file: already has pam_gaze"
    return
  fi
  grep -qE '^auth[[:space:]]+requisite[[:space:]]+pam_nologin\.so' "$file" ||
    { echo "Error: no 'auth requisite pam_nologin.so' line in $file to insert after" >&2; exit 1; }
  sudo sed -i -E "/^auth[[:space:]]+requisite[[:space:]]+pam_nologin\.so/a $PAM_FAILLOCK\n$PAM_GAZE" "$file"
  echo "    $file: added pam_gaze (sufficient, before the password)"
}

pam_remove() {
  local file=$1
  [ -f "$file" ] && grep -q 'pam_gaze\.so' "$file" || return 0
  sudo sed -i -E -e '/^auth[[:space:]]+sufficient[[:space:]]+pam_gaze\.so/d' \
    -e '/^-auth[[:space:]]+requisite[[:space:]]+pam_faillock\.so[[:space:]]+preauth/d' "$file"
  echo "    $file: removed pam_gaze"
}

camera_present() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "$CAMERA" ] && return 0
  done
  return 1
}

greeter_installed() { [ -f /etc/pam.d/greetd ] && pacman -Q noctalia-greeter >/dev/null 2>&1; }

if [ "$ACTION" = uninstall ]; then
  echo "==> Removing face auth from the lock screen, greeter and TTY login (requires sudo)"
  pam_remove /etc/pam.d/login
  pam_remove /etc/pam.d/greetd
  if [ -f "$NOCTALIA_CONFIG" ]; then
    toml_set "$NOCTALIA_CONFIG" lockscreen allow_empty_password false
    echo "    $NOCTALIA_CONFIG: allow_empty_password = false"
  fi
  if sudo test -f "$GREETER_CONFIG"; then
    toml_set "$GREETER_CONFIG" auth allow_empty_password false sudo
    echo "    $GREETER_CONFIG: allow_empty_password = false"
  fi

  echo "==> Removing the overlay"
  systemctl --user disable --now gaze-overlay 2>/dev/null || true
  rm -f "$OVERLAY_BIN" "$OVERLAY_UNIT"
  systemctl --user daemon-reload

  if [ -f "$ORC_DROPIN" ]; then
    echo "==> Removing the gazed ORC drop-in (requires sudo)"
    sudo rm -f "$ORC_DROPIN"
    sudo systemctl daemon-reload
    echo "    Removed $ORC_DROPIN"
  fi

  if [ -e /usr/lib/gaze/runtimes/vitis ]; then
    echo "==> Switching Gaze back to the CPU (requires sudo)"
    sh "$REPO/npu/use-cpu.sh" --unregister
  fi

  echo
  echo "==> Done. Gaze itself is still installed (sudo/polkit face auth, enrolled faces)."
  echo "    Remove it with: paru -Rns gaze-bin   (also cleans sudo and polkit-1)"
  echo "    NPU runtime (npu/install-sdk.sh): see README, 'Uninstall'."
  exit 0
fi

echo "==> 1/6 Gaze package and daemon (requires sudo)"
camera_present || {
  echo "Error: webcam USB $CAMERA not found; this repo targets the PX13 (HN7306)." >&2
  exit 1
}
if ! pacman -Q gaze-bin >/dev/null 2>&1; then
  # Not "gaze": that AUR package is an unrelated file watcher.
  if command -v paru >/dev/null; then paru -S --needed gaze-bin
  elif command -v yay >/dev/null; then yay -S --needed gaze-bin
  else echo "Error: install gaze-bin from the AUR first (no paru/yay found)." >&2; exit 1
  fi
fi
# GStreamer's ORC JIT maps its code from a file it deletes right away, so
# checkservices (cachy-update) flags gazed after every upgrade. Use ORC's C
# fallbacks instead; the frames are small.
ORC_CONF=$'[Service]\nEnvironment=ORC_CODE=backup'
if [ "$(cat "$ORC_DROPIN" 2>/dev/null)" != "$ORC_CONF" ]; then
  printf '%s\n' "$ORC_CONF" | sudo install -Dm644 /dev/stdin "$ORC_DROPIN"
  sudo systemctl daemon-reload
  sudo systemctl try-restart gazed
  echo "    Wrote $ORC_DROPIN"
fi
sudo systemctl enable --now gazed
echo "    $(pacman -Q gaze-bin), gazed $(systemctl is-active gazed)"

echo "==> 2/6 Cameras, security level, template encryption"
CHANGED=0
OLD_LEVEL="$(toml_get "$GAZE_CONFIG" security level)"
FACES="$(gaze list-faces 2>/dev/null || true)"    # before a restart: gazed may be loading
# Both nodes of the webcam (color and IR) by USB ID: survives /dev/videoN
# renumbering and needs no PipeWire session (greeter, TTY).
toml_set "$GAZE_CONFIG" cameras rgb "\"usb:$CAMERA\"" sudo
toml_set "$GAZE_CONFIG" cameras ir "\"usb:$CAMERA\"" sudo
# The IR emitter lights every other frame on its own; skip the dark ones.
toml_set "$GAZE_CONFIG" cameras emitter_enabled false sudo
toml_set "$GAZE_CONFIG" cameras dark_luma_threshold 20 sudo
toml_set "$GAZE_CONFIG" cameras parallel_capture '"auto"' sudo
# ResNet50 + SCRFD-10G, threshold 0.5; RGB and IR must both match.
toml_set "$GAZE_CONFIG" security level '"high"' sudo
if [ -e /dev/tpmrm0 ]; then
  toml_set "$GAZE_CONFIG" storage encrypt_templates true sudo
else
  echo "    No TPM (/dev/tpmrm0): templates stay unencrypted"
fi
if [ "$CHANGED" = 1 ]; then
  sudo systemctl restart gazed
  echo "    Updated $GAZE_CONFIG, restarted gazed"
else
  echo "    $GAZE_CONFIG already set"
fi
if [ -n "$OLD_LEVEL" ] && [ "$OLD_LEVEL" != '"high"' ] && grep -q '•' <<< "$FACES"; then
  echo "    WARNING: level changed from $OLD_LEVEL to \"high\"; templates are tied to the"
  echo "    recognizer model, so re-enroll: gaze remove-face <name> && gaze add-face <name>"
fi

echo "==> 3/6 TTY login and lock screen PAM (requires sudo)"
# Noctalia's lock screen authenticates against the hard-coded PAM service "login".
pam_add /etc/pam.d/login
for svc in sudo polkit-1; do
  grep -qs 'pam_gaze\.so' "/etc/pam.d/$svc" ||
    echo "    Note: /etc/pam.d/$svc has no pam_gaze (opted out?); no face auth there"
done

echo "==> 4/6 Noctalia lock screen"
if command -v noctalia >/dev/null; then
  mkdir -p "$(dirname "$NOCTALIA_CONFIG")"
  touch "$NOCTALIA_CONFIG"
  # PAM only runs after the password box is submitted; Enter on an empty box starts the face check.
  toml_set "$NOCTALIA_CONFIG" lockscreen allow_empty_password true
  echo "    $NOCTALIA_CONFIG: allow_empty_password = true"
else
  echo "    (skipped: noctalia not installed)"
fi

echo "==> 5/6 greetd / noctalia-greeter (requires sudo)"
if [ "$GREETER" = 0 ]; then
  echo "    (skipped: --no-greeter)"
elif ! greeter_installed; then
  echo "    (skipped: greetd PAM or noctalia-greeter not installed)"
else
  pam_add /etc/pam.d/greetd
  sudo chown root:root /etc/pam.d/greetd    # gaze doctor errors if it is user-owned
  sudo test -f "$GREETER_CONFIG" || sudo install -Dm644 -o greeter -g greeter /dev/null "$GREETER_CONFIG"
  toml_set "$GREETER_CONFIG" auth allow_empty_password true sudo
  sudo chown greeter:greeter "$GREETER_CONFIG"
  echo "    $GREETER_CONFIG: allow_empty_password = true"
fi

echo "==> 6/6 Face ID-style overlay"
if [ "$OVERLAY" = 0 ]; then
  echo "    (skipped: --no-overlay)"
else
  command -v cargo >/dev/null || {
    echo "Error: cargo not found: pacman -S rustup && rustup default stable (or --no-overlay)" >&2
    exit 1
  }
  MISSING="$(pacman -T gtk4 gtk4-layer-shell || true)"
  # shellcheck disable=SC2086
  [ -z "$MISSING" ] || sudo pacman -S --needed $MISSING
  cargo build --release --locked --manifest-path "$REPO/gaze-overlay/Cargo.toml"
  install -Dm755 "$REPO/gaze-overlay/target/release/gaze-overlay" "$OVERLAY_BIN"
  install -Dm644 "$REPO/gaze-overlay/gaze-overlay.service" "$OVERLAY_UNIT"
  systemctl --user daemon-reload
  systemctl --user enable gaze-overlay
  systemctl --user restart gaze-overlay 2>/dev/null ||
    echo "    (not started: no graphical session; starts with the next login)"
  echo "    Installed $OVERLAY_BIN and the gaze-overlay user service"
  # The overlay follows the gazed journal.
  id -nG | grep -qwE 'wheel|systemd-journal|adm' ||
    echo "    WARNING: no journal access; add yourself to systemd-journal and log in again"
fi

echo
gaze doctor 2>&1 | grep -E '^Summary|✗|⚠' | sed 's/^/    /' || true
if grep -q '•' <<< "$FACES"; then
  echo "==> Done. Test: sudo -k; sudo true"
else
  echo "==> Done. Enroll your face (in a real terminal): gaze add-face default"
fi
