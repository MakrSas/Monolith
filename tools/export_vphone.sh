#!/bin/zsh
# Makes a folder Monolith on iOS can bring in from a vphone-cli machine (~/.vphone/machines/NAME):
# drop it on the app in Finder (the iPhone's Files section) or pick it in the Files app.
#   tools/export_vphone.sh VM_DIR [NAME] [RAM_MB] [OUTDIR]
# The disk goes in packed (holes left out). Reads the machine; writes nothing to it. Stop the VM first.
set -e
VM=${1:?usage: $0 VM_DIR [NAME] [RAM_MB] [OUTDIR]}
NAME=${2:-$(basename "$VM")}; RAM=${3:-2048}; OUT=${4:-$HOME/Desktop/$NAME}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
for f in Disk.img nvram.bin SEPStorage config.plist; do [ -f "$VM/$f" ] || { echo "$VM/$f is missing (has the machine been created and booted once?)" >&2; exit 1; }; done
ROM=$(plutil -extract romImages.avpBooter raw "$VM/config.plist" 2>/dev/null || echo OpenAVB.bin)
SEPROM=$(plutil -extract romImages.avpSEPBooter raw "$VM/config.plist" 2>/dev/null || echo OpenSEP.bin)
# The ECID is the first 8 bytes of the machine identifier (VZMacMachineIdentifier's ECID), as vphone-linux reads it.
ECID=$(plutil -extract machineIdentifier raw "$VM/config.plist" 2>/dev/null | base64 -d 2>/dev/null | plutil -extract ECID raw - 2>/dev/null || true)
[ -n "$ECID" ] || ECID=$(cat "$VM/ecid" 2>/dev/null || true)
[ -n "$ECID" ] || { echo "cannot find the machine's ECID; put it (hex or decimal) in $VM/ecid" >&2; exit 1; }
[[ $ECID == 0x* ]] && ECID=$((ECID))
make -C "$HERE" build/hvsparse >/dev/null
mkdir -p "$OUT"
cp "$VM/$ROM" "$OUT/AVPBooter.vmapple2.bin"
cp "$VM/$SEPROM" "$OUT/OpenSEP.bin"
cp "$VM/nvram.bin" "$OUT/auxiliary.bin"
cp "$VM/SEPStorage" "$OUT/SEPStorage"
echo "packing the disk (only its data moves)..."
"$HERE/build/hvsparse" pack "$VM/Disk.img" "$OUT/disk.img.hvsparse"
cat > "$OUT/machine.json" <<JSON
{"name": "$NAME", "ecid": $ECID, "seed": 0, "ramMB": $RAM, "platform": "vresearch101"}
JSON
echo "$OUT: $(du -sh "$OUT" | cut -f1)"
