# 没有 Mac，怎么把这个 App 装到 iPhone 上

结论先说：**能装。不需要 Mac，也不需要买开发者账号。**

Xcode 本身只有 macOS 版本，Windows 装不了（虚拟机装 macOS 可以，但要 10GB+ 下载、折腾驱动、还慢）。下面这条路更省事：

> **GitHub 的免费 macOS 机器负责编译 → 你的 Windows 负责签名 → iPhone 安装**

全程零成本，只用免费账号。

---

## 整体流程

```
你的 Windows                          GitHub 云端                    你的 iPhone
─────────────                         ───────────                    ───────────
1. 推送代码  ────────────────────▶  2. macOS 机器编译
                                      产出未签名 .ipa
3. 下载 ipa  ◀────────────────────
4. Sideloadly 签名 ──────────────────────────────────────────────▶  5. 安装完成
```

---

## 第一步：注册 GitHub（已有就跳过）

https://github.com/signup

免费账号就行，不需要付费。

---

## 第二步：装两个工具

### Git

https://git-scm.com/download/win

下载后一路下一步安装。装完**重开一个终端**（很重要，否则 PATH 没生效）。

验证：

```bash
git --version
```

### GitHub CLI（可选，但强烈建议）

https://cli.github.com/

装完执行一次登录：

```bash
gh auth login
```

选 `GitHub.com` → `HTTPS` → `Login with a web browser`，浏览器里授权一下。

> 有了它，后面的建仓库和推送一条命令搞定。没有的话要手动去网页建仓库、还要生成 Token，麻烦不少。

---

## 第三步：推送代码

打开终端，进到工程目录：

```bash
cd C:\Users\Administrator\Desktop\dshporject\NovelReader
node tools/push-to-github.mjs
```

脚本会问你仓库名和用户名，然后自动建仓库、提交、推送。

看到 `推送成功` 就好了。

<details>
<summary>不想用脚本？手动操作</summary>

```bash
cd C:\Users\Administrator\Desktop\dshporject\NovelReader
git init
git add -A
git commit -m "feat: iOS 小说阅读器"
git branch -M main
git remote add origin https://github.com/你的用户名/novel-reader.git
git push -u origin main
```

推送时提示输密码 —— **不是账号密码**，是 Personal Access Token。
去 https://github.com/settings/tokens 生成，勾 `repo` 权限。

</details>

---

## 第四步：云端编译

1. 打开 `https://github.com/你的用户名/novel-reader/actions`
2. 左边栏点 **Build iOS IPA**
3. 右边有个 **Run workflow** 按钮，点它 → 绿色 **Run workflow**
4. 等 5-10 分钟

第一次会久一点，因为要装 Xcode 依赖。之后有缓存会快很多。

构建完成后：
- 点进那次运行记录
- 页面**最底部**有个 **Artifacts** 区域
- 下载 `NovelReader-unsigned-ipa.zip`，解压得到 `.ipa`

> ⚠️ 如果构建失败，点开红色那一步看日志。常见原因是 Xcode 版本或 scheme 问题，把日志发我，我改。

---

## 第五步：用 Sideloadly 签名安装

### 装 Sideloadly

https://sideloadly.io/

Windows 版直接下载安装。同时装 **iTunes**（微软商店版或官网版都行）——Sideloadly 需要它的驱动来连 iPhone。

### 安装步骤

1. iPhone 用数据线连电脑，手机上点 **信任此电脑**
2. 打开 Sideloadly
3. **IPA 文件**：拖入刚下载的 `.ipa`
4. **Apple ID**：填你的 Apple ID（就是登录 iCloud 那个邮箱）
5. 点 **Start**
6. 会弹窗要密码 —— 输入 Apple ID 密码
   - 如果开了双重验证，需要去 https://appleid.apple.com 生成一个 **App 专用密码**填进去
7. 等进度条走完

### 在 iPhone 上信任

装完后 App 打不开，会提示"不受信任的开发者"。这是正常的：

**设置 → 通用 → VPN与设备管理 → 开发者APP → 你的 Apple ID → 信任**

然后就能打开了。

---

## 关于 7 天限制

用免费 Apple ID 签的 App，**7 天后会失效**（打不开，提示需要重新验证）。

三个办法：

| 方案 | 说明 | 成本 |
|---|---|---|
| **重签** | 7 天后重新用 Sideloadly 装一次 | 免费，但要动手 |
| **AltStore** | 电脑装 AltServer，同一 WiFi 下自动续签 | 免费，需要电脑偶尔开机 |
| **付费开发者** | 一年有效期，不用反复签 | $99/年 |

**重签不会丢数据**——书架的数据库和下载的书都在 App 沙盒里，覆盖安装会保留。但**不要删除 App 再装**，那样数据就没了。

> 重要：先把重要的书导出备份，或者确认 NAS 上还有原件。

---

## 备选方案

### 方案 B：找一台 Mac（哪怕一小时）

同学、公司、网吧、二手 Mac mini……只要能开 Xcode 就行：

1. 打开工程，选自己的 Apple ID 做 Team
2. 连 iPhone，`⌘R`
3. 完事

比云端方案快，而且能直接调试。

### 方案 C：Windows 装 macOS 虚拟机

可行，但我不推荐：

- 要 15-20GB 下载（macOS 镜像 + VMware/VirtualBox）
- 需要 CPU 支持虚拟化，还得打补丁绕过苹果的硬件检查
- 装完 Xcode 又要 15GB
- 编译速度慢，可能卡死

除非你本来就想要个 macOS 环境，否则不值得。

### 方案 D：租云 Mac

- MacStadium、MacinCloud 之类，按小时或按月租
- 优点：真 Mac，体验完整
- 缺点：要花钱（约 $1/小时 起），而且远程操作 Xcode 有点卡

对于"只想装个 App 自己用"，GitHub Actions 的免费额度完全够。

---

## 常见问题

**Q：GitHub Actions 免费吗？**

公开仓库完全免费，不限时长。私有仓库每月 2000 分钟免费额度，macOS 机器按 10 倍计费（相当于 200 分钟），这个项目编译一次约 5-8 分钟，够用 25 次左右。

建议用 **Public** 仓库，反正代码也没什么见不得人的。

**Q：编译失败了怎么办？**

点开失败的步骤看日志。如果是 `xcodebuild: error: Scheme NovelReader is not configured`，说明 scheme 没提交上去——检查 `.xcodeproj/xcshareddata/xcschemes/` 目录在不在。

**Q：Sideloadly 报错 "Failed to obtain provisioning profile"**

通常是 Apple ID 或密码问题。检查：
- 是否开了双重验证 → 需要用 App 专用密码
- Bundle ID 是否和别人撞了 → 在工程里改成 `com.你的名字.novelreader` 再重新编译

**Q：装上了但闪退**

大概率是签名或架构问题。在 iPhone 上：设置 → 隐私与安全性 → 分析 → 分析数据，找 `NovelReader` 开头的崩溃日志，发我。

**Q：能装到 iPad 吗？**

可以，同一个 ipa。Sideloadly 会自动识别设备。

**Q：能不能不装 Sideloadly，直接网页安装？**

需要企业证书或者 TestFlight。TestFlight 要求 App Store Connect 账号（免费 Apple ID 也能用，但流程更长：要建 App 记录、上传构建、等审核）。个人自用的话 Sideloadly 最直接。

---

## 一句话总结

```bash
node tools/push-to-github.mjs   # 推送
# 去 GitHub Actions 点 Run workflow
# 下载 ipa，Sideloadly 签名，装到 iPhone
```

全程不需要 Mac，不需要付费账号。
