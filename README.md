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
| 会议 | 一键录音（每 60 秒存一段、中断后**立刻把当前段封存**并每 3 秒重试接上、本应用被系统回收后能找回）。界面和记录里显示的都是**实际录到的时长**，被来电打断的那段单独标成「漏录」。列表按 **年 → 月 → 日** 折叠，默认展开最近一天；搜索按标题或会议文字匹配，历史关键词留成可点的标签 |
| 会议 → 详情 | 深色区一条常驻播放胶囊（整场连续播放、跨段拖动定位、点某一段从那里播），下面一张米黄的「纸」上压着「转写 / 纪要 / 录音 / 导出」四个文件夹标签 |
| 会议 → 详情 → 转写 | 逐段苹果语音识别，单段超时保护、逐段增量保存 |
| 会议 → 详情 → 纪要 | 生成摘要/议题/决议/待办/日程/未决问题，按文档排版（不是一堆卡片），审阅后写入提醒事项与日历 |
| 会议 → 详情 → 导出 | 文本导出 + **把多段录音合并成一个 .m4a**（分段是防「App 被杀导致整段录音报废」的保险，合并是听、发、存档要的整文件） |
| 对话 | **一段对话一个话题，而且记得住**：每轮都带着「和这句话相关的长期记忆 + 最近几天的流水 + 这段对话的往来」去问模型，回复是一句人话（问「我今天做了什么」「明天要做什么」会照着记录答），下面再跟要建的条目卡片。说一句话（打字 / 说话 / **拍照或选相册**）就把里面的东西建出来，没有「解析」这一步；勾选确认后写进系统，可以接着上一条改（「第二条改成周五」）。助手回复下面有复制 / 朗读 / 删除三个小按钮 |
| 对话 → 右上角脑子 | **记忆页**：助理到底记住了什么（长期记忆 + 按天分的流水），记错的可以左滑删掉，也可以整体清空 |
| 速记 | 手动新建：选类型（待办 / 日程 / 备忘 / 提醒）→ 填标题和时间 → 保存。不联网、不需要密钥。记下的东西也会进每日流水。页面底部能看已记的备忘和已排的通知（可取消） |
| 余额 | 对话页和会议详情页顶上常驻一个胶囊：DeepSeek 官方显示金额（含赠送），OpenCode Go 显示三个订阅窗口里最紧的那个的剩余百分比。点一下重新查；每用一次模型（整理完一段话、生成完一份纪要）自动刷新一次，设置页有明细和重置时间 |
| 设置 | DeepSeek 官方 / OpenCode Go（订阅）/ OpenCode Zen / 自定义，密钥存系统钥匙串，带真实连接测试和「拉取模型列表」 |
| 诊断 | E1 探针（后台录音、日历提醒读写、签名信息）+ 运行日志导出 |

## 数据都存在哪儿：一个本机 SQLite

对话、记忆、每日流水都在 `Documents/assistant.sqlite3` 里（系统的 sqlite3，没有第三方库，开了文件共享所以「文件」App 里能直接拷出来看）。分三块：

| 表 | 内容 |
|---|---|
| `chat_threads` / `chat_folders` / `chat_entries` | 对话会话、分组、每条消息（消息体是 JSON，图片仍然是 `chatImages/` 下的文件）。旧版本的 `chat.json` 第一次启动时自动导入，然后改名成 `chat.json.imported` 留着 |
| `memories` | 长期记忆：关于你的稳定事实、偏好、人物、在做的项目。按内容去重 |
| `timeline` | 每日流水：`done`（做了什么）/ `plan`（打算做什么）/ `note`（记下的信息），按天查 |

记忆怎么进模型：每轮对话前，客户端挑出**和这次说的话相关**的长期记忆（中文用二元组重叠算相关性，再按新旧加权），加上最近 7 天到未来 3 天的流水，拼成【长期记忆】【最近几天】两段塞进 prompt；模型那一边固定返回 `{reply, items, remember}` 三段——`reply` 是要说的话，`items` 是要建的条目，`remember` 是要记住的东西（落库）。所以「上午去厂里看了桥杆」进 `done`，「明天把报价单发给采购」进 `plan`，第二天问「明天要做什么」就有东西可答。

记忆是给模型看的上下文，错的留着会一直误导它——所以记忆页里能逐条删，也能整体清空。

会议记录没进数据库，还是 `meetings.json` + `recordings/` 下的音频文件：音频本身必须留在文件系统里（几十上百 MB 的音频塞进数据库没有好处，而且合并导出、分享都要一个真实文件），记录跟着音频走最省心。备忘也还是 `notes.json`。

