# Agent Ring 自动更新与发布

采用 Sparkle **2.10.0**、ad-hoc 应用签名和 **Ed25519/EdDSA 更新签名**，不要求 Apple 开发者账号或公证。

应用保留 App Sandbox。Installer XPC 负责安装；主程序不再具有 `/Applications/` 读写例外。已有的网络权限用于下载，正式包移除未使用的 Downloader XPC。应用和 helper 不启用 Library Validation；发布脚本分别签署嵌套代码，绝不把主程序沙盒 entitlements 签到 Installer 上。

每小时检查更新，沿用旧版用户的自动检查开关。用户确认后下载、安装和重启；默认不启用静默安装。菜单栏更新徽章继续保留，点击它或「检查更新」打开 Sparkle 标准更新窗口。

## 你需要手动完成的步骤

### 1. 一次性生成并备份生产签名密钥

在项目根目录运行，使用已安装完整 Xcode 的 Mac：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -resolvePackageDependencies \
  -project AgentRing.xcodeproj -scheme AgentRing \
  -clonedSourcePackagesDirPath /tmp/AgentRingSourcePackages

SPARKLE_TOOLS=/tmp/AgentRingSourcePackages/artifacts/sparkle/Sparkle/bin
"$SPARKLE_TOOLS/generate_keys" --account kkk0913.AgentRing
SPARKLE_PUBLIC_KEY=$("$SPARKLE_TOOLS/generate_keys" --account kkk0913.AgentRing -p)
```

私钥保存在当前用户的 macOS Keychain，账号名称为 `kkk0913.AgentRing`。如果已有该账号的密钥，命令会复用它。不要每次发布重新生成密钥。不要使用测试脚本生成的临时密钥发布。

导出到新建的私有临时目录，供下一步上传。不要粘贴私钥到聊天、日志或 Git：

```bash
SPARKLE_EXPORT_DIR=$(mktemp -d)
"$SPARKLE_TOOLS/generate_keys" --account kkk0913.AgentRing \
  -x "$SPARKLE_EXPORT_DIR/private.key"
chmod 600 "$SPARKLE_EXPORT_DIR/private.key"
```

将该文件另存到安全的加密备份或密码管理器。没有 Developer ID 时，丢失这把私钥会使已安装的客户端无法信任后续更新，通常只能要求用户重新手动安装。GitHub Secret 无法下载回原文，不能代替备份。

### 2. 配置 GitHub Actions（一次性）

先确保 `gh auth status` 显示有 `kkk0913/AgentRing` 的配置权限，再执行：

```bash
gh secret set SPARKLE_PRIVATE_KEY --repo kkk0913/AgentRing \
  < "$SPARKLE_EXPORT_DIR/private.key"
gh variable set SPARKLE_PUBLIC_ED_KEY --repo kkk0913/AgentRing \
  --body "$SPARKLE_PUBLIC_KEY"
