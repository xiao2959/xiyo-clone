# 下载 IPA 的完整步骤（含"现在还不能下载"的确认）

> 我刚查了你本机：**没有配置任何远程仓库**（`git remote -v` 为空）。
> 所以 **GitHub 上还没有这个项目，Actions 也没跑过，没有 artifact 可下载。**
>
> 必须先推上去、等构建完成，才有东西可下。下面是完整链路。

---

## 阶段 0：先推到 GitHub（还没做）

### 最省事的方式：双击脚本

```
C:\Users\Administrator\Documents\deepseek-harness\default-workspace\xiyo-lab\app-skeleton\推送.cmd
```

双击后：
1. 提示输入 **GitHub 用户名**
2. 提示输入 **仓库名**（直接回车 = `xiyo-clone`）
3. 自动推送，然后自动打开 Actions 页面

> 前提：先去 https://github.com/new 建一个**空**仓库（Private 也行，**别勾 README/.gitignore**）。

### 或者手动三条命令

```powershell
$env:Path += ";C:\Program Files\Git\cmd"
cd C:\Users\Administrator\Documents\deepseek-harness\default-workspace\xiyo-lab\app-skeleton
git remote add origin https://github.com/你的用户名/xiyo-clone.git
git push -u origin main
```

第一次推送会弹登录：
- 点 **Sign in with your browser** → 浏览器里点 Authorize（最简单）
- 或粘贴 **Personal Access Token**（GitHub → Settings → Developer settings → Personal access tokens (classic) → 勾 `repo`）

---

## 阶段 1：触发构建

推到 GitHub 后有两种情况：

| 情况 | 怎么办 |
|---|---|
| Actions 里**自动开始跑**（有黄色圆点） | 等就行 |
| Actions 里显示 "Workflows aren't being run on this repository" | 点 **I understand my workflows, go ahead and enable them** |
| 手动触发 | Actions → 左侧 **build-ios** → 右侧 **Run workflow** → 绿色按钮 |

---

## 阶段 2：等构建跑完

```
仓库页面 → Actions 标签 → 点最新那次运行（叫 build-ios 或 commit 信息）
```

你会看到 6 个步骤依次变绿：

```
✅ Set up job
✅ Install Rust
✅ Build libidevice_ffi.a        ← 编 Rust（已验证能过）
✅ Install XcodeGen
✅ Generate project
✅ Build (unsigned)              ← 最关键，Swift 编译在这
✅ Package IPA
✅ Upload artifact
```

**耗时**：第一次 15–25 分钟（Rust 依赖要下载编译），有缓存后 5–8 分钟。

---

## 阶段 3：下载 artifact（你问的"怎么下载"）

### 位置：**那次运行页面的最底部**

```
1. 点进那次运行（页面 URL 形如 github.com/用户/仓库/actions/runs/1234567890）
2. 页面拉到最底部
3. 看到一个区块叫  Artifacts
4. 里面有一行：XiYOClone-unsigned-ipa
5. 点它 → 浏览器直接下载 XiYOClone-unsigned-ipa.zip
```

**注意三点**：

| 事 | 说明 |
|---|---|
| 必须是**成功**的运行（绿色 ✅） | 失败的运行没有 Artifacts 区块 |
| 下载的是 **zip**，不是 ipa | 解压后里面才是 `XiYOClone-unsigned.ipa` |
| 有效期 **90 天** | 过期要在 Actions 里重新跑一次 |

### 解压后你会得到

```
XiYOClone-unsigned.zip
└── XiYOClone-unsigned.ipa     ← 这个才是给全能签的
```

---

## 阶段 4：用全能签签名

```
1. 全能签 → 上传 IPA（选 XiYOClone-unsigned.ipa）
2. 填 UDID：00008110-001658DC0C83801E
3. 选证书：iPhone Distribution: Anna Beer (BT8T5D9JD8)
4. 开始签名 → 拿到安装链接
5. 手机上打开链接 → 安装
```

**签名时要注意**：这个 App 里有一个扩展（`LocalVPNExtension.appex`）。
全能签必须**把扩展一起签**（大多数签名工具会自动处理嵌套的 .appex）。
如果装完打开 App 点"连接隧道"没反应，多半就是扩展的 entitlement 没保住 —— 那时跑一下 App 里的「自检」，第 3 项会红叉。

---

## 阶段 5：装好后第一次运行

```
1. 打开 App「定位隧道」
2. 点「连接隧道」→ 系统弹「想要添加 VPN 配置」→ 允许
3. 状态栏出现 VPN 图标
4. 点「自检」→ 等 8 项跑完 → 截图发我
5. 点「配对设备」→ 记下 6 位数字
6. 手机设置里完成配对
7. 地图选点 → 「注入到手机」
```

**第 4 步的自检截图最重要** —— 有它我就能定位任何问题。

---

## 如果 Actions 报错（这时还没有 artifact）

把报错页面**截图**或复制这段：

```
页面左侧那一步的名字（比如 Build (unsigned)）
+ 红色日志最后 30 行
```

贴给我，我逐条改。

---

## 如果你不想用 GitHub

两个替代：

1. **把 zip 发给有 Mac 的人**
   [xiyo-app-skeleton.zip](xiyo-lab/xiyo-app-skeleton.zip)（61.8 KB）
   对方跑：`cd Rust && ./build-ios.sh` → `brew install xcodegen` → `xcodegen generate` → Xcode 里 Run

2. **租云 Mac**（约 ¥2–5/小时）
   MacStadium / AWS EC2 mac，连上去按上面同样步骤做