列表里的「分组 / 今天 / 昨天 / 本月 / 更早」是**冻结行**：滚动时钉在屏幕顶上不动，下面过去的行从它后面穿过——和表格冻结首行一个意思（用 `.plain` 的 List 加 Section header 做的，见 `YBPinnedHeader`）。

界面整套按元宝的样子做：纯黑底 + 深灰卡片、主操作是卡片正中一个蓝图标加蓝字、分组是一张卡里若干行（首尾各自收圆角）、文档类页面反过来用暖米色的纸。所有颜色、字号、组件都收在 `ios/IPhoneAssistant/YuanbaoStyle.swift` 一个文件里，改一处全app跟着变；深浅色各有一套值，切到浅色模式不会变成白字压白底。

关于时间：发给模型的上下文里带的是**当前时刻**（含时区和星期），不是只有日期。像「10 分钟后提醒我」这种相对表达，除了让模型换算，客户端还会按本地时间再算一遍绝对时间覆盖掉模型给的值——模型的日期算术错得很有规律，而错的往往正是最要紧的那条。提醒默认到点弹通知，只有明说「提前半小时提醒我」才会提前。

条目最终落到哪儿由模型判断，四选一，卡片上显示目标并且能手动改：

| 类型 | 去处 | 判断依据 |
|---|---|---|
| 待办 | 提醒事项的「AI助理」列表 | 需要事后回来打勾、或时间比较远 |
| 日程 | 日历的「AI助理」 | 要占用一段时间（会议、约人） |
| 提醒 | 本机通知，弹完就完 | 几分钟到几小时内响一下，不用跟踪完成 |
| 备忘 | 本应用内的备忘列表 | 只是信息，不需要行动 |

长按图标有快捷菜单：开始录音 / 新建对话 / 速记一条。

## 目录结构

```
.github/workflows/build-ipa.yml   云构建流水线（含编译错误回传）
ci/build-error.log                编译失败时自动写入的诊断信息
tools/make-appicon.ps1            在 Windows 上生成 App 图标（产物已入库）
ios/project.yml                   XcodeGen 工程描述（权限声明、快捷菜单都在这里）
ios/IPhoneAssistant/
  App.swift / RootView.swift      入口与五个页签
  AppRouter.swift                 快捷菜单的接管与页签跳转
  AppLog.swift                    结构化日志（无 Mac 开发的基础设施）
  YuanbaoStyle.swift              界面语汇的唯一出处（色板 / 字号 / 卡片 / 行 / 标签页 / 波形）
  Assets.xcassets                 图标与主题蓝

  LLMProvider.swift               供应商预设
  LLMService.swift                OpenAI 兼容客户端
  BalanceStore.swift              余额 / 订阅用量（DeepSeek 与 OpenCode Go 两个接口）
  SettingsStore.swift             设置与系统钥匙串凭证
  SQLiteDatabase.swift            本机 SQLite 封装 + 建表（对话 / 记忆 / 流水）
  MemoryStore.swift               记忆库：长期记忆 + 每日流水 + 挑上下文给模型
  MemoryView.swift                记忆页（记了什么、逐条删）
  ChatListView.swift              对话列表（新建 / 分组 / 时间分段）
  ChatView.swift                  一段对话（说话即创建，带记忆）
  ChatStore.swift                 对话的存储（SQLite，图片在 chatImages/）
  CameraPicker.swift              相机拍照
  AssistantView.swift             速记页（手动新建表单）
  AIStructurer.swift              文本 → 回复 + 结构化条目 + 要记的事
  SystemWriter.swift              写提醒事项 / 日历 / 通知
  NotificationService.swift       本地通知的排期、查看与取消
  NoteStore.swift                 备忘存储（notes.json，备忘录没有公开写入接口）

  RecordingService.swift          分段录音（中断即封存 + 断线重连 + 记实际时长）
  MeetingStore.swift              会议存储与孤儿段恢复
  MeetingsView.swift              会议列表（年月日折叠）
  RecordView.swift                录音页
  MeetingDetailView.swift         会议详情（播放条 + 四个分页）
  MeetingPlayer.swift             跨段连续播放
  MeetingAudioExport.swift        多段合并成一个 m4a
  TranscriptionService.swift      语音识别
  TranscriptionView.swift         转写页
  MeetingSummarizer.swift         会议纪要 prompt 与解析
  MeetingSummaryPanel.swift       纪要面板（嵌在详情页里）

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
