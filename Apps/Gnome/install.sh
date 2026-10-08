#!/bin/sh
# Builds the GNOME app in release mode and installs it for the current user
# (or into PREFIX). The Swift runtime is linked statically, so only GTK 4,
# libadwaita and SQLite are needed at run time.
#
#   Apps/Gnome/install.sh                 # into ~/.local
#   PREFIX=/usr/local sudo -E Apps/Gnome/install.sh
#   Apps/Gnome/install.sh --uninstall
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${PREFIX:-$HOME/.local}
lib="$prefix/lib/circles-gnome"
bin="$prefix/bin"
share="$prefix/share"
id=dev.circles.Circles

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$lib" "$bin/circles-gnome" "$share/applications/$id.desktop" "$share/metainfo/$id.metainfo.xml" \
        "$share/icons/hicolor/scalable/apps/$id.svg" "$share/icons/hicolor/symbolic/apps/$id-symbolic.svg"
    echo "Removed Circles from $prefix."
    exit 0
fi

swift build -c release --static-swift-stdlib --package-path "$here" --product CirclesGnome
build="$(swift build -c release --package-path "$here" --show-bin-path)"

# The executable finds its resources (icons) in the bundle beside it, so both
# live in one directory; the command on PATH is a symlink to it.
mkdir -p "$lib" "$bin" "$share/applications" "$share/metainfo" \
    "$share/icons/hicolor/scalable/apps" "$share/icons/hicolor/symbolic/apps"
install -m 755 "$build/CirclesGnome" "$lib/CirclesGnome"
rm -rf "$lib/CirclesGnome_CirclesGnome.resources"
cp -R "$build/CirclesGnome_CirclesGnome.resources" "$lib/"
ln -sf "$lib/CirclesGnome" "$bin/circles-gnome"

install -m 644 "$here/data/$id.desktop" "$share/applications/"
install -m 644 "$here/data/$id.metainfo.xml" "$share/metainfo/"
# The app icon lives in the app's resource bundle (so it always resolves, even
# uninstalled); install the system copy from there.
icons="$here/Sources/CirclesGnome/Icons/hicolor"
install -m 644 "$icons/scalable/apps/$id.svg" "$share/icons/hicolor/scalable/apps/"
install -m 644 "$icons/symbolic/apps/$id-symbolic.svg" "$share/icons/hicolor/symbolic/apps/"

command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" || true
command -v update-desktop-database >/dev/null && update-desktop-database -q "$share/applications" || true
echo "Installed Circles into $prefix. Run circles-gnome, or find Circles in your app launcher."
