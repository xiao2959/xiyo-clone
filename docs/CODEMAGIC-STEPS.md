# Codemagic 三步点完就开编（你在自己浏览器里操作）

> 我在你机器上看到你的 Edge 已经打开 Codemagic 的 **Application settings** 页面，
> 说明账号已登录、应用可能已添加。下面把剩下几步说清楚。

---

## 第 1 步：确认应用已连到仓库

看页面顶部/左侧，应用名下面应该显示：

```
xiao2959/xiyo-clone        ← 正确
```

如果是别的仓库或空白，回到 **Applications → Add application**：

```
1. 选 GitHub
2. 点 Install GitHub App / Authorize
3. 在授权页选 Only select repositories → 勾 xiao2959/xiyo-clone
4. 点 Install & Authorize
5. 回到 Codemagic，选中这个仓库
```

**关键**：授权时必须**选中这个仓库**，只勾 All repositories 也行，但必须包含它。

---

## 第 2 步：把构建配置切成 `codemagic.yaml`

这一步最容易漏 —— 不切的话它会开一个空白的 Workflow Editor，然后构建失败。

在 **Application settings** 页面里找：

```
Build configuration（构建配置）
  ○ Workflow Editor
  ● codemagic.yaml        ← 选这个
```

选完可能有个下拉让你选 workflow 名，选：

```
ios-unsigned
```

然后点 **Save** / **Finish**。

> 仓库根目录已经有我写好的 `codemagic.yaml`，它会做：
> Rust 交叉编译 → 生成 Xcode 工程 → xcodebuild 编未签名 App → 打包 IPA

---

## 第 3 步：开始构建

回到应用首页，点：

```
Start new build  （或 Start your first build）
→ 选分支 main
→ 点 Start new build
```

然后会进入构建页，你能看到步骤依次执行：

```
✅ Set up build machine
✅ Install Rust + iOS target
✅ Build Rust static lib        ← 会打印 9 个符号
✅ Install XcodeGen and generate project
✅ Build unsigned app           ← 最关键
✅ Package IPA
✅ Upload artifact
```

**约 20 分钟**（第一次要装 Rust 依赖）。

---

## 构建完成后：下载 IPA

构建页底部有 **Artifacts** 区块：

```
Artifacts
└── XiYOClone-unsigned.ipa      ← 点它下载
```

下载后拿去做全能签签名（UDID `00008110-001658DC0C83801E`，证书 Anna Beer）。

---

## 如果构建失败，把这几行发我

在失败的步骤上点开日志，复制：

```
❌ 红叉那一步的名字
+ 日志里最后 20~30 行
```

常见错误和对应处理：

| 报错 | 原因 | 处理 |
|---|---|---|
| `No configuration file found` | 第 2 步没切到 codemagic.yaml | 回第 2 步 |
| `xcodegen: command not found` | brew 没装成功 | 我改 yaml 用 `brew install xcodegen` |
| `Swift Compiler Error ... .swift:行号` | Swift 代码有类型错 | 发我行号，我改 |
| `Undefined symbols: _pairing_start` | 静态库没链上 | 我改 LIBRARY_SEARCH_PATHS |
| `The provisioning profile...` | 触发签名了 | 我加 CODE_SIGNING_ALLOWED=NO（已加，若仍报说明 xcodebuild 参数位置不对） |
| `command not found: cargo` | Rust 没装 | 改 yaml 的 rustup 安装段 |

---

## 我这边同时在做什么

GitHub Actions 那边 `#7`（macos-13）还在排队，我没取消 —— 两条路谁先通都行。

---

## 为什么要你点，而不是我全自动

Codemagic 的登录态在你**自己的浏览器窗口**里（那个窗口没有开远程调试端口），
我这边够不到它的会话。

如果你想让我全自动，可以这样做（任选）：

1. **把你的 Codemagic 邮箱和密码发我**，我在我控制的那个代理窗口里登录，全程我来
2. 或者你点完第 1~3 步就行 —— 后面下载 IPA、签名、安装都不需要 Codemagic 了
