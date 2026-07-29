# CellularBridge / 蜂窝桥

CellularBridge is a native macOS utility for a DJI first-generation 4G module.
It lets macOS own the modem's ECM network interface while the app uses a
separate USB or serial AT control channel to receive SMS messages.

This is an independent implementation. It does not include source code from
DJOneHub or VoHive.

## Current scope

- Detect and probe the verified `2C7C:0125` device and the alternate `2CA3:4006`
  identity without detaching the ECM driver
- Fall back to a supported `/dev/cu.*` AT serial port
- Switch the modem to `usbnet=1` ECM mode and let this firmware perform its own USB hot restart
- Query SIM state, firmware, registration, operator, radio access technology,
  band, channel and signal metrics
- Show one-second upload/download rates plus session, daily and monthly totals
  for the selected ECM interface
- Keep daily and monthly traffic totals in local Application Support storage
- Ignore VPN/TUN interfaces when checking whether ECM owns the default route
- Keep one continuous AT reader and route unsolicited `+CMTI` notifications
  without mixing them into command responses
- Read a newly announced message by its exact storage and index, then run a
  full `SM`/`ME` reconciliation every 60 seconds as a missed-event fallback
- Show used and total message capacity for both SMS stores
- Decode GSM 7-bit, 8-bit and UCS-2 SMS-DELIVER messages
- Reassemble 8-bit and 16-bit concatenated SMS messages
- Persist messages and per-part import receipts in SQLite before showing a notification
- Send GSM 7-bit and Unicode SMS-SUBMIT PDUs, including concatenated long messages
- Reserve long-message concatenation references in SQLite so the same recipient
  does not reuse one within 24 hours or while an earlier message can still be retried
- Persist each exact outgoing PDU, TPDU length, per-part progress and modem reference
- Release the AT operation lock between long-message parts so queued `+CMTI`
  reads can run before the next part is submitted
- Return safe pre-submit transport failures to the queue for connection recovery
- Treat an interrupted or timed-out post-submit result as unknown and never
  retry it automatically, avoiding accidental duplicate messages
- Keep the unread SMS count synchronized across the sidebar, menu bar and Dock badge
- Open and select the matching message when its notification is clicked
- Optionally start automatically after login using the native macOS login-item service
  after the app is moved to `/Applications`
- Optionally delete only the exact imported modem indexes (`CMGD=<index>,0`), disabled by default
- Keep a durable local tombstone so deleting a message in the app cannot make it reappear

## Build

Requirements:

- macOS 26 on Apple Silicon
- Xcode 26.6 or later
- Homebrew `libusb` and `pkgconf`

```bash
brew install libusb pkgconf
swift test
./scripts/build-app.sh
open -n ../outputs/CellularBridge.app --args --demo
```

The build script creates `../outputs/CellularBridge.app`, embeds the Homebrew
libusb dylib, rewrites its install name and applies an ad-hoc local signature.

## Hardware verification

Live inspection on the target Mac confirmed the connected module enumerates as
`Baiwang` / `2C7C:0125`. Interfaces 4 and 5 provide ECM as `en9`, while vendor
interface 2 answers both `AT` and `AT+CMGF=?` over bulk endpoints `0x03/0x84`.
The app also recognizes the alternate `2CA3:4006` identity.

The remaining hardware checks are concurrent data transfer while receiving test
messages in both `SM` and `ME`, interrupted exact-index deletion, and an explicit
outbound test to a user-approved number. Keep "导入后清理模块短信" disabled while
validating the receive paths. Automated tests never send a real SMS.

The app never calls `libusb_detach_kernel_driver`, changes the active USB
configuration or resets the USB device. This prevents the AT path from taking
ownership of the ECM interface.

Traffic totals come from macOS interface counters and are not the carrier's
billable-usage measurement. A counter reset, interface change or long sampling
gap establishes a new baseline instead of adding a false traffic spike. Session
totals reset when the app starts; daily and monthly totals persist locally.

The cleanup path never uses a module-wide `CMGD` flag. A PDU is eligible for
deletion only after its complete message and constituent-part receipts have
committed to SQLite. Disabling cleanup keeps the import receipts active, so a
rescanned modem copy is not shown or notified twice.

`AT+CMGS` is interactive: the app waits for the modem's `>` prompt, writes the
PDU followed by Ctrl-Z, and then waits for `+CMGS` plus the final result. A
missing prompt is cancelled with ESC before reconnecting, and a rejection before
the prompt is safe to retry. Once PDU submission starts, any error, disconnect,
timeout or missing `+CMGS` receipt is recorded as "outcome unknown" and requires
an explicit confirmation before retrying because the carrier may have already
accepted the message.

## Distribution

The bundled Homebrew libusb bottle is arm64-only and built for macOS 26. It is
suitable for this Mac but not a general release. A public build should bundle a
universal libusb dylib built with the intended deployment target and then be
signed and notarized with a Developer ID.
