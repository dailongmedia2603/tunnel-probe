#!/bin/bash
# Builds TunnelProbe.tipa (TrollStore). Needs: clang (Xcode or CLT), Go, an
# iPhoneOS SDK (auto-detected via xcrun, or SDK=/path/to/iPhoneOS.sdk), and
# ldid (skipped with a warning when missing — the .tipa then won't install).
set -euo pipefail
cd "$(dirname "$0")"

MINOS=14.0
TARGET="arm64-apple-ios$MINOS"
SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
CLANG="$(xcrun -f clang)"
OUT=build
APP="$OUT/Payload/TunnelProbe.app"
APPEX="$APP/PlugIns/PacketTunnel.appex"

rm -rf "$OUT"
mkdir -p "$APPEX"

echo "==> SDK: $SDK"

echo "==> [1/5] libwg.a (wireguard-go, Go c-archive)"
(
  cd go
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
    CGO_CFLAGS="-target $TARGET -isysroot $SDK -O2" \
    CGO_LDFLAGS="-target $TARGET -isysroot $SDK" \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "../$OUT/libwg.a" .
)

CFLAGS=(-target "$TARGET" -isysroot "$SDK" -O2 -Wall -Wno-unused-result -I"$OUT" -Ishared)
GO_LIBS=("$OUT/libwg.a" -framework CoreFoundation -framework Security -lresolv)

echo "==> [2/5] probehelper (root helper)"
"$CLANG" "${CFLAGS[@]}" helper/helper.c shared/netutil.c "${GO_LIBS[@]}" -o "$APP/probehelper"

echo "==> [3/5] PacketTunnel.appex"
"$CLANG" "${CFLAGS[@]}" -fobjc-arc -fapplication-extension \
  extension/PacketTunnelProvider.m shared/netutil.c "${GO_LIBS[@]}" \
  -framework Foundation -framework NetworkExtension \
  -e _NSExtensionMain -o "$APPEX/PacketTunnel"
cp extension/Info.plist "$APPEX/Info.plist"

echo "==> [4/5] TunnelProbe app"
"$CLANG" "${CFLAGS[@]}" -fobjc-arc \
  app/main.m app/ProbeViewController.m app/RootTask.m "${GO_LIBS[@]}" \
  -framework UIKit -framework Foundation -framework NetworkExtension \
  -o "$APP/TunnelProbe"
cp app/Info.plist "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

echo "==> [5/5] sign + package"
if command -v ldid >/dev/null 2>&1; then
  ldid -Shelper/entitlements.plist "$APP/probehelper"
  ldid -Sextension/entitlements.plist "$APPEX/PacketTunnel"
  ldid -Sapp/entitlements.plist "$APP/TunnelProbe"
elif [ "${REQUIRE_LDID:-0}" = 1 ]; then
  echo "ERROR: ldid not found"; exit 1
else
  echo "WARNING: ldid not found — binaries are NOT signed with entitlements"
fi
(cd "$OUT" && zip -qry TunnelProbe.tipa Payload)
ls -la "$OUT/TunnelProbe.tipa"
echo "==> done: $OUT/TunnelProbe.tipa"
