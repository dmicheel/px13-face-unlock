# PX13 face unlock

Windows Hello-style face unlock on the ASUS ProArt PX13 (HN7306) under
CachyOS/Arch with niri and Noctalia, using [Gaze](https://github.com/GunduLabs/gaze)
with the built-in RGB **and** IR cameras, optionally on the Ryzen AI NPU. Adds
a Face ID-style overlay that shows while Gaze is scanning.

| Where | How |
|---|---|
| `sudo`, polkit prompts | automatic |
| Noctalia lock screen | press **Enter** on the empty password box |
| noctalia-greeter (after logout) | press **Enter** on the empty password box |
| TTY console login | automatic after entering the user name |
| Boot | unchanged (LUKS passphrase, greetd autologin) |

The password keeps working everywhere as fallback (`pam_gaze.so` is
`sufficient`, placed before the normal stack).

Tested with kernel 7.3.0-cachyos, gaze 0.3.10, noctalia 5.3.0,
noctalia-greeter 1.7.0, Ryzen AI SDK 1.8.0 and xrt 2.21.75.

## Install

```sh
bash install.sh                  # --no-greeter / --no-overlay skip those parts
gaze add-face default            # enroll; run in a real terminal (TUI)
```

Runs as a regular user (asks for sudo) and is idempotent. It needs an AUR
helper (`paru` or `yay`) for `gaze-bin`, and Rust for the overlay
(`pacman -S rustup && rustup default stable`). Without Noctalia or
noctalia-greeter installed, those steps are skipped.

To keep `sudo` free of face auth, create `/etc/gaze/pam-sudo.optout` **before**
installing.

## What it installs

- **Gaze** (`gaze-bin` from the AUR, *not* `gaze`, an unrelated file
  watcher) and the `gazed` daemon. The package itself adds `pam_gaze` to
  `sudo` and `polkit-1`.
- **Gaze config** (`/etc/gaze/config.toml`):
  - both cameras by the webcam's USB ID (`usb:3277:0059`): Gaze resolves the
    color and IR nodes (`/dev/video0`, `/dev/video2`) itself, which survives
    external cameras renumbering `/dev/videoN` and needs no PipeWire session
    (greeter, TTY),
  - `emitter_enabled = false` and `dark_luma_threshold = 20`: the IR emitter
    works out of the box (no `linux-enable-ir-emitter`) and lights every
    other frame; the dark frames are skipped,
  - `parallel_capture = "auto"`: RGB and IR are captured at the same time,
  - `level = "high"`: ResNet50 + SCRFD-10G, threshold 0.5, and RGB **and** IR
    must both match (IR alone when the RGB image is too dark),
  - `encrypt_templates = true` if a TPM is present: face templates are
    sealed with the TPM. If the TPM becomes unusable, `gazed` refuses to start
    (passwords still work).
- **PAM** (`/etc/pam.d/login`, `/etc/pam.d/greetd`): `pam_faillock preauth`
  and `pam_gaze` after `pam_nologin`, the same lines the package uses for
  `sudo`. Noctalia's lock screen authenticates against the hard-coded service
  `login`, so this also covers TTY logins.
- **Empty-password submit** (`allow_empty_password = true` in
  `~/.config/noctalia/config.toml` `[lockscreen]` and
  `/var/lib/noctalia-greeter/greeter.toml` `[auth]`): both only run PAM after
  the password box is submitted, so Enter on an empty box starts the face
  check.
- **Overlay** (`gaze-overlay/`, Rust + GTK4 layer shell, installed to
  `~/.local/bin` with a `gaze-overlay` user service): a small HUD at the bottom
  of the focused screen, with a scan line while scanning, then a green check
  or a red shake. It is click-through and never takes focus. `gazed` sends
  progress signals only to the client that started the scan, so the overlay
  follows the `gazed` journal (needs journal access, e.g. the `wheel` group).
  It is skipped on the lock screen and greeter: niri draws nothing above a
  session lock. Preview: `gaze-overlay --demo`.

Templates are tied to the recognizer model: after changing `level`,
re-enroll (`gaze remove-face default && gaze add-face default`), otherwise
nothing matches. Add captures later with `gaze refine-face default`.

## NPU acceleration (optional)

Runs detector, recognizer and liveness on the NPU (`amdxdna`,
`/dev/accel/accel0`) through AMD's Ryzen AI SDK (Gaze's `vitis` provider).
Unlock time stays about the same (~1 s; ResNet50 ~30 ms on the NPU vs ~15 ms
on the CPU); the gain is offloading the CPU. Needs ~25 GB in `/opt/ryzen-ai`.

