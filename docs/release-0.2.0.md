# Agent Ring 0.2.0

## 新增与改进
- Codex、Cursor 多账号同时监测，支持勾选和拖动排序。
- 平台独立启停；增加 Kimi Code、GLM Coding Plan API Key 配置。
- 优化 macOS 设置页、菜单栏圆环与弹框分页。
- 修复初始焦点、设置页与弹框同时打开的问题。
- 固定账号显示顺序；加载和认证失败保留菜单栏占位。
- Cursor 网络失败显示旧数据及最后成功更新时间。

## 安装与边界
- macOS 13 及以上；DMG 包含 Apple Silicon 与 Intel 通用 App。
- 退出旧版，将 App 拖入 Applications 并替换。账号和设置沿用现有存储。
- 此包采用 ad-hoc 签名，未做 Apple 公证。首次安装可能需要在系统隐私与安全性中允许打开。
- 更新源为 kkk0913/AgentRing；本地未配置更新公钥的旧构建需手动覆盖安装一次。
- Kimi 旧本地 Token 需更换为 Kimi Code API Key；不是 Moonshot 按量 API Key。
- Kimi/GLM 凭据尚未进行真实账户联调；新增平台暂不向蓝牙副屏同步。
- Antigravity 保留原方案；本次未接入 TypeSafe 或 MiMo。
