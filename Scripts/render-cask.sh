#!/bin/sh
set -eu
VERSION="${1:-}"
SHA256="${2:-}"
ARCH="${3:-}"
case "$VERSION" in
  *[!0-9.]*|.*|*..*|*.) echo "invalid version" >&2; exit 1 ;;
esac
[ "$(printf '%s' "$VERSION" | awk -F. '{print NF}')" = 3 ] || { echo "invalid version" >&2; exit 1; }
[ "${#SHA256}" = 64 ] || { echo "invalid sha256" >&2; exit 1; }
case "$SHA256" in *[!0-9a-f]*) echo "invalid sha256" >&2; exit 1 ;; esac
case "$ARCH" in arm64|universal) ;; *) echo "architecture must be arm64 or universal" >&2; exit 1 ;; esac

cat <<EOF
cask "nemo" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/SeungheonOh/nemo/releases/download/v#{version}/Nemo-#{version}.dmg"
  name "Nemo"
  desc "Offline speech dictation with NVIDIA Nemotron ASR"
  homepage "https://github.com/SeungheonOh/nemo"

  livecheck do
    url :url
    strategy :github_latest
  end

EOF
if [ "$ARCH" = arm64 ]; then
  printf '  depends_on arch: :arm64\n'
fi
cat <<'EOF'
  depends_on macos: :sonoma

  app "Nemo.app"

  uninstall quit: "dev.nemo.dictate"

  zap trash: [
    "~/Library/Application Support/Nemo",
    "~/Library/Logs/Nemo.log",
    "~/Library/Preferences/dev.nemo.dictate.plist",
  ]
end
EOF
