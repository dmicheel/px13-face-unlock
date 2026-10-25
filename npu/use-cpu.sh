#!/bin/sh
# Fall back to CPU inference: switch /etc/gaze/config.toml to cpu/cpu and restart gazed.
# The NPU registration stays in place, so npu/use-npu.sh switches back without recompiling.
#   --unregister   also remove the vitis runtime registration and the gazed drop-in
set -eu

[ "$(id -u)" -eq 0 ] || exec sudo sh "$0" "$@"

CONFIG=/etc/gaze/config.toml

sed -i -e 's/^execution_provider = ".*"/execution_provider = "cpu"/' \
       -e 's/^device = ".*"/device = "cpu"/' "$CONFIG"

if [ "${1:-}" = "--unregister" ]; then
    rm -rf /usr/lib/gaze/runtimes/vitis
    rm -f /etc/systemd/system/gazed.service.d/vitis.conf /usr/local/libexec/gaze-npu-cache-check
    systemctl daemon-reload
    echo "Removed the vitis runtime registration and gazed drop-in."
fi

systemctl restart gazed
echo "gazed restarted on the CPU."
