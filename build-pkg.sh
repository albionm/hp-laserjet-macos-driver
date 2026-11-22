#!/bin/bash
#
# Build a .pkg installer for the HP LaserJet P1007 / P1505 ARM64 driver.
#
# Compiles rastertoxqx from source and assembles the filter, both PPDs and
# both firmware files into a distributable .pkg that anyone can
# double-click to install. Same result as `sudo ./install.sh <model>`.
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - Must be run on Apple Silicon (arm64)
#
# Usage: sudo ./build-pkg.sh
#
# Optional: sudo ./build-pkg.sh --sign "Developer ID Installer: Your Name (TEAMID)"
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
PKG_ROOT="$BUILD_DIR/pkg-root"
SCRIPTS_DIR="$BUILD_DIR/scripts"
RESOURCES_DIR="$BUILD_DIR/resources"

PKG_ID="com.foo2xqx.hp-laserjet-xqx"
PKG_VERSION="3.0.0"
OUTPUT_NAME="HP-LaserJet-P1007-P1505-Driver.pkg"

FOO2ZJS_DIR="$SCRIPT_DIR/foo2zjs"
MODELS="P1007 P1505"

# Signing identity (optional)
SIGN_IDENTITY=""
if [ "$1" = "--sign" ] && [ -n "$2" ]; then
    SIGN_IDENTITY="$2"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

firmware_for() {
    case "$1" in
        P1007) echo sihpP1005 ;;
        P1505) echo sihpP1505 ;;
    esac
}

# Compile with clang; if linking against the default SDK fails (e.g. a newer
# SDK whose .tbd stubs the installed linker can't parse), retry against each
# other installed macOS SDK, newest first.
cc_build() {
    if clang "$@" 2>/dev/null; then
        return 0
    fi
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk \
                      /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk \
                      2>/dev/null | sort -rV); do
        if clang -isysroot "$sdk" "$@" 2>/dev/null; then
            log "  (built against $(basename "$sdk"))"
            return 0
        fi
    done
    clang "$@"
}

# ── Step 0: Checks ──────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    die "Run with sudo:  sudo $0 $*"
fi

if [ "$(uname -m)" != "arm64" ]; then
    die "This must be built on an Apple Silicon Mac (arm64)."
fi

which clang >/dev/null 2>&1 || die "Xcode Command Line Tools required: xcode-select --install"

log "Validating source files..."
[ -f "$SCRIPT_DIR/rastertoxqx.c" ] || die "rastertoxqx.c not found"
[ -f "$FOO2ZJS_DIR/jbig.c" ]       || die "foo2zjs/jbig.c not found"
[ -f "$FOO2ZJS_DIR/xqx.h" ]        || die "foo2zjs/xqx.h not found"
[ -f "$FOO2ZJS_DIR/arm2hpdl.c" ]   || die "foo2zjs/arm2hpdl.c not found"
for m in $MODELS; do
    [ -f "$SCRIPT_DIR/HP-LaserJet_$m.ppd" ] || die "HP-LaserJet_$m.ppd not found"
    [ -f "$FOO2ZJS_DIR/$(firmware_for $m).img" ] || die "foo2zjs/$(firmware_for $m).img not found"
done

# ── Step 1: Compile ──────────────────────────────────────────────────────────

mkdir -p "$BUILD_DIR"

log "Compiling rastertoxqx..."
cd "$SCRIPT_DIR"
cc_build -o "$BUILD_DIR/rastertoxqx" rastertoxqx.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -lcups -lcupsimage -O2
codesign --force --sign - "$BUILD_DIR/rastertoxqx"

log "Compiling arm2hpdl and generating firmware..."
cc_build -o "$BUILD_DIR/arm2hpdl" foo2zjs/arm2hpdl.c -Ifoo2zjs -O2
for m in $MODELS; do
    fw=$(firmware_for $m)
    "$BUILD_DIR/arm2hpdl" "foo2zjs/$fw.img" > "$BUILD_DIR/$fw.dl"
done

# ── Step 2: Package layout ──────────────────────────────────────────────────

log "Preparing package layout..."
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Library/Printers/foo2xqx/filter"
mkdir -p "$PKG_ROOT/Library/Printers/foo2xqx/firmware"
mkdir -p "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$RESOURCES_DIR"