Download `ryzen_ai-1.8.0.tgz` (the **installer**, not the driver zip) from
AMD's Ryzen AI Software page on account.amd.com (AMD account and EULA
required; see AMD's [Linux install guide](https://ryzenai.docs.amd.com/en/latest/linux.html)), then:

```sh
bash npu/install-sdk.sh ~/Downloads/ryzen_ai-1.8.0.tgz
journalctl -u gazed -f | grep -m1 'Models & user DB loaded'   # first start: ~8 min
```

The first start compiles all models for the NPU: about 8 minutes without
face auth (passwords work). The result is cached in
`/var/cache/gaze/inference/vitis/`; later starts take ~3 s, also after kernel
updates. Only a change to Gaze, the SDK, XRT or the NPU firmware recompiles
(see below).

`npu/install-sdk.sh` passes `-a yes` to AMD's installer, which accepts AMD's
EULAs. It:

- installs `xrt`, `xrt-plugin-amdxdna` (Arch's XRT is enough), `patchelf`,
  `uv`, and an unlimited memlock limit (`/etc/security/limits.d/99-amdxdna.conf`,
  for `xrt-smi` after the next login),
- installs the SDK into `/opt/ryzen-ai/venv` with a standalone Python 3.12
  from `uv` (gazed can't see `/home`). AMD's installer ends with `dpkg` errors
  for `linux-libc-dev` and `zip`; they don't matter on Arch,
- clears the executable-stack flag on two SDK libraries (glibc >= 2.41
  refuses them) and links `libncurses.so.6` to Arch's `libncursesw.so.6`,
- runs `npu/use-npu.sh`.

`npu/use-npu.sh` (re-runs itself with sudo, idempotent):

- makes `/opt/ryzen-ai` root-owned and not writable by others (Gaze requires it),
- registers the SDK in `/usr/lib/gaze/runtimes/vitis/`: `libonnxruntime.so`
  plus the provider libraries, and a `library-path` with the SDK, peano,
  compat and Python library directories,
- writes the `gazed` drop-in `/etc/systemd/system/gazed.service.d/vitis.conf`:
  - `WorkingDirectory=/var/cache/gaze`: the NPU compiler needs a writable
    working directory, otherwise it aborts the daemon,
  - `LD_PRELOAD=/usr/lib/libxrt_coreutil.so.2`: the SDK bundles an older,
    incompatible copy,
  - `XILINX_XRT`, `XILINX_VITIS`, `XILINX_VITIS_AIETOOLS`, `PATH`,
    `LimitMEMLOCK=infinity`,
  - `BindReadOnlyPaths=…/vitis/osrelease:/proc/sys/kernel/osrelease`: Gaze
    hashes the kernel version into the cache key, so every kernel update
    would recompile. gazed sees the kernel version from the first run instead
    (`uname -r` is unaffected); the compiled NPU binaries don't depend on the
    kernel,
  - `ExecStartPre=-+/usr/local/libexec/gaze-npu-cache-check`
    (`npu/cache-check.sh`): records what Gaze's cache key misses (the `gazed`
    binary, the SDK's compiler, XRT, the running NPU firmware) in
    `…/vitis/compiled-with`. When any of it changes, e.g. on a `gaze-bin`
    update, it logs the change, drops the cache and re-pins the kernel
    version, so gazed recompiles. It also deletes caches of older kernels/SDKs,
- sets `execution_provider = "vitis"`, `device = "npu"` and restarts gazed.

Switching:

```sh
sh npu/use-cpu.sh                # back to the CPU; registration stays
sh npu/use-npu.sh                # back to the NPU, no recompile
sh npu/use-npu.sh --recompile    # force a recompile, re-pin to the running kernel
sh npu/use-cpu.sh --unregister   # also remove the registration and the drop-in
```

`gaze doctor --benchmark` times out with the NPU runtime: it builds its own
sessions, which compiles in the CLI process. Use the journal instead.

## Verify

```sh
gaze doctor                      # expect 0 errors
sudo -k; sudo true               # should pass without a password prompt
journalctl -u gazed -f           # "Face auth requested service=..." per attempt

# NPU: four sessions (detector, recognizer ×2, liveness), no "Accelerator setup failed"
journalctl -u gazed -b | grep -E 'Loaded accelerated|Accelerator setup failed'
```

The IR camera in a live view (flickers: lit and dark frames):

```sh
ffplay -f v4l2 -input_format gray -video_size 640x400 /dev/video2
```

Match scores and liveness per frame are logged at debug level:

```sh
printf '[Service]\nEnvironment=RUST_LOG=info,gazed=debug\n' | sudo tee /etc/systemd/system/gazed.service.d/debug.conf
sudo systemctl daemon-reload && sudo systemctl restart gazed
# ... test, then remove debug.conf again and restart
```

## Troubleshooting

- **Nothing matches after changing `level`** — re-enroll (see above).
- **No overlay** — `journalctl --user -u gaze-overlay`; your user needs
  journal access (`wheel` or `systemd-journal`). Not shown on the lock screen
  and greeter by design.
- **`gaze doctor` errors on `/etc/pam.d/greetd` permissions** — it must be
  root-owned; re-run `bash install.sh`.
- **`vitis is configured but not registered`** or **`Failed to load library
  .../libonnxruntime_providers_shared.so`** — re-run `sh npu/use-npu.sh`.
- **`libpeano-lib.so...` / `libncurses.so.6: cannot open shared object`**,
  **`cannot enable executable stack`** — re-run `bash npu/install-sdk.sh`
  (e.g. after reinstalling the SDK).
- **`undefined symbol: xrt_core::smi::get_option_options`** — the SDK's
  bundled `libxrt_coreutil` was loaded; the drop-in's `LD_PRELOAD` is missing.
- **`Failed to open ".../aie_unsupported_original_ops.json"` + daemon crash**
  — the compiler ran with a read-only working directory; `WorkingDirectory`
  is missing from the drop-in.
- **`mmap(...) failed (err=-11)`** — memlock limit too low.
- **No face detected on the NPU, or `Accelerator setup failed`/crash after an
  update** — stale compiled models: `sh npu/use-npu.sh --recompile`. The
  cache check logs its decisions: `journalctl -u gazed | grep 'NPU model cache'`.
- **Face auth stops matching on the NPU** — check scores with debug logging;
  fall back with `sh npu/use-cpu.sh`.

## Known limitations

- **Empty Enter + failed face = faillock strike.** On the lock screen and
  greeter, a failed face check passes an empty password to `pam_unix`, which
  counts toward `pam_faillock` (default: 3 failures / 15 min). Type the
  password instead of pressing Enter repeatedly.
- **Lid closed** (`abort_if_lid_closed = true`): face auth is skipped when
  docked with the lid shut.
- **GNOME Keyring after a greeter face login** isn't unlocked (no password is
  supplied). Fix if needed: `unlock_gnome_keyring = true`,
  `sudo gaze keyring`, and `pam_gnome_keyring.so use_authtok` on greetd's
  auth keyring line.

## Uninstall

```sh
bash install.sh uninstall        # PAM lines, empty-password submit, overlay, NPU registration
paru -Rns gaze-bin               # Gaze itself; also cleans sudo and polkit-1
```

NPU runtime: `sudo rm -rf /opt/ryzen-ai /etc/security/limits.d/99-amdxdna.conf`
and `sudo pacman -Rns xrt-plugin-amdxdna xrt`.

## Layout

```text
install.sh               Gaze, config, PAM, lock screen/greeter, overlay (uninstall too)
npu/install-sdk.sh       XRT, Ryzen AI SDK in /opt/ryzen-ai, Arch fixes, then use-npu.sh
npu/use-npu.sh           register the SDK with Gaze, gazed drop-in, switch to the NPU
npu/use-cpu.sh           switch back to the CPU (--unregister removes the NPU setup)
npu/cache-check.sh       gazed ExecStartPre: recompile when Gaze/SDK/XRT/NPU firmware change
gaze-overlay/            Face ID-style overlay (Rust, GTK4) and its user service
```

## Credits

- **Gundu Labs** — [Gaze](https://github.com/GunduLabs/gaze)
  ([docs](https://gaze.gundulabs.com): configuration, greetd, acceleration guides)
- **Noctalia** — [lock screen](https://github.com/noctalia-dev/noctalia) and
  [greeter](https://github.com/noctalia-dev/noctalia-greeter)
  (biometric UX: [noctalia-greeter#90](https://github.com/noctalia-dev/noctalia-greeter/issues/90))
- **AMD** — [Ryzen AI Software](https://ryzenai.docs.amd.com/en/latest/linux.html),
  `amdxdna` driver and XRT

## License

Guide and scripts: CC0. Overlay: MIT, text in `gaze-overlay/LICENSE`. Gaze and
the Ryzen AI SDK are not included. Details in `LICENSE`.

## AI notice

Parts of this repository (scripts, overlay, and this README) were written or
revised with assistance from an AI coding tool, validated by hands-on testing
on the PX13. Review before use on other hardware.
