# Source of truth for the Homebrew cask. The release workflow substitutes the
# version and sha256 placeholders and pushes the result to the shared tap
# (sabuz796/homebrew-tap), so a tag updates both the GitHub release and the
# cask in one run. Install line: brew install --cask sabuz796/tap/pi-status-bar
cask "pi-status-bar" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/sabuz796/pi-status-menubar/releases/download/v#{version}/PiStatusBar-#{version}.dmg"
  name "Pi Status Bar"
  desc "Menu bar companion for the Pi coding agent"
  homepage "https://github.com/sabuz796/pi-status-menubar"

  depends_on macos: :ventura

  app "Pi Status Bar.app"

  zap trash: [
    "~/.pi/statusbar",
    "~/.pi/agent/extensions/pi-statusbar.ts",
  ]

  caveats <<~EOS
    On first launch macOS may report the app is from an unidentified developer.
    Clear the quarantine flag once, then open it:

      xattr -dr com.apple.quarantine "/Applications/Pi Status Bar.app"
  EOS
end
