# vphone-patcher

vphone-cli's firmware patchers (FirmwarePatcher, VPhonePatchKit, VPhoneSign, VPhoneCoreKit, VPhoneArchiveKit),
from https://github.com/Lakr233/vphone-cli (MIT, see LICENSE; the commit is in UPSTREAM), built as one Swift
package for macOS and iOS so Monolith can prepare and patch a device guest's firmware on the phone.

Changes from upstream are marked `MONOLITH:` in the source: macOS-only APIs are fenced with `#if os(macOS)`,
and what needs host tools (diskutil, mount_apfs, aea, …) goes through Monolith's own code instead.
