#!/bin/sh
# gazed ExecStartPre (installed by npu/use-npu.sh). Gaze's cache key covers only the ORT
# path/version and the (pinned, see use-npu.sh) kernel version. This records what else the
# compiled NPU models depend on and drops the cache when it changes, so gazed recompiles
# (~8 min). Logs to gazed's journal; never fails, so it can't keep gazed from starting.

RUNTIME=/usr/lib/gaze/runtimes/vitis
PIN=$RUNTIME/osrelease
STAMP=$RUNTIME/compiled-with
CACHE=/var/cache/gaze/inference/vitis
ORT_LIB=/opt/ryzen-ai/venv/onnxruntime/lib
SP=/opt/ryzen-ai/venv/lib/python3.12/site-packages

hash() { sha256sum < "$1" 2>/dev/null | cut -c1-16; }
so_version() { readlink -f "$1" 2>/dev/null | sed 's/.*\.so\.//'; }

fingerprint() {
    echo "gaze $(pacman -Q gaze-bin 2>/dev/null | cut -d' ' -f2) $(hash /usr/bin/gazed)"
    sdk=$(ls -d "$SP"/voe-*.dist-info 2>/dev/null | sed 's/.*voe-//; s/\.dist-info$//')
    echo "sdk $sdk $(hash "$ORT_LIB/libonnxruntime_vitisai_ep.so")"
    echo "xrt $(so_version /usr/lib/libxrt_coreutil.so.2)"
    echo "xdna $(so_version /usr/lib/libxrt_driver_xdna.so.2)"
    # The firmware the NPU is running, not the files on disk: changes only after a reboot.
    echo "npu-fw $(cat /sys/class/accel/accel0/device/fw_version 2>/dev/null)"
}

current=$(fingerprint)

if [ ! -f "$STAMP" ] && [ -f "$PIN" ]; then
    # Setup from before this check: assume the existing cache matches what is installed.
    echo "NPU model cache: recording build inputs, no recompile"
elif [ ! -f "$PIN" ] || [ "$current" != "$(cat "$STAMP")" ]; then
    recorded=$(cat "$STAMP" 2>/dev/null)
    [ -n "$recorded" ] && printf '%s\n' "$current" | while read -r key value; do
        old=$(printf '%s\n' "$recorded" | awk -v k="$key" '$1 == k { sub(/^[^ ]+ /, ""); print }')
        [ "$old" = "$value" ] || echo "NPU model cache: $key changed: ${old:-none} -> $value"
    done
    echo "NPU model cache: recompiling, face auth is unavailable for ~8 min (passwords work)"
    rm -rf "$CACHE"
    cat /proc/sys/kernel/osrelease > "$PIN"
fi
printf '%s\n' "$current" > "$STAMP"

# Remove caches of other kernels/SDKs, but only if the current one is where we expect it.
ORT=$(readlink -f "$RUNTIME/libonnxruntime.so")
NS=$(printf '%s:%s:%s\n' "$ORT" "${ORT##*.so.}" "$(cat "$PIN")" | sha256sum | cut -d' ' -f1)
if [ -d "$CACHE/$NS" ]; then
    for dir in "$CACHE"/*/; do
        [ "$dir" = "$CACHE/$NS/" ] || rm -rf "$dir"
    done
fi
exit 0
