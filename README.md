# 书虫 · NovelReader

一个**本地优先**的 iOS 小说阅读器。支持本地 TXT/EPUB、NAS 书库（OPDS/WebDAV/HTTP 目录）、规则化在线书源，全部内容都能下载到设备离线阅读。个人自用、自签安装。

---

## 一、功能

### 阅读
- **分页引擎**：Core Text 逐行排版，按实际可用区域精确切页，不会裁字或页底留空
- **字号 / 行距 / 段距 / 页边距**实时调节，调完立刻重排并停在原来的位置
- **6 套主题**：羊皮纸、纯白、棕褐、护眼绿、夜间、纯黑（OLED）
- **翻页**：点击左右三分区、左右滑动；支持无动画
- **进度保存**：精确到字符偏移，换字号/转屏都不丢位置
- **目录**：搜索、正序/倒序、一键跳到当前章

### 本地资源
- 支持 **TXT**（UTF-8 / GBK / GB18030 / Big5 / UTF-16 自动探测）
- 支持 **EPUB**（解析 OPF、spine、nav 目录，内嵌章节标题）
- 支持 **HTML/HTM**
- 三种导入方式：
  1. 「文件」App → 长按 → 共享 → 书虫
  2. 书架 → `+` → 从「文件」导入
  3. 把文件拖进 `文件 App → 我的 iPhone → 书虫 → Inbox`，回到书架自动扫描

### NAS 资源库
| 类型 | 适用 | 地址示例 |
|---|---|---|
| OPDS | calibre-web、COPS、Komga、Kavita | `http://NAS:8083/opds` |
| HTTP 目录 | nginx autoindex、Apache、群晖 | `http://NAS/books/` |
| WebDAV | 群晖 / 威联通 | `http://NAS:5005/books` |

- 支持 HTTP Basic 认证（用户名 + 密码）
- 浏览目录 → 点一本书 → 自动下载整本并解析入库，之后完全离线
- 兼容 OPDS-PSE 分页漫画式条目

### 在线书源（可选）
- **规则书源**：自定义搜索页 / 详情页 / 正文的 CSS 选择器，支持简化 XPath
- **JSON API 书源**：接口返回 JSON 时用字段路径映射
- 支持编码指定（老站 GBK 常见）
- 书源配置可导出/导入 JSON，换机直接搬

### 离线下载
- 整本下载、按章节增量下载、阅读时自动预取后续 3 章
- 单章失败不中断整本
- 下载限速，不会把站打死
- 存储页按书统计缓存大小，可单本清理

---

## 二、编译与安装（自签）

> 需要一台 Mac（黑苹果/虚拟机也行）+ Xcode 15 或更高。

### 1. 打开工程

```bash
cd NovelReader
open NovelReader.xcodeproj
```

### 2. 配置签名（关键）

1. Xcode → 左侧点 `NovelReader` 项目 → TARGETS `NovelReader` → **Signing & Capabilities**
2. 勾选 **Automatically manage signing**
3. **Team** 选你的 Apple ID（没有就 `Add an Account` 用普通 Apple ID 登录，免费）
4. **Bundle Identifier** 改成唯一值，比如 `com.你的名字.novelreader`
   - 免费账号的 Bundle ID 不能和别人重复，撞了会报错

### 3. 真机运行

1. iPhone 用数据线连 Mac，手机上点「信任此电脑」
2. Xcode 顶部设备选你的 iPhone → `⌘R`
3. 首次运行后，手机上：**设置 → 通用 → VPN与设备管理 → 开发者APP → 信任**
4. 打开 App

> **免费账号限制**：证书 7 天过期。到期后重新 `⌘R` 一次即可，书架数据不会丢（数据存在 App 沙盒里，重装覆盖安装才保留；如果删除 App 重装会清空，重要书建议先导出）。

### 4. 打包成 ipa（用 AltStore / Sideloadly 安装）

```bash
# 归档
xcodebuild -project NovelReader.xcodeproj \
           -scheme NovelReader \
           -configuration Release \
           -destination 'generic/platform=iOS' \
           -archivePath build/NovelReader.xcarchive \
           archive

# 导出 ipa（需要 ExportOptions.plist，method 用 development 或 ad-hoc）
xcodebuild -exportArchive \
           -archivePath build/NovelReader.xcarchive \
           -exportPath build/ipa \
           -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` 示例（免费账号用 `development`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>你的TeamID</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
```

导出的 `.ipa` 拖进 AltStore / Sideloadly 即可。AltStore 配合 AltServer 可以自动 7 天续签，长期用最省事。

### 5. 模拟器快速验证

```bash
xcodebuild -project NovelReader.xcodeproj -scheme NovelReader \
           -destination 'platform=iOS Simulator,name=iPhone 15' build
```

---

## 三、NAS 配置示例

### calibre-web（最推荐）

1. calibre-web 网页 → 右上角头像 → **管理权限** → 勾选 `允许 OPDS 匿名浏览`（或给账号开 OPDS 权限）
2. App → 书源 → 新增 → OPDS 书库
3. 地址填 `http://你的NAS IP:8083/opds`
4. 有账号密码就填上，没有留空
5. 保存后去「发现」页浏览

### 群晖 WebDAV

