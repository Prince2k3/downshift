# Homebrew formula for the Prince2k3/homebrew-tap repository (Formula/dshift.rb).
# scripts/update-formula.sh <version> fills in the url and sha256 after the tag is pushed.
class Dshift < Formula
  desc "Route each Claude Code and Codex prompt to the cheapest model that can handle it"
  homepage "https://github.com/Prince2k3/downshift"
  url "https://github.com/Prince2k3/downshift/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "86ca4f3b31a0cbc797613a1199cd1e20fc03f5da161f34961f535ac0542e7547"
  license "MIT"
  head "https://github.com/Prince2k3/downshift.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/dshift"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/dshift --version").strip
    assert_match "cloudflare", shell_output("#{bin}/dshift hosts list")
  end
end
