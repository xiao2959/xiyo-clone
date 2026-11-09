# 编译卡在 GitHub 的 macOS 产能上，两条路给你

> 代码早就写完了（含官方那种自动换算），**只差一个能跑 macOS 的机器把它编成 IPA**。
> GitHub 这边不是我们配置错了，是他们排队。

---

## 现在的实测状态

| 尝试 | 结果 | 说明 |
|---|---|---|
| `macos-14` | ❌ 2 秒失败 | `The configuration 'macos-14-arm64-us-default' is not supported` |
| `macos-15` / `macos-latest` | ⏳ 排队 | GitHub 原文：*"Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times."* |
| `macos-13` | ⏳ 排队中（已 8 分钟） | 有效标签，但 GitHub 的 macOS 11/12/13 已被标记弃用，可能长时间不分配 |

**结论**：不是权限问题，是**产能排队**。快的话十几分钟，慢的话几小时。

---

## 路线 A：Codemagic（最省事，2 分钟注册）

Codemagic 现在只支持邮箱注册（GitHub 登录入口已撤），流程很短：

```
1. 打开 https://codemagic.io/signup
2. 填邮箱 + 密码 → 点 Create your account
3. 去邮箱点验证链接（会立刻到）
4. 登录后：Add application → 选 GitHub → 授权 → 选 xiao2959/xiyo-clone
5. 选 "Other / codemagic.yaml" → Start new build
```

**仓库里我已经放好 `codemagic.yaml`**，它会自动：

```
① 装 Rust + iOS target
② cargo build --release --target aarch64-apple-ios
③ 打印导出的 9 个 C 符号
④ brew install xcodegen && xcodegen generate
⑤ xcodebuild（不签名）编 App
⑥ 打包成 XiYOClone-unsigned.ipa
⑦ 上传成 Artifacts
```

免费额度 **500 分钟/月**，一次构建约 20 分钟。

**你注册完告诉我，剩下的（配置、触发、盯进度、下载）我来做。**

---

## 路线 B：给 GitHub 绑付款方式（最彻底）

```
https://github.com/settings/billing/payment_information
```

绑卡后，公开仓库的 macOS runner 立刻可用（公开仓库用量本身免费，
绑卡只是为了解除"新账号 macOS 限制"）。

**这条一劳永逸**，以后改代码随时能重新编。

---

## 路线 C：什么都不做，等 GitHub 排队

我已经挂了后台监控（每 25 秒查一次），**一排到就自动开始编**，编完我第一时间告诉你。

风险：可能要等很久，而且 `macos-13` 是弃用标签，可能永远排不上。

---

## 编出来之后，这个 App 的行为是这样的

```
1. 打开 App → 连接隧道（系统弹"添加 VPN 配置"，允许）
2. 配对设备（显示 6 位码 → 输到手机设置里）
3. 在地图上点一下
4. 界面显示三行：
      地图上点的   36.7069000, 119.1618000
      注入用的     36.7064462, 119.1559046     ← 自动换算过的
      坐标偏移     528 米（已自动换算）
5. 点「注入到手机」→ 地图 App 跳到那个位置
```

**第 4 步那三行就是和 StikDebug 的本质区别**：你能看到它把坐标换算过了，所以不偏。

---

## 我已经验证过的部分

| 项 | 结果 |
|---|---|
| Swift 语法（9 文件，swiftc -parse） | ✅ 全通过 |
| 换算常量 vs 已验证实现 | ✅ 6/6 一致 |
| 换算精度 | ✅ 往返 0.0000 毫米 |
| 地图点选逻辑 | ✅ 代码完整（MapReader + proxy.convert） |
| Rust 静态库 | ✅ cargo build 通过，9 符号 |
| 真机编译 | ⏳ 就缺这台机器 |