1. 套件中心安装 **WebDAV Server**
2. 开启 HTTP（默认 5005）或 HTTPS（5006）
3. 把书放在 `共享文件夹/books`
4. App → 新增 → WebDAV → 地址 `http://NAS:5005/books`，填群晖账号密码

### nginx 目录

```nginx
location /books/ {
    alias /volume1/books/;
    autoindex on;
    autoindex_exact_size off;
    charset utf-8;
}
```

App 里填 `http://NAS/books/`。

### Komga

`http://NAS:25600/opds/v1.2/catalog`

### Kavita

`http://NAS:5000/api/opds`，需要在 Kavita 设置里生成 API Key，填到密码栏。

---

## 四、规则书源写法

以某个小说站为例，先在浏览器里用开发者工具看清结构，然后：

| 字段 | 说明 | 示例 |
|---|---|---|
| 搜索地址模板 | `{keyword}` `{page}` 占位 | `https://site.com/search?q={keyword}&page={page}` |
| 列表项选择器 | 每条结果的容器 | `div.result-item` |
| 标题 | 容器内取标题 | `h3 a` |
| 链接 | 取 href | `h3 a@href` |
| 作者 | | `span.author` |
| 章节链接 | 详情页目录 | `#list dd a` |
| 正文容器 | 章节页正文 | `#content` |
| 要去掉的元素 | 逗号分隔 | `div.ads,script,.recommend` |

选择器语法：
- CSS：`div#content`、`div.content p`、`a@href`（`@` 后缀取属性）
- 简化 XPath：`//div[@id='list']//a`、`//*[@class='content']`

> 站点结构改版后规则会失效，改选择器即可，不用改代码。

---

## 五、工程结构

```
NovelReader/
├── NovelReader.xcodeproj/
├── NovelReader/
│   ├── App/
│   │   ├── NovelReaderApp.swift      # 入口、SwiftData 容器
│   │   └── AppState.swift            # 全局状态、主题、排版参数持久化
│   ├── Models/
│   │   ├── Models.swift              # Book / Chapter / 存储目录常量
│   │   └── BookSourceModels.swift    # 书源配置、条目、候选书
│   ├── Parsers/
│   │   ├── TextSanitizer.swift       # 编码探测、广告清洗、章节标题识别
│   │   ├── ChapterSplitter.swift     # 分章、硬切、文件名解析
│   │   ├── TXTParser.swift           # TXT 解析
│   │   ├── EPUBParser.swift          # 内置 ZIP 读取 + EPUB 解析
│   │   └── HTMLParser.swift          # HTML→文本、实体解码
│   ├── Sources/
│   │   ├── LocalFileSource.swift     # 本地文件扫描/导入
│   │   ├── OPDSSource.swift          # OPDS / HTTP目录 / WebDAV
│   │   ├── WebBookSource.swift       # 规则书源搜索/详情/正文
│   │   ├── SourceRuleEngine.swift    # CSS/XPath 引擎 + 轻量 DOM
│   │   └── SourceRegistry.swift      # 书源持久化、导入导出
│   ├── Services/
│   │   ├── HTTPClient.swift          # 网络封装、编码、Basic Auth
│   │   ├── ImportService.swift       # 各种导入链路
│   │   ├── DownloadManager.swift     # 离线下载队列
│   │   └── Store.swift               # SwiftData 读写、章节缓存
│   ├── Views/
│   │   ├── Library/                  # 书架、详情、目录
│   │   ├── Reader/                   # 阅读器、分页引擎、排版设置
│   │   ├── Discover/                 # 书源浏览与搜索
│   │   └── Settings/                 # 书源管理、存储、关于
│   ├── Resources/Assets.xcassets/
│   └── Info.plist
└── tools/
    ├── verify-core.mjs               # 核心算法验证（63 项）
    ├── lint-swift.mjs                # Swift 静态检查
    └── fixtures/                     # 测试用 txt / epub
```

### 技术选型说明

- **零第三方依赖**：不引入 SPM 包，避免自签工程依赖解析失败
- **EPUB 的 ZIP 解压**用系统 `zlib` 的 raw inflate 自己实现，不依赖 ZIPFoundation
- **持久化**用 SwiftData（iOS 17+），章节正文写文件而不是塞数据库，避免大文本拖慢
- **分页**用 Core Text 而不是 UITextView，字符范围可精确映射，重排不丢位置

---

## 六、验证

在没有 Xcode 的机器上也能跑核心逻辑验证：

```bash
node tools/verify-core.mjs    # 63 项：分章、编码、HTML、EPUB、OPDS
node tools/lint-swift.mjs     # Swift 静态检查
```

`verify-core.mjs` 会同时生成 `tools/fixtures/` 下的测试文件，可以直接拖进 App 里手工验证。

---

## 七、已知限制

- **MOBI / AZW3 / PDF** 不支持解析，但可以从 NAS 下载到本地文件（暂不解析）
- **DRM 电子书**（Kindle、Apple Books 购买的书）无法解析
- 规则书源依赖目标站结构，改版需手动更新选择器
- 免费证书 7 天过期，需重新签名
- 竖排（直排）暂未实现

---

## 八、隐私

- 所有书源、账号密码、阅读记录只存在设备本地沙盒
- 无统计、无广告、无上报
- 网络请求只发生在：你配置的书源、你点击下载的文件