log "Assembling payload..."
install -m 755 "$BUILD_DIR/rastertoxqx" "$PKG_ROOT/Library/Printers/foo2xqx/filter/rastertoxqx"
for m in $MODELS; do
    fw=$(firmware_for $m)
    install -m 644 "$SCRIPT_DIR/HP-LaserJet_$m.ppd" "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources/"
    install -m 644 "$BUILD_DIR/$fw.dl" "$PKG_ROOT/Library/Printers/foo2xqx/firmware/"
done
xattr -cr "$PKG_ROOT"    # drop quarantine/download metadata (com.apple.provenance can't be removed; harmless)
chown -R root:wheel "$PKG_ROOT"

# ── Step 3: Installer scripts ───────────────────────────────────────────────

log "Creating installer scripts..."

cat > "$SCRIPTS_DIR/preinstall" << 'PREINSTALL'
#!/bin/bash
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: This driver requires Apple Silicon (arm64)." >&2
    exit 1
fi

# Remove leftovers of older driver versions
FILTER_DIR="/usr/libexec/cups/filter"
rm -f "$FILTER_DIR/gs-bundled" 2>/dev/null
rm -rf "$FILTER_DIR/gs-res" 2>/dev/null
rm -f "$FILTER_DIR"/libjbig2dec*.dylib "$FILTER_DIR"/libtiff*.dylib \
      "$FILTER_DIR"/libpng*.dylib "$FILTER_DIR"/libjpeg*.dylib \
      "$FILTER_DIR"/liblcms2*.dylib "$FILTER_DIR"/libfontconfig*.dylib \
      "$FILTER_DIR"/libfreetype*.dylib "$FILTER_DIR"/libopenjp2*.dylib \
      "$FILTER_DIR"/libtesseract*.dylib "$FILTER_DIR"/libarchive*.dylib \
      "$FILTER_DIR"/libleptonica*.dylib "$FILTER_DIR"/libwebp*.dylib \
      "$FILTER_DIR"/libsharpyuv*.dylib "$FILTER_DIR"/libgif*.dylib \
      "$FILTER_DIR"/libintl*.dylib "$FILTER_DIR"/libidn*.dylib \
      2>/dev/null
rm -f "$FILTER_DIR/foomatic-rip" "$FILTER_DIR/rastertoxqx" 2>/dev/null
rm -f /usr/local/bin/foo2xqx-wrapper /usr/local/bin/foo2xqx 2>/dev/null
rm -rf /usr/local/share/foo2xqx 2>/dev/null

# The filter now uploads firmware itself; the old hotplug daemon raced with
# print jobs sent right after power-on.
for plist in /Library/LaunchDaemons/com.foo2xqx.firmware-upload*.plist; do
    [ -f "$plist" ] || continue
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
done
rm -f /usr/local/bin/hp-p1007-firmware-upload /usr/local/bin/hp-p1505-firmware-upload

exit 0
PREINSTALL

cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
FILTER="/Library/Printers/foo2xqx/filter/rastertoxqx"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"

chown root:wheel "$FILTER"
chmod 755 "$FILTER"
codesign --force --sign - "$FILTER" 2>/dev/null || true

# Point any existing queues for these printers at the new PPDs
for m in P1007 P1505; do
    LC_ALL=C lpstat -v 2>/dev/null \
        | awk -v m="LaserJet%20$m" 'index($0,m){sub(/:$/,"",$3); print $3}' \
        | while read -r q; do
            lpadmin -p "$q" -P "$PPD_DIR/HP-LaserJet_$m.ppd" 2>/dev/null
            cupsenable "$q" 2>/dev/null || true
            cupsaccept "$q" 2>/dev/null || true
        done
done

exit 0
POSTINSTALL

chmod 755 "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

# ── Step 4: Distribution XML and resources ──────────────────────────────────

log "Creating Distribution XML..."

cat > "$BUILD_DIR/Distribution.xml" << DISTXML
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<installer-gui-script minSpecVersion="2">
    <title>HP LaserJet P1007 / P1505 Driver</title>
    <welcome file="welcome.html" />
    <readme file="readme.html" />
    <options customize="never" require-scripts="false" hostArchitectures="arm64" />
    <os-version min="14.0" />
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_ID" />
        </line>
    </choices-outline>
    <choice id="default" />
    <choice id="$PKG_ID"
            visible="false"
            title="HP LaserJet P1007 / P1505 Driver"
            description="CUPS raster driver for HP LaserJet P1007 and P1505 on Apple Silicon">
        <pkg-ref id="$PKG_ID" />
    </choice>
    <pkg-ref id="$PKG_ID"
             version="$PKG_VERSION"
             onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
