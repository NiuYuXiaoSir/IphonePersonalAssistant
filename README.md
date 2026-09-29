# IphonePersonalAssistant

个人自用的 iPhone AI 助理（私人工作秘书）。**不上架 App Store**，通过侧载安装到自己的手机上。

## 这个仓库是干什么的

因为手头没有 Mac，iOS App 的编译只能放在云端做。这个仓库承担三件事：

1. **构建**：GitHub Actions 的 macOS runner 把 Swift 代码编译成**未签名**的 ipa
2. **分发**：产物自动发布到固定的 `latest` Release
3. **报错回传**：编译失败时把编译器诊断写进 `ci/build-error.log` 并提交回仓库——这样没有 Mac 也能读到错误

签名和安装由电脑端的侧载工具（Sideloadly / AltStore）用免费 Apple ID 完成。

```
push 代码 → CI 编译（约 1 分钟）→ 发布到 latest → 下载 ipa → 侧载安装
```

## 下载安装包

```
https://github.com/NiuYuXiaoSir/IphonePersonalAssistant/releases/download/latest/IPhoneAssistant-unsigned.ipa
```

**在电脑上下载。** 用 Sideloadly 装机时，ipa 全程留在电脑上、通过数据线推进手机，手机不需要联网下载任何东西。

下载后校验完整性：

```
certutil -hashfile IPhoneAssistant-unsigned.ipa SHA256
```

当前构建的 SHA256 写在 Release 页面的说明里。

> 下载会跳转到 `objects.githubusercontent.com` / `release-assets.githubusercontent.com`，这两个域名在国内的代理规则模式下容易被漏掉。如果 `github.com` 打得开但下载卡住，八成卡在这里，切成全局模式下载十几秒即可。

## 安装参数（Sideloadly）

- **Bundle ID**：必须取消勾选 `Use automatic bundle ID`，手动填 `com.niuyuxiaosir.iphoneassistant.probe`
  - 自动 bundle ID 每次安装都会变，iOS 会把每次安装当成全新的 App、清空数据，而免费签名每 7 天要重装一次
- **密码**：用的是 App 专用密码（appleid.apple.com 生成），不是 Apple ID 登录密码
- 装完要在 设置 → 通用 → VPN 与设备管理 里信任证书，并在 设置 → 隐私与安全性 → 开发者模式 里打开开关

## App 现在能做什么

| 页面 | 功能 |
|---|---|
| 会议 | 一键录音（每 60 秒存一段、中断自动恢复、App 被杀后能找回）、列表、音频试听、Markdown 导出 |
| 会议 → 详情 → 自动转写 | 逐段 Apple Speech 识别，单段超时保护、逐段增量保存 |
| 会议 → 详情 → AI 纪要 | 生成摘要/议题/决议/待办/日程/未决问题，审阅后写入提醒事项与日历 |
| 速记 | 一句话 → AI 拆成待办/日程/备忘 → 确认 → 写入系统 |
| 设置 | DeepSeek 官方 / OpenCode Zen / 自定义，API Key 存 Keychain，带真实连接测试 |
| 诊断 | E1 探针（后台录音、EventKit 读写、签名信息）+ 运行日志导出 |

## 目录结构

```
.github/workflows/build-ipa.yml   云构建流水线（含编译错误回传）
ci/build-error.log                编译失败时自动写入的诊断信息
ios/project.yml                   XcodeGen 工程描述（权限声明都在这里）
ios/IPhoneAssistant/
  App.swift / RootView.swift      入口与四页签
  AppLog.swift                    结构化日志（无 Mac 开发的基础设施）

  LLMProvider.swift               供应商预设
  LLMService.swift                OpenAI 兼容客户端
  SettingsStore.swift             设置与 Keychain 凭证
  AssistantView.swift             速记页
  AIStructurer.swift              文本 → 结构化条目
  SystemWriter.swift              写提醒事项 / 日历

  RecordingService.swift          分段录音
  MeetingStore.swift              会议存储与孤儿段恢复
  MeetingsView.swift              会议列表
  RecordView.swift                录音页
  MeetingDetailView.swift         会议详情
  TranscriptionService.swift      语音识别
  TranscriptionView.swift         转写页
  MeetingSummarizer.swift         会议纪要 prompt 与解析
  MeetingSummaryView.swift        纪要页

  ProbeStore.swift / ContentView.swift   诊断页（E1 探针）
```

工程文件（`.xcodeproj`）由 `xcodegen` 在 CI 里生成，不入库。

## 本地（Windows）怎么改

改完 `ios/` 下的文件 push 即可，剩下交给 CI（约 1 分钟）。本地没有编译器，所以：

- **一次 push 只改一件事**，方便定位问题
- 纯逻辑（prompt、JSON 解析、时间解析）尽量先抽成不依赖 iOS 的模块，将来可以在 Windows 上单独验证
- 编译失败看 `ci/build-error.log`

## 注意事项

- 免费 Apple ID 的签名 **7 天过期**，到期后重新装一次即可。覆盖安装不会清除 App 数据
- 免费账号同时最多装 3 个 App
- 仓库是公开的，但**不要**往里面提交任何密钥。API Key 在 App 运行时输入、存放在手机 Keychain 里，永远不进仓库
- 会议录音涉及法律合规：录音前请确认符合当地法律和他人知情权