```

对应 GitHub 网页：Settings → Secrets and variables → Actions。

- Repository secret `SPARKLE_PRIVATE_KEY`：导出的 base64 私钥种子。
- Repository variable `SPARKLE_PUBLIC_ED_KEY`：公钥，用于固定发布身份并核对私钥。

确认已加密备份并上传成功后，删除刚刚导出的临时私钥文件：

```bash
rm "$SPARKLE_EXPORT_DIR/private.key"
rmdir "$SPARKLE_EXPORT_DIR"
```

无需配置 Apple 证书、Developer ID、GitHub Pages 或新服务器。不要在工作流中打印 Secret、使用 `set -x`，或把私钥作为命令行参数传入工具。

### 3. 推送代码，先运行一次 dry run

提交并推送本次修改后，在 Actions → Release → Run workflow 中勾选 `dry_run`（默认开启）。成功后检查构建 artifact 中的 DMG 和 `appcast.xml`。缺失密钥、公私钥不匹配、构建版本不一致、嵌套签名不完整或更新包验签失败都会阻止发布。

本地无公钥的 Debug/Release 构建仍能启动，更新界面会明确显示「此构建未配置更新签名公钥」。本地需要检查正式 feed 时，可以把公开的 `SPARKLE_PUBLIC_ED_KEY` 作为 xcodebuild 参数传入。

### 4. 发布首个 Sparkle 版本

本仓库首次发布计划为 v0.2.0。首次发布允许没有历史 Release；后续版本必须严格递增。不要覆盖已存在的 tag 或正式 Release。

```bash
bash Scripts/set-version.sh 0.2.0
# 审阅、提交并推送包括版本号在内的改动后：
git tag v0.2.0
git push origin v0.2.0
```

工作流会执行：构建 universal App → 嵌套 ad-hoc 签名 → 校验两个版本字段和公钥 → 打包 DMG → 签署更新包和 appcast → 验证最终 DMG → 上传草稿附件 → 公开 Release。

正式 Release **只上传 DMG 和 appcast.xml，不上传 ZIP**。旧版始终优先选择任何 ZIP；即使跳过迁移版的用户直接更新未来版本，也应进入手动 DMG 路径。Sparkle 可以直接安装 DMG 中的 App，因此不需要独立 ZIP。

固定 feed URL：

```text
https://github.com/kkk0913/AgentRing/releases/latest/download/appcast.xml
```

工作流先在草稿上传完整附件，最后才公开，避免 latest 指向不完整的 feed。它拒绝覆盖已公开 Release、拒绝降低 latest 版本，并使用当前密钥验证上一版已签名 feed，防止意外换钥。首次从无 appcast 的旧版迁移时跳过上一版 feed 验签。

### 5. 手动覆盖安装一次，并验收下一次升级

现有用户需要退出旧版，从首个 Sparkle 版本 DMG 拖入「应用程序」并覆盖一次。首次打开仍可能需要系统「隐私与安全性 → 仍要打开」，因为未做 Apple 公证。

发布下一个递增版本后，用已安装的生产包完成一次真实 GitHub 升级，检查：下载、安装、重启、版本号、账户读取、设置、登录时启动。至少在另一台 Mac 上测试；本机临时测试公钥的产物不能更新生产包。

## 本地验证

```bash
bash Scripts/test-release-tools.sh
bash Scripts/test-sparkle-update.sh /tmp/AgentRingSourcePackages/artifacts/sparkle/Sparkle valid
bash Scripts/test-sparkle-update.sh /tmp/AgentRingSourcePackages/artifacts/sparkle/Sparkle tampered-feed
bash Scripts/test-sparkle-update.sh /tmp/AgentRingSourcePackages/artifacts/sparkle/Sparkle tampered-archive
```

后面三个命令需要已登录的 macOS 桌面，运行独立 Bundle ID 的测试 App，使用本机回环 HTTP、临时 EdDSA 密钥和真实 Installer XPC。成功场景要求 `1.0.0 → 2.0.0` 替换并重启；篡改场景要求 Sparkle 拒绝且旧 App 保持 `1.0.0`。它们不会替换 `/Applications/AgentRing.app` 或使用生产账号。测试留下临时目录和独立测试 App 的沙盒容器，方便排查；终端打印其路径与 Bundle ID。

工具单测验证错误版本、篡改包、错误签名密钥、缺失签名、错误下载 URL、空私钥和禁止覆盖现有密钥。CI 自动运行这组检查；GUI 升级测试在本地或有桌面的测试 Mac 上执行。

## 边界

- EdDSA 认证更新来源，不提供 Apple 开发者身份，也不保证首次安装没有 Gatekeeper 提示。
- 私钥、签名后的 DMG 和 appcast 不得在发布后修改；修复必须发新版本。
- `spctl`/公证校验不作为 ad-hoc 分发的发布门槛；`codesign --verify --deep --strict` 和 EdDSA 验签必须通过。
- 首个 feed 公开前，在生产地址检查更新会得到 404，这是发布配置尚未上线，并非有可用更新。
- Sparkle 升级需要同步检查沙盒集成、嵌套签名和端到端测试，依赖固定为精确版本。

官方依据：[基本集成](https://sparkle-project.org/documentation/)、[沙盒与签名](https://sparkle-project.org/documentation/sandboxing/)、[发布更新](https://sparkle-project.org/documentation/publishing/)。
