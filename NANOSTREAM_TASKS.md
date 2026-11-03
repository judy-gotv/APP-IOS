# NanoStream 项目任务清单

> 状态说明（第 1 轮审计后）：下面打勾的项表示“代码已实现”，**不是**“已在真机/授权源上验收通过”。
> 最终验收只看下面 8 项未完成项：签名 IPA、真机逐页截图、授权源网络播放验收、KSPlayer GPL 合规定夺、清除收藏入口真机验证、ITS 上架声明、AppIcon 与 LaunchScreen 资源、补单元测试 target。
> 在这 8 项完成前，任何打勾项都不得对外宣称为已验证功能。


- [x] 移除内置假播放列表与假频道，首次启动显示空状态。
- [x] M3U/M3U8 网络地址异步加载并显示错误。
- [x] Xtream 服务器、用户名、密码加载。
- [x] 本地 M3U 文件选择与导入。
- [x] 播放列表持久化、删除、刷新。
- [x] 收藏与播放历史持久化、清空操作（含清除收藏入口）。
- [x] AVPlayer / KSPlayer / Auto 三选一并保存。
- [x] 网络缓存滑杆接入 AVPlayer/KSPlayer。
- [x] 稳定 AVPlayer 生命周期，Auto 在失败后切换 KSPlayer。
- [x] AVPlayerLayer + AVPictureInPictureController 原生画中画能力按设置启用（此前误写为 AVPlayerViewController，实际实现为 AVPlayerLayer 渲染 + AVPictureInPictureController）。
- [x] 语言选择持久化并更新导航文字。
- [x] 首页左上角分类菜单与真实分组筛选。
- [x] 首页网格布局切换（2列 / 3列 / 4列）。
- [x] 移除主页 4K UHD/FHD/HD 假筛选，频道仅按真实分组与搜索过滤。
- [x] 最近播放卡片可点击并进入详情播放页。
- [x] 详情页订阅/频道/节目导航、分组按钮均有真实行为。
- [x] KSPlayer 使用精简控制层，避免满屏控制按钮。
- [x] AVPlayer 4K 无画面时检测视频轨并自动回退 KSPlayer。
- [x] 新增繁體中文本地化（中/英/越/繁四语表；第 3 轮修复已把设置说明与确认框等硬编码文案补进表——但表是手工维护的，之后新增文案仍须手动进表，未进表的键会原样显示简体中文，不会自动翻译）。
- [x] System/Light/Dark 主题选择。
- [x] Cyberpunk/落日金/剧毒绿/霓虹粉/深海蓝色彩主题。
- [x] KSPlayer 与 AVPlayer 共用精简播放控制层，中间播放按钮样式一致。
- [x] AVPlayer 使用 AVPlayerLayer 自定义渲染，移除系统右上角音量按钮。
- [x] AVPlayer 使用真实 AVPictureInPictureController 画中画与 AVRoutePickerView 投影入口。
- [x] AVPlayer 编码信息从当前 AVPlayerItem 轨道读取分辨率、帧率、码率和编码类型。
- [x] 播放详情页固定播放器，频道/订阅/节目列表独立滚动。
- [x] 硬件加速与自动选择音轨设置真实接入 KSPlayer；AVPlayer 侧硬件解码为系统默认行为，无公开开关可接（设置项在 AV 侧不产生额外行为，见 README 缺口说明）。
- [x] 播放列表支持编辑名称、地址、账号、密码并保存后重新加载（远端类型；本地文件编辑无新文件内容时仅改名，不重新加载）。
- [x] XMLTV EPG 地址设置、解析、频道匹配与播放页节目展示。
- [x] GitHub macOS Runner 编译、KSPlayer 依赖和未签名测试包封装（不是标准签名 IPA；签名仍为待办）。
- [x] EPG 节目单支持保存地址（保存与更新为同一操作）、手动刷新、前台定时刷新、删除和上次更新时间。
- [x] AVPlayer 播放失败或无视频画面时真实回退 KSPlayer（回退后 KSPlayer 会用自己的轨道信息覆盖编码信息栏，并非保留 AVPlayer 的编码信息）。
- [x] 播放页按真实媒体选择组显示音频轨道；HLS 变体可发现时显示真实清晰度选项，不可用时不显示假选项。
- [x] 首页支持 2 列 / 3 列 / 4 列，4 列频道名称允许多行完整展示。
- [x] 首页右上角改为真实订阅选择，并按订阅缓存/重新加载对应频道。
- [x] 增加真实预览开关；开启后只为可见卡片建立有限数量 AVPlayer 预览连接，关闭后不连接直播流。
- [x] 增加统一延迟开关；AVPlayer/HLS 可取得 seekable range 时显示真实毫秒值，否则显示“延迟不可用”。
- [x] 播放页和预览卡片共用真实延迟显示规划。
- [ ] 使用 Apple Developer 证书配置签名 IPA。
- [ ] 在真实 iPhone 上逐页截图回归并完成最终视觉校准。
- [ ] 使用授权的 M3U/Xtream 源完成网络播放验收。

- [ ] KSPlayer GPL 合规定夺：确认 KSPlayer/FFmpeg 许可证义务、补齐 LICENSE 文件、决定 Reference-Original 文件是否从仓库历史清除（法律结论由用户定夺，见 README）。
- [ ] 补齐清除收藏入口的真机验证（代码已实现，见上），并与签名 IPA、真机截图、授权源验收一并验收。
- [ ] 填写 ITSAppUsesNonExemptEncryption 上架声明（勿擅自填 false/true，需按实际加密使用情况确认）。
- [ ] 补齐 AppIcon 与 LaunchScreen 资源（当前无 Assets，无法凭空造图标）。
- [ ] 补单元测试 target（当前 App target 为 executable，无法直接 import 做单元测试；需先拆分逻辑模块再接测试，否则会编不过）。
