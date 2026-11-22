#!/bin/sh
#
# HP LaserJet P1007 / P1505 - Apple Silicon Native Driver Installer
#
# Installs an ARM64-native driver using the rastertoxqx CUPS raster filter.
# No Ghostscript dependency — uses macOS built-in cgpdftoraster for
# PDF rendering.
#
# Usage: sudo ./install.sh [P1007|P1505]     (default: P1007)
#

set -e

MODEL="${1:-P1007}"
case "$MODEL" in
    P1007|p1007) MODEL=P1007; FW=sihpP1005 ;;
    P1505|p1505) MODEL=P1505; FW=sihpP1505 ;;
    *)
        echo "ERROR: Unsupported model '$MODEL'. Supported: P1007, P1505"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER_DIR="/Library/Printers/foo2xqx/filter"
OLD_FILTER_DIR="/usr/libexec/cups/filter"
FIRMWARE_DIR="/Library/Printers/foo2xqx/firmware"
OLD_FIRMWARE_DIR="/usr/local/share/foo2xqx"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_NAME="HP-LaserJet_$MODEL.ppd"
FOO2ZJS_DIR="$SCRIPT_DIR/foo2zjs"

echo "=== HP LaserJet $MODEL - ARM64 Native Driver Installer ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    echo "  sudo $0 $MODEL"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "WARNING: This driver is built for Apple Silicon (arm64)."
    echo "  Detected architecture: $ARCH"
    echo ""
fi

# Compile with clang; if linking against the default SDK fails (e.g. a
# newer SDK whose .tbd stubs the installed linker can't parse), retry
# against each other installed macOS SDK, newest first.
cc_build() {
    if clang "$@" 2>/dev/null; then
        return 0
    fi
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk \
                      /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk \
                      2>/dev/null | sort -rV); do
        if clang -isysroot "$sdk" "$@" 2>/dev/null; then
            echo "  (built against $(basename "$sdk"))"
            return 0
        fi
    done
    echo "ERROR: compilation failed. Output with the default SDK:"
    clang "$@"
    return 1
}

# Step 1: Compile rastertoxqx (the CUPS raster filter)
echo "[1/5] Compiling rastertoxqx..."
cd "$SCRIPT_DIR"
cc_build -o rastertoxqx rastertoxqx.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -lcups -lcupsimage -O2
echo "  rastertoxqx: $(file -b rastertoxqx)"

# Step 2: Compile arm2hpdl and generate firmware
echo "[2/5] Preparing firmware..."
if [ ! -f "$FOO2ZJS_DIR/arm2hpdl" ] || [ "$(file -b "$FOO2ZJS_DIR/arm2hpdl" | grep -c arm64)" -eq 0 ]; then
    cd "$FOO2ZJS_DIR"
    cc_build -o arm2hpdl arm2hpdl.c -I. -O2
    cd "$SCRIPT_DIR"
fi
if [ ! -s "$FOO2ZJS_DIR/$FW.dl" ]; then
    cd "$FOO2ZJS_DIR"
    ./arm2hpdl "$FW.img" > "$FW.dl"
    cd "$SCRIPT_DIR"
fi
echo "  Firmware: $FW.dl ($(wc -c < "$FOO2ZJS_DIR/$FW.dl" | tr -d ' ') bytes)"

# Step 3: Install the rastertoxqx filter
echo "[3/5] Installing CUPS filter..."
mkdir -p "$FILTER_DIR"
cp "$SCRIPT_DIR/rastertoxqx" "$FILTER_DIR/rastertoxqx"
chown root:wheel "$FILTER_DIR/rastertoxqx"
chmod 755 "$FILTER_DIR/rastertoxqx"
codesign --force --sign - "$FILTER_DIR/rastertoxqx" 2>/dev/null || true
echo "  Installed to $FILTER_DIR/rastertoxqx"

# Step 4: Install firmware
echo "[4/5] Installing firmware..."
mkdir -p "$FIRMWARE_DIR"
cp "$FOO2ZJS_DIR/$FW.dl" "$FIRMWARE_DIR/$FW.dl"
chmod 644 "$FIRMWARE_DIR/$FW.dl"
echo "  Installed to $FIRMWARE_DIR/$FW.dl"

