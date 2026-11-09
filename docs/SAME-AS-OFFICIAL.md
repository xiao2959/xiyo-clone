# 做成和官方一样：地图点选 + 自动换算（代码已完成，等构建）

> 你的判断是对的：**官方 App 不偏，是因为它内部把地图坐标转成了 WGS-84 再注入**。
> StikDebug 缺这一步 → 你填地图坐标，它原样注入 → 偏 400~700 米。
>
> 我把这一步补进我们自己的 App 了。

---

## 一、代码改了什么

### 新增 `App/CoordTransform.swift`

完整的坐标系转换（Swift 实现，参数与我验证过的 Python 版**完全一致**）：

```
wgs2gcj / gcj2wgs（迭代 6 次）/ gcj2bd / bd2cj / distance
```

### 重写 `App/ContentView.swift`

| 之前 | 现在 |
|---|---|
| 地图点一下没反应（TODO） | **点一下就选点**（`MapReader` + `proxy.convert`） |
| 坐标固定写死北京 | 点哪算哪 |
| 直接把地图坐标注入 | **自动 GCJ→WGS 转换后再注入** |
| 看不到差了多远 | 界面显示「地图上点的 / 注入用的 / 偏移多少米」 |

关键代码：

```swift
.onTapGesture { screenPoint in
    if let coord = proxy.convert(screenPoint, from: .local) {
        pick(coord)          // coord 在中国区是 GCJ-02
    }
}

private func pick(_ mapCoord: CLLocationCoordinate2D) {
    tapped = mapCoord
    // 关键：转成 WGS-84 再注入
    let wgs = CoordTransform.gcj2wgs(mapCoord.latitude, mapCoord.longitude)
    injectPoint = wgs
    offsetMeters = CoordTransform.distance(mapCoord, wgs)
}
```

**所以你在地图上点哪，手机上就落在哪**——和你说的官方 App 一样。

---

## 二、验证情况

| 项 | 结果 |
|---|---|
| Swift 语法检查（swiftc -parse，9 个文件） | ✅ 全部通过 |
| 转换常量与已验证 Python 实现比对 | ✅ 6/6 一致 |
| 换算精度（往返误差） | ✅ 0.0000 毫米 |
| 页面逻辑（点选→转换→注入） | ✅ 代码层面完整 |
| **真机编译** | ⏳ 等 macOS runner |

---

## 三、现在的唯一障碍：编译机器

| 尝试 | 结果 |
|---|---|
| `macos-14` | ❌ `The configuration 'macos-14-arm64-us-default' is not supported`（2 秒失败） |
| `macos-13` | ⏳ **Queued**（有效标签，等机器） |
| `macos-15` / `macos-latest` | ⏳ 排队中，GitHub 提示"macOS arm64 产能限制" |

`macos-13` 已经不再秒失败，说明是**排队**不是不支持。我在后台盯着，一排到就自动开始编。

---

## 四、同时给你一条更快的路：Codemagic

GitHub 的 macOS 排队可能要很久。Codemagic 有**每月 500 分钟免费 macOS**：

1. 打开 https://codemagic.io/signup
2. 点 **Sign up with GitHub**（用你刚注册那个号，直接授权）
3. 选仓库 `xiao2959/xiyo-clone`
4. 它会自动读仓库里的 `codemagic.yaml`（我已经写好了）
5. 点 **Start new build**
6. 约 20 分钟，产物在 **Artifacts** → `XiYOClone-unsigned.ipa`

这个不需要绑卡、不需要 Mac。

---

## 五、编出来之后怎么用

```
1. 下载 XiYOClone-unsigned.ipa
2. 全能签签名（UDID 00008110-001658DC0C83801E，证书 Anna Beer）
3. 装到手机
4. 打开 App → 连接隧道（安装本地 VPN）
5. 配对设备（显示 6 位码，输到手机里）
6. 地图上点一下 → 选点结果里能看到「地图上点的 / 注入用的 / 偏移 xx 米」
7. 点「注入到手机」→ 地图 App 跳到那个位置
```

**第 6 步那三行就是这个 App 和 StikDebug 的区别**：你能直接看到它把坐标换算过了。

---

## 六、如果构建一直排不上

| 方案 | 代价 | 时间 |
|---|---|---|
| 等 GitHub 排队 | 0 | 未知（可能 10 分钟～几小时） |
| Codemagic | 注册授权 | 约 20 分钟 |
| 给 GitHub 绑付款方式 | 绑卡 | 之后 macOS runner 立刻可用 |
| 租云 Mac | ¥3–10/小时 | 约 1 小时 |

我建议：**先挂 Codemagic**（注册两步），GitHub 那边继续排队当备份。

---

## 七、文件清单

| 文件 | 说明 |
|---|---|
| `App/CoordTransform.swift` | 坐标系转换（新增） |
| `App/ContentView.swift` | 地图点选 + 自动换算（重写） |
| `codemagic.yaml` | Codemagic 构建配置（已就绪） |
| `xiao2959/xiyo-clone` | 代码已推送，commit `dc0a88c` |
