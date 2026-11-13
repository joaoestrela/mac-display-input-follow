# Tap this repository directly:
#   brew tap joaoestrela/display-follow https://github.com/joaoestrela/mac-display-input-follow
#   brew install --HEAD display-follow
class DisplayFollow < Formula
  desc "Move macOS windows off an external monitor when it switches to another input"
  homepage "https://github.com/joaoestrela/mac-display-input-follow"
  license "MIT"
  head "https://github.com/joaoestrela/mac-display-input-follow.git", branch: "main"

  depends_on arch: :arm64
  depends_on :macos

  def install
    system "make", "build", "check"
    bin.install ".build/display-follow"
  end

  service do
    run [opt_bin/"display-follow", "run"]
    keep_alive true
    process_type :background
    log_path var/"log/display-follow.log"
    error_log_path var/"log/display-follow.log"
  end

  def caveats
    <<~EOS
      Run setup while each monitor is showing this Mac, then start the service:
        display-follow setup
        brew services start display-follow

      Don't also use `make install` from the repository: two watchers would fight.
    EOS
  end

  test do
    assert_match(/\d+\.\d+\.\d+/, shell_output("#{bin}/display-follow version"))
  end
end
