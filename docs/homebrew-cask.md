# Homebrew cask 模板 · SkillReader

用法（自建 tap，tap 仓库名需为 `homebrew-tap`）：

1. 建 tap 仓库 `huweidong-ai/homebrew-tap`
2. 在 GitHub Releases 发布 `SkillReader-<版本>.dmg` 后，
   把下方文件的 `version` / `sha256` 填好，放进 tap 仓库 `Casks/skillreader.rb`
3. 计算 sha256：`shasum -a 256 SkillReader-<版本>.dmg`
4. 用户即可安装：
   ```bash
   brew tap huweidong-ai/tap
   brew install --cask skillreader
   ```

稳定后可向官方 homebrew-cask 仓库提 PR。

---

```ruby
cask "skillreader" do
  version "1.0"
  sha256 :no_check  # 发布稳定后改为固定 sha256

  url "https://github.com/huweidong-ai/skill-reader/releases/download/v#{version}/SkillReader-#{version}.dmg"
  name "SkillReader"
  desc "Skill package reader and manager: read SKILL.md bundles and share them across AI agents"
  homepage "https://github.com/huweidong-ai/skill-reader"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "SkillReader.app"

  zap trash: "~/.agent"
end
```
