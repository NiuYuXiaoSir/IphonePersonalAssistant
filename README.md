# IphonePersonalAssistant

个人自用的 iPhone AI 助理（私人工作秘书）。**不上架 App Store**，通过侧载安装到自己的手机上。

## 这个仓库是干什么的

因为手头没有 Mac，iOS App 的编译只能放在云端做。这个仓库承担两件事：

1. **构建**：GitHub Actions 的 macOS runner 把 Swift 代码编译成**未签名**的 ipa
2. **分发**：产物自动发布到固定的 `latest` Release，浏览器打开链接即可下载

签名和安装由电脑端的侧载工具（Sideloadly / AltStore）用免费 Apple ID 完成。

```
push 代码 → CI 编译（约 1 分钟）→ 发布到 latest → 下载 ipa → 侧载安装
```

## 下载安装包

```
https://github.com/NiuYuXiaoSir/IphonePersonalAssistant/releases/download/latest/IPhoneAssistant-unsigned.ipa
```

**在电脑上下载。** 用 Sideloadly 装机时，ipa 全程留在电脑上、通过数据线推进手机，手机不需要联网下载任何东西。每次改动推送后约一分钟即可重新下载。

下载后校验完整性：

```
certutil -hashfile IPhoneAssistant-unsigned.ipa SHA256
```

当前构建的 SHA256 写在 Release 页面的说明里。

> 下载会跳转到 `objects.githubusercontent.com` / `release-assets.githubusercontent.com`，这两个域名在国内的代理规则模式下容易被漏掉。如果 `github.com` 打得开但下载卡住，八成卡在这里，切成全局模式下载十几秒即可。

## 当前阶段：E1 探针

`ios/` 里现在是一个**能力探针**，不是完整产品。它用来验证「云构建 → 侧载装机 → 7 天续签」这条链路，同时测掉几个关键技术假设：

- 免费 Apple ID 的描述文件有效期和 entitlements（App Groups 到底有没有）
- 麦克风 + 后台录音（`UIBackgroundModes: audio`）在免费签名下能不能用
- 日历 / 提醒事项的 EventKit 授权流程，以及**写入待办**的完整路径
- 没有推送能力时，本地通知是否够用
- 重新签名安装后 App 数据是否保留

跑完点「复制报告到剪贴板」，把结果反馈回去。

## 目录结构

```
.github/workflows/build-ipa.yml   云构建流水线
ios/project.yml                   XcodeGen 工程描述（权限声明都在这里）
ios/IPhoneAssistant/              探针源码
  App.swift
  ProbeStore.swift                探针逻辑（含提醒事项写入的原型实现）
  ContentView.swift               探针界面
```

工程文件（`.xcodeproj`）由 `xcodegen` 在 CI 里生成，不入库——这样就不用手工维护 `project.pbxproj`。

## 本地（Windows）怎么改

改完 `ios/` 下的文件，push 即可，剩下交给 CI。本地没有编译器，所以：

- **一次 push 只改一件事**，方便定位问题
- 纯逻辑（prompt、JSON 解析、时间解析）尽量先抽成不依赖 iOS 的模块，将来可以在 Windows 上单独验证

## 注意事项

- 免费 Apple ID 的签名 **7 天过期**，到期后重新装一次即可。覆盖安装不会清除 App 数据（这一点由探针验证）
- 免费账号同时最多装 3 个 App
- 仓库是公开的，但**不要**往里面提交任何密钥。DeepSeek 的 API Key 在 App 运行时输入、存放在手机 Keychain 里，永远不进仓库
