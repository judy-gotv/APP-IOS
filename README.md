# NanoStream Clone

本工程是 SwiftUI IPTV 播放器，目标平台 iOS 16+，按 390pt 竖屏优先设计。界面与功能按原 App 的公开行为重建（非复制二进制实现）。

## 已实现的功能

- 底部胶囊导航：首页、收藏、播放列表、设置
- 首页顶部搜索、分组筛选、最近播放横向卡片和 2/3/4 列频道卡片
- 频道详情页：播放器、订阅/频道/节目切换、搜索和频道列表
- 收藏空状态（星标引导）和播放列表卡片；收藏页可滚动
- 频道分组、搜索、收藏星标、最近播放
- AVPlayer（AVPlayerLayer）与 KSPlayer 双引擎播放，引擎可在设置中切换
- 真实画中画、AirPlay 投影、自动音轨、编码信息、播放延迟指示
- XMLTV EPG 节目单设置、频道匹配与播放页当前/后续节目
- M3U / TXT、Xtream Codes、tvHeadend 播放列表添加与编辑表单
- 播放设置、网络缓存、播放器偏好、色彩主题
- 播放列表编辑与保存后重新加载

## 明确的缺口（不要误读为已实现）

- **不提供示例频道。** 用户必须自己添加订阅；没有内置播放地址。
- **没有 4K 画质筛选。** 画质标签只归一化订阅源自带的 resolution/quality 字段，缺失时显示未知，不从频道名猜测画质。
- **没有自动播放。** 播放需用户点选频道。
- **User-Agent / HTTP 代理设置仅作用于 M3U 与 EPG 请求**，KSPlayer 不读取这两个设置。
- **字幕字号设置暂未接入播放器字幕渲染**，仅保存偏好。
- **EPG 仅在 App 前台运行时刷新**，未接入 BGTask 后台刷新。
- **硬件加速是 AVPlayer 的系统默认行为**，没有可公开切换的 AVPlayer 开关；该设置主要影响 KSPlayer。
- **CI 产物是未签名测试包，不可安装**，仅供解包检查；签名与 Provisioning Profile 是待办任务（见 NANOSTREAM_TASKS.md）。

## 在 Xcode 中运行（唯一构建路径）

1. 安装 Xcode 15.4（与 `project.yml` 和 CI 一致）。
2. 运行 `xcodegen generate --spec project.yml` 生成 Xcode 工程。
3. 在 Xcode 中选择 iOS 16 或更高版本的运行目标，运行 `NanoStreamClone`。

`Package.swift` 仅为占位：它**不是**构建路径，也**不能**用来对纯逻辑源码做类型检查——其 executable 目标编译全部 `Sources/` 树（含 SwiftUI/AVKit/KSPlayer 界面代码），需要 Apple SDK，在 Linux 上编不过；它只用来在 `project.yml` 旁标明 KSPlayer 版本（2.3.4）。不要按旧说明“打开 Package.swift 运行 executable”来构建本 App；真实构建只走 XcodeGen。

## GitHub Actions 打包

仓库已包含 `project.yml`、`Resources/AppInfo.plist` 和 `.github/workflows/build-ipa.yml`。工作流在 push 到 main 且改动 `Sources/`、`Resources/`、`project.yml`、`Package.swift` 或 `.github/workflows/` 本身时自动触发（也可手动触发），在 GitHub 的 macOS 14 + Xcode 15.4 Runner 上生成 Xcode 工程、执行 `xcodebuild build`（**不是** `archive`，不签名），并上传带完整提交 sha 的未签名测试包（`.zip`，内含 `Payload/` 与未签名说明 `UNSIGNED_NOTICE.txt`）与 sha256。

完成后打开该次运行页面，在 **Artifacts** 下载测试包。此版本不包含 Apple 签名，不能直接安装到普通 iPhone；后续可在工作流中加入 Apple Developer 证书和 Provisioning Profile。

## Reference-Original 与合规待确认

`Reference-Original/` 存放静态分析时得到的两个参照文件，**已从 App 资源中排除，不随 App 分发**：

- `NanoStream-Info.plist`：原 App 的 Info.plist（含原 bundle id、原显示名及构建元数据），仅作字段对照用。
- `KSPlayer-default.metallib`：已编译的 Metal 着色器库，无源码、无版本对应关系，本 App 不加载它。

**KSPlayer GPL 合规尚未确认。** KSPlayer 的许可证、依赖（FFmpeg 等）是否要求本 App 以特定方式开源或声明，目前未做法律结论，仓库也**没有** LICENSE 文件。发版前必须由用户定夺合规方案；本 README 不声称已解决该问题。相关任务见 NANOSTREAM_TASKS.md。

## 隐私说明

- 播放列表密码只存系统 Keychain（service `com.k20.nanostream.clone.xtream`，按播放列表 UUID 分账号），不写进 UserDefaults 的 SavedState。
- 旧版本存入 UserDefaults 的明文密码在启动时迁移进 Keychain 后清除。
- Keychain 项的 accessible 属性为 `kSecAttrAccessibleWhenUnlocked`（仅本机解锁后可读，不走 iCloud 同步）；写入后会回读校验，校验失败时旧密码不清除、不提交编辑，避免写入失败丢凭证。启动迁移时还会清洗端点字符串里嵌的凭证（粘贴的 `get.php?username=&password=`、userinfo），不只清密码字段。
- HTTP 代理密码同样只存系统 Keychain（与播放列表密码不同的 service，按剥离后的代理身份 `user@host:port` 或 `host:port` 分账号），不在 UserDefaults 里留明文。字段里带的密码在离场确认时迁移进 Keychain 并改写为剥离形式（设置页打开期间的请求直接用字段内联密码认证，不先迁移；字段未打开时则在发起请求前迁移）；迁移失败时仍以明文保存在本地，并在设置页亮红字警告。清除字段（或字段变空）会删除上次记录身份的已存密码，设置页的“清除已存代理密码”按钮删除当前身份的密码并作废已缓存会话；换到另一代理身份并迁移成功时，上一身份的已存密码一并删除，只保留当前身份；无内联密码时换身份同样删除上一身份。设置页的“清除全部已存代理密码”按钮（仅在存有任一代理密码时出现）可一次性清除所有历史身份的孤儿密码；该按钮只删除 Keychain 条目，若字段中仍带有密码，离场确认时仍会重新存入（按钮旁有同样说明）。
- App 不会在日志中输出带凭证的完整 Xtream 地址。
- 本 App 使用 App Transport Security 的任意加载（`NSAllowsArbitraryLoads`），原因是 IPTV 订阅源普遍为 http 明文地址；这是有意的取舍，不是疏忽。

## EPG 时区说明

XMLTV 节目时间缺时区时按 UTC 解析（XMLTV 惯例）。此前版本静默使用设备时区，会导致节目整体错位；已升级的用户若发现节目时间偏移，请检查节目单来源是否带时区偏移。

## 本地开发提示

Linux 容器没有 Apple 的 AVFoundation/SwiftUI SDK，无法在本地执行 iOS 编译或模拟器截图验证；GitHub Actions 使用 macOS 14 + Xcode 15.4 完成真实编译。
