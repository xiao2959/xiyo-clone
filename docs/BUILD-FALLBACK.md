# Codemagic 备用构建（GitHub Actions 的 macOS runner 不可用时的替代）

> 现象：GitHub Actions 里 `macos-14` 直接报
> `The configuration 'macos-14-arm64-us-default' is not supported`，
> `macos-13 / macos-15 / macos-latest` 排队 4 分钟以上不启动。
> 判断：这个账号没有可用的 macOS runner。

---

## 方案：Codemagic（免费额度含 macOS）

Codemagic 对开源/个人项目提供 **每月 500 分钟免费 macOS 构建**，用它出未签名 IPA。

### 步骤

1. 打开 https://codemagic.io/signup
2. 选 **Sign up with GitHub**（用同一个账号，会直接授权仓库）
3. 授权后选仓库 `xiao2959/xiyo-clone`
4. 项目类型选 **Other** → 它会自动读仓库根目录的 `codemagic.yaml`
5. 点 **Start new build**
6. 约 15–25 分钟，产物在 **Artifacts** 里：`XiYOClone-unsigned.ipa`

### 仓库里已经放好的配置

`codemagic.yaml`（同目录下一级）会做这些事：

```
1. rustup target add aarch64-apple-ios
2. cargo build --release --target aarch64-apple-ios     # 编 Rust 静态库
3. brew install xcodegen && xcodegen generate          # 生成工程
4. xcodebuild ... CODE_SIGNING_ALLOWED=NO              # 编未签名 App
5. 打包 Payload/ -> ipa
6. 上传 artifact
```

---

## 备选：租一台云 Mac（最稳）

| 服务 | 价格 | 说明 |
|---|---|---|
| MacStadium | ~$1–2/小时 | 延迟高但稳定 |
| AWS EC2 mac2 | ~$0.65/小时 + 24h 最低 | 贵，需要配额申请 |
| 国内云 Mac 租赁 | ¥3–10/小时 | 更适合国内网络 |

连上去之后：

```bash
git clone git@github.com:xiao2959/xiyo-clone.git   # 或直接传 zip
cd xiyo-clone/Rust && ./build-ios.sh
brew install xcodegen && cd .. && xcodegen generate
xcodebuild -project XiYOClone.xcodeproj -scheme XiYOClone \
           -configuration Release -sdk iphoneos \
           CODE_SIGNING_ALLOWED=NO build
# 打包成 ipa 后拿去做全能签签名
```

---

## 备选：给 GitHub 账号加付款方式

GitHub 对部分新账号/地区限制 macOS runner。
在 https://github.com/settings/billing/payment_information 添加付款方式后，
macOS runner 通常立刻可用（公开仓库用量免费）。

**这是最省事的**，但涉及绑卡，你自己决定。

---

## 判断顺序

```
1. 先等 GitHub 的 probe 结果（macos-13 / macos-15 有没有起来）
   ↓ 起来了 → 把 ios.yml 的 runs-on 改成那个标签，直接跑
   ↓ 起不来
2. Codemagic（免费，但要注册授权）
   ↓ 不想注册
3. 绑卡解锁 GitHub macOS（最省事）
   ↓ 都不想
4. 租云 Mac（¥3–10/小时，最稳）
```
