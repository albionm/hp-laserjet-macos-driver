# HP LaserJet P1007 / P1505 — ARM64 macOS Driver

A native Apple Silicon driver for the HP LaserJet P1007 and P1505 on macOS. Once installed, the printer behaves like any other Mac printer: it shows up in System Settings, prints from every app's print dialog, and needs no manual steps after power-on.

The driver is a single small binary (`rastertoxqx`) that converts CUPS raster data to the printer's native XQX format using JBIG compression. It links only against system libraries and runs inside the CUPS sandbox. No Ghostscript, no Homebrew.

```
PDF → cgpdftoraster (macOS built-in) → rastertoxqx → XQX → printer
```

macOS already renders print jobs to raster through CoreGraphics with its built-in `cgpdftoraster` filter. `rastertoxqx` takes that 8-bit grey raster, halftones it, uploads the printer's firmware when needed, and wraps the result in the XQX protocol the printer expects.

## Installation

You need macOS on Apple Silicon and the Xcode Command Line Tools (`xcode-select --install`). Pass your model, `P1007` or `P1505` (default `P1007`):

```bash
sudo ./install.sh P1505
```

This compiles `rastertoxqx` and installs the filter, firmware and PPD under `/Library/Printers`. Then add the printer in System Settings › Printers & Scanners and choose "HP LaserJet P1505 rastertoxqx" (or P1007) as the driver. If a queue for the printer already exists — for example one set up with a Foomatic PPD — the installer switches it to this driver automatically.

Print a test page with:

```bash
lp -d HP_LaserJet_P1505 testpage.pdf
```

Prefer a double-clickable installer? `sudo ./build-pkg.sh` builds `HP-LaserJet-P1007-P1505-Driver.pkg`, which installs the same thing for both models.

### Reboots and macOS updates

Nothing to do. Everything lives in `/Library/Printers/foo2xqx/` and the CUPS configuration, which macOS updates leave alone. If printing ever stops after an update, re-run `sudo ./install.sh <model>`.

If a newer SDK breaks compilation (it happened with the macOS 27 SDK, whose library stubs the linker couldn't read), the installer automatically falls back to an older installed SDK.

## Firmware

These printers forget their firmware every time they're switched off. `rastertoxqx` takes care of it: before each job it asks the printer for its IEEE-1284 device ID over the CUPS side channel. If there's no `FWVER` in it, it sends the firmware first (`sihpP1005.dl` for the P1007, `sihpP1505.dl` for the P1505) and waits until the printer reports it loaded. The first job after power-on just takes about 10 seconds longer.

Earlier versions used a USB hotplug LaunchDaemon for this. It raced with jobs sent right after power-on — the job reached the printer before the firmware and was silently dropped — so the installers now remove it.

## Print quality

Text and line art print at the full 1200×600 dpi.

Grey areas and photos are halftoned by `rastertoxqx` itself with a 45° clustered-dot screen at about 106 lpi, plus a tone curve that compensates for toner spread. The PPD asks macOS for 8-bit grey raster for this. macOS's own 1-bit halftoning uses isolated 1/1200" dots, which these lasers print grainy and much too dark. The screen and curve were picked by comparing printed test sheets on a P1505.

Large grey areas may still darken slightly toward their bottom edge. That's toner drag inside the printer; a coarser screen reduces it at the cost of detail (`SCREEN_PERIOD` in `rastertoxqx.c`).

## Troubleshooting

Check the CUPS log with `tail -f /var/log/cups/error_log`. The firmware messages are informational, so they only appear with debug logging enabled (`cupsctl --debug-logging`; turn it off again with `cupsctl --no-debug-logging`).

- **Printer doesn't react to the first job after power-on:** look for `Sending printer firmware` or `did not report firmware version` in the debug log. You can also send the firmware by hand: `lp -d HP_LaserJet_P1505 -o raw /Library/Printers/foo2xqx/firmware/sihpP1505.dl`.
- **"Filter failed":** check that `/Library/Printers/foo2xqx/filter/rastertoxqx` exists. If not, re-run the installer.
- **Log says `foomatic-rip` is not available:** the queue uses the Foomatic PPD from `foo2zjs/PPD/`. Re-run the installer to switch it to the native PPD.
- **Output is faint or outlined:** make sure the resolution is 1200×600 dpi (the default). 600×600 prints faint on these models.
- **Wrong paper size:** the P1505 PPD defaults to A4 and the P1007 PPD to Letter. Some apps keep their own setting — Firefox, for example, remembers the paper size per printer in its print dialog. The system-wide default is in System Settings › Printers & Scanners › Default paper size.

## Repository layout

- `rastertoxqx.c` — the CUPS filter: halftoning, firmware upload, XQX output
- `HP-LaserJet_P1007.ppd`, `HP-LaserJet_P1505.ppd` — printer descriptions
- `install.sh` — builds and installs for one model
- `build-pkg.sh` — builds a `.pkg` installer for both models
- `testpage.pdf` — a simple test page
- `foo2zjs/` — an unmodified copy of the [foo2zjs](http://foo2zjs.rkkda.com/) project. The driver uses its JBIG encoder (`jbig.c`, `jbig_ar.c`), the XQX definitions (`xqx.h`), `arm2hpdl.c` and the firmware images (`sihp*.img`) to generate the `.dl` firmware files. `xqxdecode` is handy for inspecting what the filter sends. The rest is kept for reference and for adding further models.

## Other printers

The same XQX protocol is used by the HP LaserJet P1005, P1006 and P1008. `rastertoxqx` already knows their firmware files (`firmware_for_model()`); each still needs a PPD and an entry in the `case` block of `install.sh` and `build-pkg.sh`. The P1007 path shares all code with the P1505 but has not been re-tested on a P1007 since the halftoning and firmware changes.

The LaserJet 1018, 1020 and 1022 use the related ZjStream protocol, which needs a separate filter with almost the same structure. Beyond HP, the same pattern could support the Dell, Xerox, Samsung and Konica Minolta printers foo2zjs handles on Linux.

If you have one of these printers and an Apple Silicon Mac, [open an issue](https://github.com/faradayfury/hp-laserjet-macos-driver/issues/new) with your printer model and macOS version.

## License

GPL v2 or later — see [LICENSE](LICENSE). `rastertoxqx.c` is derived from foo2zjs's `foo2xqx.c`, and the bundled foo2zjs and JBIG-KIT code are GPL v2+ as well.

Exception: the printer firmware images (`foo2zjs/sihp*.img`) and colour profiles (`foo2zjs/*.icm`) are copyrighted by their manufacturers (HP, Konica Minolta, Lexmark, Oki, Samsung) and are not covered by the GPL; see the list at the top of [foo2zjs/COPYING](foo2zjs/COPYING).

## Background

The XQX protocol and JBIG compression code come from the foo2zjs project by Rick Richardson and the JBIG-KIT library by Markus Kuhn, both GPL v2+.

An earlier version used Ghostscript for rendering. CUPS runs filters in a sandbox that blocks Homebrew libraries, so Ghostscript had to be bundled with ~15 dylibs rewritten to `@loader_path/` — a ~35 MB package that broke on every `brew upgrade ghostscript`. Using macOS's built-in `cgpdftoraster` removed all of that.
