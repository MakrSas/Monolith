# Moving a vphone device to the iPhone or iPad

Monolith runs the devices [vphone](https://github.com/Lakr233/vphone-cli) makes on a Mac (HomePod, HomeView,
Apple Watch, Apple TV, iPhone guests on the `vresearch101` research board). A device that works in vphone on
the Mac can be brought to the phone and run there in Monolith.

The device is copied, not converted: the phone runs the same disk, boot ROM, SEP and identity the Mac did.

## What you need

- The vphone machine on the Mac, created and **booted at least once** in vphone, then **shut down**
  (not suspended). It lives in `~/.vphone/machines/NAME` (or wherever your vphone library is).
- This repository on the Mac, with Xcode's command-line tools (the script builds a small packer).
- Free space: on the Mac about the size of the guest's data (not its full 64 GB disk), and on the phone about
  twice that while the disk is unpacked.

## 1. Pack the machine on the Mac

```sh
tools/export_vphone.sh ~/.vphone/machines/NAME [DISPLAY_NAME] [RAM_MB] [OUT_DIR]
```

- `DISPLAY_NAME`: the name Monolith shows (default: the folder's name).
- `RAM_MB`: the guest's memory on the phone (default 2048). Use 2048 for a HomePod or a watch, 3072 for a
  HomeView. More is not better on a phone: it is taken from what iOS allows the app.
- `OUT_DIR`: where the folder goes (default `~/Desktop/DISPLAY_NAME`).

The script only reads the machine. It makes a folder in the format Monolith brings in:

| File | What it is |
| --- | --- |
| `AVPBooter.vmapple2.bin` | the machine's boot ROM (vphone's `OpenAVB.bin`) |
| `OpenSEP.bin` | the SEP ROM |
| `SEPStorage` | the SEP's storage |
| `auxiliary.bin` | the machine's NVRAM (vphone's `nvram.bin`) |
| `disk.img.hvsparse` | the disk, packed: only the data, not the empty space of the 64 GB image |
| `machine.json` | name, ECID, memory, platform `vresearch101` and the screen size |

The ECID comes from the machine's `config.plist`. If the script cannot find it, put it (hex or decimal) in a
file named `ecid` in the machine's folder and run it again.

## 2. Copy the folder to the phone

Either way works:

- **Finder**: connect the phone, open it in Finder, Files tab, and drop the folder on **Monolith**.
  Monolith brings it in the next time it opens.
- **Files app**: copy the folder to the phone (iCloud Drive, a USB drive, AirDrop), then in Monolith tap
  **+ → Bring in a device from a folder…** and pick it.

Monolith copies the files into its own storage and unpacks the disk; the Home screen shows the progress
("Unpacking NAME's disk…"). A large guest takes a few minutes.

## 3. Start it

The device appears in **Devices**. Turn on JIT first (Settings), then start it like any other.

- The first start after a move can take longer than on the Mac: the guest rebuilds caches.
- HomePod: its top surface is the screen; touch it to play or pause, and use + and − on it for volume.
  It appears as an AirPlay speaker on your Wi-Fi.
- HomeView: pull down from the top-right corner for Control Center; the **Apps** button under the screen
  opens any app.
- Watch: the Digital Crown and the side button are under the screen.

## When it does not work

- *"The folder is missing …"*: the export was interrupted, or a file was not copied. Export again.
- *The device stops at once*: it was suspended in vphone rather than shut down, or its memory is too high
  for this phone. Shut it down in vphone and export again, or export with a smaller `RAM_MB`.
- *Black screen*: give the first start a few minutes. Settings > Storage shows what Monolith keeps, if the
  phone runs low on space.
