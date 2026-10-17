<p align="center"><img src="assets/icon.png" width="128" alt="InputLock icon"></p>

<h1 align="center">InputLock</h1>

<p align="center">A stealth keyboard &amp; mouse lock for macOS, unlocked with Touch ID or your login password.</p>

---

Press **⌃⌥⌘L** and your Mac *looks* exactly the same: windows stay open, videos keep playing, the cursor still moves.
But typing, clicking, scrolling, trackpad gestures and media keys do nothing. The moment someone tries to use it,
the **native macOS Touch ID / password dialog** appears. Only you can unlock it.

- No overlay, no Dock icon, no menu-bar icon. Just a one-second 🔒 badge when you lock or unlock.
- The Mac never sleeps or screen-locks while InputLock is locked.
- Hot corners, Mission Control swipes, volume/brightness keys and clicks behind the unlock dialog are all blocked.
- Starts automatically at login. Single tiny binary, no dependencies, no network access.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/devrashed01/InputLock/main/install.sh | bash
```

This downloads the latest release into `~/Applications`, adds a login item and opens the permission settings.
One-time step: enable **InputLock** in **System Settings ▸ Privacy & Security ▸ Accessibility** and **Input Monitoring**, then run:

```bash
launchctl kickstart -k gui/$(id -u)/com.local.inputlock
```

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/devrashed01/InputLock/main/install.sh | bash -s uninstall
```

<details><summary>Manual download</summary>

1. Download `InputLock.zip` from the [latest release](../../releases/latest), unzip it and move `InputLock.app` to Applications.
2. The app isn't notarized, so the first time, **right-click ▸ Open ▸ Open**.
3. Grant **Accessibility** and **Input Monitoring** as described above, then open it again.

</details>

### Build from source
Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/devrashed01/InputLock.git
cd InputLock
bash build.sh            # builds, installs to ~/Applications and adds a login item
```

If you have an *Apple Development* signing identity, `build.sh` uses it, and your privacy permissions survive rebuilds.
Otherwise it signs ad-hoc, and you'll need to re-grant permissions after each rebuild.

| Command | What it does |
|---|---|
| `bash build.sh` | Build, install and start |
| `bash build.sh release` | Build a universal, ad-hoc-signed `dist/InputLock.zip` |
| `bash build.sh uninstall` | Stop, remove the login item and the app |

## Usage

| | |
|---|---|
| **⌃⌥⌘L** | Lock (when locked: show the unlock dialog) |
| Touch ID / password | Unlock |
| `pkill -x InputLock` | Quit |

Logs: `log stream --predicate 'subsystem == "com.local.inputlock"'`

## How it works
A `CGEventTap` filters input at the session level. While locked, only cursor movement passes.
The first real interaction triggers `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`, the system's own
Touch ID / password prompt. IOKit power assertions keep the display awake. A watchdog re-enables the tap if macOS
disables it. If macOS's own lock screen appears, InputLock steps aside, and unlocking macOS unlocks InputLock too.

InputLock stores no passwords and never sees them. Authentication is handled entirely by macOS.

> **Note:** This is a deterrent against casual access, not a replacement for the macOS lock screen (⌃⌘Q).
> Anyone who can hold the power button can still restart the Mac.

## License
[MIT](LICENSE)
