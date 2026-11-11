<p align="center">
  <img src="docs/icon.png" width="120" height="120" alt="Monolith">
</p>

<h1 align="center">Monolith</h1>

<p align="center">Apple's devices on your iPhone and iPad: HomePod, HomeView, Apple Watch, Apple TV and the Mac.</p>

<p align="center">
  <a href="#install">Install</a>
  ·
  <a href="#devices">Devices</a>
  ·
  <a href="docs/vphone-transfer.md">Move a device from vphone</a>
  ·
  <a href="https://github.com/MakrSas/Monolith/releases">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/MakrSas/Monolith/releases"><img src="https://img.shields.io/github/v/release/MakrSas/Monolith?include_prereleases&style=flat-square&color=2E6BFF&labelColor=111111" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/MakrSas/Monolith?style=flat-square&color=2E6BFF&labelColor=111111" alt="GPL-2.0-or-later"></a>
</p>

Monolith is a fork of [Henge](https://github.com/Leviidev/Henge). It keeps everything Henge does for macOS
and adds Apple's other devices, the ones [vphone](https://github.com/Lakr233/vphone-cli) builds on a Mac,
running on the phone in Monolith's own emulator.

**This is a beta.** HomePod mini and HomeView install and run on the phone; read [Known issues](#known-issues)
before you start.

## Devices

| Device | On the phone | Notes |
| --- | --- | --- |
| **HomePod mini** | Installs in the app | The top surface is the screen: touch to play or pause, + and − for volume. It shows up as an AirPlay speaker on your Wi-Fi. |
| **HomeView** | Installs in the app | Pull down from the top-right corner for Control Center. The **Apps** button under the screen opens any app. |
| **Apple Watch** | Move from vphone | The Digital Crown and side button are under the screen. Installing in the app is not ready yet. |
| **Apple TV, iPhone** | Move from vphone | Installing in the app is not ready yet. |
| **Mac** | Installs in the app | Henge's macOS support, unchanged: see [macOS](#macos). |

### Installing on the phone, no Mac needed

Open the **Install** tab, pick HomePod mini or HomeView, choose a release and a name, and keep Monolith open
with the phone plugged in. Monolith:

1. downloads Apple's firmware for the device and the cloudOS it borrows its boot chain from (progress shows
   size, speed and time left; downloads are kept for the next install);
2. patches the boot chain and kernel;
3. restores the device in its own engine;
4. installs vphone's additions (its guest agent, launch daemons, patches) into the device's disk.

vphone's pipeline runs inside the app: the macOS tools it relies on (`diskutil`, `mount_apfs`, `aa`,
`codesign`, …) are answered by Monolith's own code, including a clean-room APFS reader and writer (`apfs/`).

If an install fails after the restore, or Monolith is closed, the restored device is kept: **Retry the last
steps** finishes it without a new download or restore. **Settings → Storage** lists what Monolith keeps, with
sizes, so you can delete downloads and leftovers.

### Moving a device from vphone on a Mac

A device that runs in vphone can be packed on the Mac with `tools/export_vphone.sh` and brought to the phone
through Finder or the Files app. See [docs/vphone-transfer.md](docs/vphone-transfer.md).

## Install

Sideload `Monolith.ipa` from [Releases](https://github.com/MakrSas/Monolith/releases) with SideStore or
AltStore. Its bundle identifier is `com.monolith.app`, so it installs beside Henge.

- **iOS or iPadOS 17 or later**, on an A14 or M1 chip or newer. Tested on an iPhone 15.
- **JIT is required**: StikDebug, the StikJIT helper built into Monolith (iOS 26 or later), TrollStore, or a
  jailbreak. Monolith pairs for JIT as *Monolith*, so it does not disturb Henge's pairing.
- **Storage**: about 20 GB free while a HomePod or HomeView installs; a Mac needs about 43 GB.
- **Memory**: sign with the increased memory limit entitlement if your certificate has it.

## Known issues

- **HomeView**: Settings and Control Center open, then close; app icons show as placeholders; Liquid Glass
  lowers the frame rate.
- **HomePod**: AirPlay connects, but there is no sound yet.
- **Apple Watch, Apple TV and iPhone** cannot be installed in the app yet (shown as *Soon*): move them from
  vphone instead.
- After an install, **quit and reopen Monolith before starting the device**: the install keeps memory the
  device then needs.
- A device's **first start takes several minutes**.
- Everything in [Henge's known limits](https://github.com/Leviidev/Henge#known-limits) for macOS applies.

## macOS

Everything Henge does is here: download macOS, install it on the device, and use it, with its own JIT, its own
virtual GPU replayed on Metal, a Magic Trackpad 2 on the touch screen, keyboard and mouse on iPad, an external
display, copy and paste and a shared folder with the Mac, Instant Resume, and Mac apps without macOS. See
[Henge's README](https://github.com/Leviidev/Henge#readme) and [docs/architecture.md](docs/architecture.md).

## Building

On a Mac with Xcode 27 or later and `xcodegen`. Like Henge, Monolith takes StikJIT, on-device pairing,
libslirp and glib from a built [Husk](https://github.com/Leviidev/Husk) checkout at `~/Documents/Coding/Husk`
(set `HUSK` to use another path). The vphone devices also need vphone's resources: a built vphone app, whose
`Contents/Resources` the packaging script copies in (set `VPHONE_RESOURCES` to its path).

```bash
ios/scripts/fetch_deps.sh
tools/build_ios_restore.sh
make ios-lib
VPHONE_RESOURCES=/path/to/VPhone.app/Contents/Resources ios/scripts/package_ipa.sh
```

That produces `~/Desktop/Monolith.ipa`. `make` builds the engine for the Mac (`build/hengevm`), `make test`
runs its tests, and `build/apfs` is the APFS tool.

## Credits

- [Henge](https://github.com/Leviidev/Henge) by Leviidev and its contributors: the emulator, macOS support and
  the app this is built on. Their history is kept in this repository.
- [vphone](https://github.com/Lakr233/vphone-cli) by Lakr233 and its contributors: the device firmware
  pipeline, patches and guest agent Monolith runs on the phone (`third_party/vphone-patcher`).

## Licence

GPL-2.0-or-later, as Henge. The shipped binary is a combined GPL work (usbmuxd, Husk) and cannot go on the App
Store. See [docs/licensing.md](docs/licensing.md).

The devices' firmware, macOS and the boot ROMs are Apple's and are not part of Monolith: it downloads them
from Apple when you install.
