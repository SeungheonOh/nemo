cask "nemo" do
  version "0.2.0"
  sha256 "c94c01e2b2b54afb5fa782c57441c842fdf969bfd399b1c500d17b6e3f396bf1"

  url "https://github.com/SeungheonOh/nemo/releases/download/v#{version}/Nemo-#{version}.dmg"
  name "Nemo"
  desc "Offline speech dictation with NVIDIA Nemotron ASR"
  homepage "https://github.com/SeungheonOh/nemo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Nemo.app"

  uninstall quit: "dev.nemo.dictate"

  caveats do
    puts "Nemo is not notarized. If macOS blocks its first launch, use System Settings → Privacy & Security → Open Anyway after verifying you trust this release."
    unsigned_accessibility
  end

  zap trash: [
    "~/Library/Application Support/Nemo",
    "~/Library/Logs/Nemo.log",
    "~/Library/Preferences/dev.nemo.dictate.plist",
  ]
end
