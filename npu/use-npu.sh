#!/bin/sh
# Run Gaze inference on the AMD NPU (Ryzen AI SDK in /opt/ryzen-ai, from npu/install-sdk.sh).
# Registers the SDK as Gaze's "vitis" runtime, gives gazed the environment the SDK needs on
# Arch/CachyOS, switches /etc/gaze/config.toml to vitis/npu and restarts gazed.
# Idempotent. Undo with npu/use-cpu.sh (add --unregister to remove everything this creates).
#   --recompile   drop the compiled-model cache and re-pin it to the running kernel
set -eu

[ "$(id -u)" -eq 0 ] || exec sudo sh "$0" "$@"

SDK=/opt/ryzen-ai
ORT_LIB=$SDK/venv/onnxruntime/lib
SP=$SDK/venv/lib/python3.12/site-packages
PY_LIB=$(ls -d "$SDK"/python/cpython-3.12.*-linux-x86_64-gnu/lib 2>/dev/null | head -n1 || true)
RUNTIME=/usr/lib/gaze/runtimes/vitis
DROPIN=/etc/systemd/system/gazed.service.d
CONFIG=/etc/gaze/config.toml
CACHE=/var/cache/gaze/inference/vitis
PIN=$RUNTIME/osrelease

die() { echo "error: $*" >&2; exit 1; }

[ -f "$ORT_LIB/libonnxruntime.so" ] || die "$ORT_LIB/libonnxruntime.so missing — run npu/install-sdk.sh first"
[ -n "$PY_LIB" ] && [ -f "$PY_LIB/libpython3.12.so.1.0" ] || die "Python 3.12 not found under $SDK/python"
[ -e "$SDK/compat/lib/libncurses.so.6" ] || die "$SDK/compat/lib/libncurses.so.6 missing (run npu/install-sdk.sh)"
[ -f /usr/lib/libxrt_coreutil.so.2 ] || die "XRT missing: pacman -S xrt xrt-plugin-amdxdna"

# Gaze refuses vendor runtimes that are not root-owned or are writable by others.
chown -R root:root "$SDK"
chmod -R go-w "$SDK"

# Runtime registration. ONNX Runtime looks for its provider libraries next to the path it
# was loaded from (this symlink), so link the provider libraries here as well.
install -d -m 755 "$RUNTIME"
for lib in libonnxruntime.so libonnxruntime_providers_shared.so libonnxruntime_providers_vitisai.so \
           libonnxruntime_vitisai_ep.so libonnxruntime_vitis_ai_custom_ops.so libonnxruntime_providers_ryzenai.so; do
    ln -sfn "$ORT_LIB/$lib" "$RUNTIME/$lib"
done
# SDK libs, flexml/voe libs, peano (needed by the VitisAI EP), libncurses.so.6 compat link,
# libpython3.12.so (needed by libflexmlrt).
printf '%s\n' "$ORT_LIB:$SP/flexml/flexml_extras/lib:$SP/voe/lib:$SP/lnx64.o/tools/peano/lib:$SDK/compat/lib:$PY_LIB" \
    > "$RUNTIME/library-path"

# Gaze keys its compiled-model cache on sha256("<ORT path>:<ORT version>:<osrelease>"), so
# every kernel update would recompile (~8 min). The NPU binaries don't depend on the kernel,
# so gazed sees a pinned osrelease instead; the key then only changes with the SDK.
if [ "${1:-}" = "--recompile" ]; then
    rm -rf "$CACHE" "$PIN"
fi
[ -f "$PIN" ] || cat /proc/sys/kernel/osrelease > "$PIN"

# Remove caches of other kernels/SDKs, but only if the current one is where we expect it.
ORT=$(readlink -f "$RUNTIME/libonnxruntime.so")
NS=$(printf '%s:%s:%s\n' "$ORT" "${ORT##*.so.}" "$(cat "$PIN")" | sha256sum | cut -d' ' -f1)
if [ -d "$CACHE/$NS" ]; then
    for dir in "$CACHE"/*/; do
        [ "$dir" = "$CACHE/$NS/" ] || rm -rf "$dir"
    done
fi

# gazed environment.
#  - WorkingDirectory: the NPU compiler needs a writable cwd; "/" is read-only under
#    ProtectSystem=strict and the compiler aborts the whole daemon otherwise.
#  - LD_PRELOAD: the SDK bundles libxrt_coreutil 2.19, which breaks Arch's XRT.
#  - LimitMEMLOCK: the NPU maps locked buffers far larger than the 8 MB default.
#  - BindReadOnlyPaths: the pinned osrelease (see above); uname() still reports the real kernel.
install -d -m 755 "$DROPIN"
cat > "$DROPIN/vitis.conf" <<EOF
[Service]
WorkingDirectory=/var/cache/gaze
Environment=PATH=$SDK/venv/bin:/usr/bin
Environment=XILINX_XRT=/usr
Environment=XILINX_VITIS=$SP
Environment=XILINX_VITIS_AIETOOLS=$SP
Environment=LD_PRELOAD=/usr/lib/libxrt_coreutil.so.2
LimitMEMLOCK=infinity
BindReadOnlyPaths=$PIN:/proc/sys/kernel/osrelease
EOF

sed -i -e 's/^execution_provider = ".*"/execution_provider = "vitis"/' \
       -e 's/^device = ".*"/device = "npu"/' "$CONFIG"

systemctl daemon-reload
systemctl restart gazed

echo "gazed restarted on the NPU. The first start after an SDK change (or --recompile) compiles"
echo "the models (~8 min); face auth is unavailable until this shows up:"
echo "  journalctl -u gazed -f | grep -m1 'Models & user DB loaded'"