DISTXML

log "Creating installer resources..."

cat > "$RESOURCES_DIR/welcome.html" << 'WELCOME'
<!DOCTYPE html>
<html>
<head>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 20px; color: #1d1d1f; }
    h1 { font-size: 22px; font-weight: 600; }
    p { font-size: 14px; line-height: 1.5; color: #424245; }
    .note { background: #f5f5f7; padding: 12px; border-radius: 8px; margin-top: 16px; }
</style>
</head>
<body>
<h1>HP LaserJet P1007 / P1505 Driver</h1>
<p>This installs a native Apple Silicon driver for the HP LaserJet P1007 and P1505.</p>
<p>No additional software is required &mdash; the driver uses macOS's built-in PDF rendering.</p>
<div class="note">
<p><strong>What gets installed (in /Library/Printers):</strong></p>
<ul>
    <li>CUPS raster filter (rastertoxqx)</li>
    <li>Printer description files (PPDs)</li>
    <li>Printer firmware, sent automatically with the first job after power-on</li>
</ul>
</div>
</body>
</html>
WELCOME

cat > "$RESOURCES_DIR/readme.html" << 'README'
<!DOCTYPE html>
<html>
<head>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 20px; color: #1d1d1f; }
    h2 { font-size: 18px; font-weight: 600; margin-top: 20px; }
    p, li { font-size: 14px; line-height: 1.6; color: #424245; }
    ol { padding-left: 20px; }
</style>
</head>
<body>
<h2>After Installation</h2>
<ol>
    <li><strong>Connect</strong> your printer via USB.</li>
    <li><strong>Add the printer</strong> in System Settings &gt; Printers &amp; Scanners:
        click <strong>+</strong>, select the printer, and choose
        <strong>&ldquo;HP LaserJet P1007 rastertoxqx&rdquo;</strong> or
        <strong>&ldquo;HP LaserJet P1505 rastertoxqx&rdquo;</strong> as the driver.
        Existing queues for these printers are switched to the new driver automatically.</li>
    <li><strong>Print!</strong> The first job after the printer is switched on takes
        about 10 seconds longer while the firmware is loaded.</li>
</ol>
</body>
</html>
README

# ── Step 5: Build the package ───────────────────────────────────────────────

log "Building component package..."
pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "$PKG_ID" \
    --version "$PKG_VERSION" \
    --ownership preserve \
    "$BUILD_DIR/component.pkg"

log "Building product archive..."
PRODUCTBUILD_ARGS=(
    --distribution "$BUILD_DIR/Distribution.xml"
    --package-path "$BUILD_DIR/"
    --resources "$RESOURCES_DIR"
)

if [ -n "$SIGN_IDENTITY" ]; then
    log "Signing with: $SIGN_IDENTITY"
    PRODUCTBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
fi

PRODUCTBUILD_ARGS+=("$SCRIPT_DIR/$OUTPUT_NAME")

productbuild "${PRODUCTBUILD_ARGS[@]}"

rm -rf "$BUILD_DIR"

PKG_SIZE=$(du -sh "$SCRIPT_DIR/$OUTPUT_NAME" | awk '{print $1}')

echo ""
echo "================================================"
echo "  Package built successfully!"
echo "  $SCRIPT_DIR/$OUTPUT_NAME ($PKG_SIZE)"
echo "================================================"
echo ""
echo "To install:  Double-click the .pkg, or:"
echo "  sudo installer -pkg '$SCRIPT_DIR/$OUTPUT_NAME' -target /"
echo ""
echo "To verify contents:"
echo "  pkgutil --payload-files '$SCRIPT_DIR/$OUTPUT_NAME'"
echo ""
if [ -z "$SIGN_IDENTITY" ]; then
    echo "Note: This package is unsigned. Recipients will need to"
    echo "right-click > Open to bypass Gatekeeper, or sign it with:"
    echo "  productsign --sign 'Developer ID Installer: ...' \\"
    echo "    '$OUTPUT_NAME' '${OUTPUT_NAME%.pkg}-signed.pkg'"
    echo ""
fi
