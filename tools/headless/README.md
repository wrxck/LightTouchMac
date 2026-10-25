# Headless devices

Run one prepared device with no app and no window, and drive it from a shell: input, screenshots, root commands,
file copy and SSH. For test rigs and agents on a Mac reached over SSH, where the app can't be clicked.

| File | What it does |
|---|---|
| `ltdev` | The command (Python 3, standard library only): start, stop, status, input, screenshots, the guest agent, SSH |
| `Sources/ltm-boot` | Writes the helper's headless config for a prepared base with PreparedDeviceBoot and BootRecipe, as the sessions harness's session-driver does |
| `build-helper.sh` | Builds `LightTouchDevice` with SwiftPM, for a Mac whose Xcode can't open the project; unsandboxed, signed ad hoc, loading a built app's emulator |
| `../../tests/headless/check.sh` | The check: a headless boot outlives its first frame ring, answers its control socket, writes a PNG and halts |

The helper's headless mode (`HelperLaunch.Mode.headless`) serves a control socket when its config names one
(`HeadlessConfig.control`); `LightTouchDevice/HeadlessControl.swift` documents the wire. `ltdev` is one client of it.

## Setup

```sh
swift build -c release --package-path tools/headless                  # ltm-boot
tools/headless/build-helper.sh "/Applications/Light Touch.app" ~/ltm-helper   # only without Xcode 27
export LTM_APP="/Applications/Light Touch.app"
export LTM_HELPER=~/ltm-helper/Contents/MacOS/LightTouchDevice          # default: the app's own
export LTM_BASE=/path/to/prepared-base                                  # firmwarekit create output
export LTM_SSH_KEY=~/.ssh/id_ed25519                                    # a key the device's root accepts
```

`LTM_RUN` keeps the device's overlay, NOR and logs (default: `LTM_STATE/run/<base name>`); `LTM_STATE` keeps the
sockets (default `~/Library/Application Support/Light Touch/headless`). A Unix socket path holds at most 103 bytes.

## Use

```sh
tools/headless/ltdev start            # usbmuxd, ltm-boot, the helper; returns once the UI is ready
tools/headless/ltdev home             # or lock, button N [SECONDS]
tools/headless/ltdev swipe 45 432 310 432 0.5
tools/headless/ltdev tap 160 240      # points from the top left of the portrait screen
tools/headless/ltdev type "hello"     # US layout keys; paste TEXT sets the guest pasteboard
tools/headless/ltdev screen out.png
tools/headless/ltdev sh 'uname -a'    # root, through the guest agent (needs the guest package)
tools/headless/ltdev put big.bin /tmp/big.bin && tools/headless/ltdev get /tmp/big.bin back.bin
tools/headless/ltdev ssh 'ls /'       # needs OpenSSH on the device
tools/headless/ltdev stop             # the app's halt: the VM pauses, which flushes storage, then QEMU quits
```

## Limits

- Uploads over SSH (`scp`, `ssh … < file`) fail at full speed: past about 140 KB the device drops what the host sends,
  and sshd stops with "Decryption integrity check failed". Downloads and throttled uploads are complete. The loss is in
  the USB path (usbmuxd and the emulated USB device), not in OpenSSH. Copy files with `ltdev put` and `get`.
- A helper built by `build-helper.sh` is not sandboxed. The app's sandboxed helper in headless mode takes no file
  grants, so it can only reach its app group's container.
