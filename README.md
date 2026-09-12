# NanoStream Clone

这是根据 `/home/judy/test/IOSAPP/KIPTV.ipa` 和提供的 iPhone 截图静态分析得到的 SwiftUI 复刻工程，目标平台 iOS 16+，按 390pt 竖屏优先设计。

## 已还原的界面与功能

- K-20 IPTV / NanoStream 暗色播放工作台
- 底部胶囊导航：首页、收藏、播放列表、设置
- 首页顶部搜索、全部/4K UHD/FHD/HD 筛选、最近播放横向卡片和双列频道卡片
- 频道详情全屏页：播放器、订阅/频道/节目切换、搜索和频道列表
- 收藏空状态（星标引导）和播放列表卡片
- 频道分组、搜索、收藏星标、最近播放
- AVKit 网络流播放（示例频道提供 HLS 地址）
- XMLTV EPG 节目单设置、频道匹配与播放页当前/后续节目
- M3U / TXT、Xtream Codes、tvHeadend 播放列表添加表单
- 播放设置、HTTP 代理、字幕字号和自动播放选项
- 真实画中画、AirPlay 投影、硬件加速、自动音轨与编码信息
- 播放列表编辑与保存后重新加载

## 在 Xcode 中运行

1. 打开 `Package.swift`。
2. 选择 iOS 16 或更高版本的运行目标。
3. 运行 `NanoStreamClone` executable target。

Linux 容器没有 Apple 的 AVFoundation/SwiftUI SDK，无法在本地执行 iOS 编译或模拟器截图验证；GitHub Actions 使用 macOS 14 + Xcode 15.4 完成真实编译。IPA 仅包含编译后的 Mach-O、Metal 着色器和 plist，没有原始 SwiftUI 图片、Storyboard 或源码；界面使用 IPA 中可确认的类名和文案重建，而不是复制二进制实现。

## GitHub Actions 打包

仓库已包含 `project.yml`、`Resources/AppInfo.plist` 和 `.github/workflows/build-ipa.yml`。工作流会在 GitHub 的 macOS Runner 上生成 Xcode 工程、Archive，并上传 `NanoStreamClone-unsigned.ipa`。

Ubuntu 首次推送：

```bash
cd /home/judy/test/NanoStreamClone
git init
git add .
git commit -m "Initial NanoStream clone"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<你的仓库>.git
git push -u origin main
```

推送后进入 GitHub 仓库的 **Actions → Build IPA → Run workflow**。完成后打开该次运行页面，在 **Artifacts** 下载 IPA。此版本不包含 Apple 签名，不能直接安装到普通 iPhone；后续可在工作流中加入 Apple Developer 证书和 Provisioning Profile。
