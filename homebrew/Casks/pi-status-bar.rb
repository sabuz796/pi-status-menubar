# Source of truth for the Homebrew cask. The release workflow fills in
# @VERSION@ and @SHA256@ and pushes the result to the tap repo
# (sabuz796/homebrew-pi-status-menubar), so a tag updates both the
# GitHub release and the cask in one run.
cask "pi-status-bar" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/sabuz796/pi-status-menubar/releases/download/v#{version}/PiStatusBar-#{version}.dmg"
  name "Pi Status Bar"
  desc "Menu bar companion for the Pi coding agent"
  homepage "https://github.com/sabuz796/pi-status-menubar"

  depends_on macos: ">= :ventura"

  app "Pi Status Bar.app"

  zap trash: [
    "~/.pi/statusbar",
    "~/.pi/agent/extensions/pi-statusbar.ts",
  ]

  caveats <<~EOS
    Pi Status Bar is signed ad-hoc, not notarized. If macOS blocks the first
    launch, right-click the app and choose Open, or run:
      xattr -dr com.apple.quarantine "/Applications/Pi Status Bar.app"
  EOS
end