# Step 5: Install PPD
echo "[5/5] Installing PPD..."
mkdir -p "$PPD_DIR"
cp "$SCRIPT_DIR/$PPD_NAME" "$PPD_DIR/$PPD_NAME"
chmod 644 "$PPD_DIR/$PPD_NAME"
echo "  Installed to $PPD_DIR/$PPD_NAME"

# Clean up leftovers from older approaches
if [ -f "$OLD_FILTER_DIR/gs-bundled" ]; then
    echo ""
    echo "Cleaning up old Ghostscript bundle..."
    rm -f "$OLD_FILTER_DIR/gs-bundled"
    rm -rf "$OLD_FILTER_DIR/gs-res"
    rm -f "$OLD_FILTER_DIR"/libjbig2dec*.dylib \
          "$OLD_FILTER_DIR"/libtiff*.dylib \
          "$OLD_FILTER_DIR"/libpng*.dylib \
          "$OLD_FILTER_DIR"/libjpeg*.dylib \
          "$OLD_FILTER_DIR"/liblcms2*.dylib \
          "$OLD_FILTER_DIR"/libidn*.dylib \
          "$OLD_FILTER_DIR"/libfontconfig*.dylib \
          "$OLD_FILTER_DIR"/libfreetype*.dylib \
          "$OLD_FILTER_DIR"/libopenjp2*.dylib \
          "$OLD_FILTER_DIR"/libtesseract*.dylib \
          "$OLD_FILTER_DIR"/libarchive*.dylib \
          "$OLD_FILTER_DIR"/libleptonica*.dylib \
          "$OLD_FILTER_DIR"/libwebp*.dylib \
          "$OLD_FILTER_DIR"/libsharpyuv*.dylib \
          "$OLD_FILTER_DIR"/libgif*.dylib \
          "$OLD_FILTER_DIR"/libintl*.dylib \
          2>/dev/null
    echo "  Removed gs-bundled, dylibs, and gs-res/"
fi
for f in "$OLD_FILTER_DIR/foomatic-rip" "$OLD_FILTER_DIR/rastertoxqx" \
         /usr/local/bin/foo2xqx-wrapper /usr/local/bin/foo2xqx; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo "  Removed old $f"
    fi
done
if [ -d "$OLD_FIRMWARE_DIR" ]; then
    rm -rf "$OLD_FIRMWARE_DIR"
    echo "  Removed old $OLD_FIRMWARE_DIR"
fi

# The filter now uploads firmware itself when the printer needs it, so the
# old USB hotplug daemon is no longer needed. It raced with print jobs sent
# right after power-on, so remove it.
for plist in /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist \
             /Library/LaunchDaemons/com.foo2xqx.firmware-upload.p1007.plist \
             /Library/LaunchDaemons/com.foo2xqx.firmware-upload.p1505.plist; do
    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "  Removed firmware hotplug daemon $plist"
    fi
done
rm -f /usr/local/bin/hp-p1007-firmware-upload /usr/local/bin/hp-p1505-firmware-upload

# Re-point any existing queue for this model at the new PPD
# (fixes queues that were set up with the Foomatic PPD).
# lpstat -v prints "device for <queue>: <uri>" (localized, but always 3 words).
QUEUES=$(LC_ALL=C lpstat -v 2>/dev/null \
         | awk -v m="LaserJet%20$MODEL" 'index($0,m){sub(/:$/,"",$3); print $3}' || true)
for q in $QUEUES; do
    echo ""
    echo "Updating existing print queue '$q' to use the native driver..."
    lpadmin -p "$q" -P "$PPD_DIR/$PPD_NAME"
    cupsenable "$q" 2>/dev/null || true
    cupsaccept "$q" 2>/dev/null || true
    echo "  Done."
done

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo ""
echo "1. PLUG IN your HP LaserJet $MODEL via USB"
echo "   Firmware is sent automatically with the first job after power-on"
echo "   (that job starts ~10 seconds later than usual)."
echo ""
if [ -z "$QUEUES" ]; then
    echo "2. ADD THE PRINTER via System Settings > Printers & Scanners"
    echo "   - Click '+' and select 'HP LaserJet $MODEL' (USB)"
    echo "   - Choose 'HP LaserJet $MODEL rastertoxqx' as the driver"
    echo ""
fi
echo "Test:  lp -d <queue> $SCRIPT_DIR/testpage.pdf"
echo ""
