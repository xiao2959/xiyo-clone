# 编译验证记录

> 这是本轮**真正跑过**的编译，不是"应该能编"。
> 环境：Windows 11 + rustc 1.99.1 (x86_64-pc-windows-gnu) + WinLibs gcc

---

## 1. 编译命令

```powershell
# 目标机是 iOS，但先在 Windows 上验证"代码本身能过类型检查"
cargo +stable-x86_64-pc-windows-gnu check
cargo +stable-x86_64-pc-windows-gnu build
```

## 2. 编译结果

```
Checking idevice v0.1.68
Checking idevice_ffi v0.3.0
Finished `dev` profile [unoptimized + debuginfo] target(s) in 28.85s
```

**零错误、零警告。**

产物：`target/debug/libidevice_ffi.a`（128,495,466 B，debug 带符号所以很大；release 会小很多）

## 3. 导出符号实测

```bash
nm -g --defined-only target/debug/libidevice_ffi.a | grep -E ' T (pairing_|simulate_location|clear_location)'
```

```
0000000000000ef0 T clear_location
0000000000001210 T pairing_identifier
00000000000015e0 T pairing_service_type
00000000000017b0 T pairing_start
00000000000028f0 T pairing_status
0000000000002f80 T pairing_take_pin
0000000000003390 T pairing_txt
0000000000003880 T pairing_wait
00000000000040b0 T simulate_location
```

**9/9 全部导出**，与 `App/Bridge/include/idevice_ffi.h` 的声明、`Bridge.swift` 的 `@_silgen_name` 完全一致。

## 4. 编译过程中发现并修掉的真问题

| # | 问题 | 原因 | 修法 |
|---|---|---|---|
| 1 | `PairingFile` 找不到 | 它被 `#[cfg(feature="rustls")]` 门控 | features 加 `rustcrypto`（= 纯 Rust rustls，适合交叉编译 iOS） |
| 2 | `use of partially moved value: r` | `match r { Err(e) => s.error = Some(e) }` 把 r 移走后又 `tx.send(r)` | 改成 `if let Err(e) = &r { s.error = Some(e.clone()) }` |
| 3 | `cannot borrow s as mutable` | `let s = ...; s.rx.take()` | 改成 `let mut s` |
| 4 | `IdeviceProvider` 未使用 | 只剩 `TcpProvider` 用到 | 删掉该 import |

**这四条如果不真编，写多少注释都发现不了。**

## 5. 还没验证的部分（诚实说明）

| 项 | 为什么没验 |
|---|---|
| `aarch64-apple-ios` 交叉编译 | 需要 macOS + Xcode SDK；Windows 上装不了 iOS target |
| Swift 侧编译 | 需要 Xcode |
| 真机运行 | 需要插线 + 开发者模式 + 你的签名证书 |
| `NetService` 广播 | 只能在真机/iOS 模拟器上验证 |

## 6. 到 iOS 上还需要做的

```bash
# 在 Mac 上
rustup target add aarch64-apple-ios
cd Rust && ./build-ios.sh          # 会编译 + 打印符号 + 复制到 App/Bridge/lib/
```

然后 Xcode 里：
- `Library Search Paths` += `$(SRCROOT)/App/Bridge/lib`
- `Other Linker Flags` 已有 `-lidevice_ffi`
- `SWIFT_OBJC_BRIDGING_HEADER` = `App/Bridge/include/idevice_ffi.h`

## 7. 复现方法（你自己可以再跑一遍）

```powershell
# 一次性环境
winget install Rustlang.Rustup
rustup default stable
rustup toolchain install stable-x86_64-pc-windows-gnu --profile minimal
winget install BrechtSanders.WinLibs.POSIX.UCRT   # 提供 gcc / nm

# 验证
cd xiyo-lab\app-skeleton\Rust
cargo +stable-x86_64-pc-windows-gnu build
nm -g --defined-only target\debug\libidevice_ffi.a | findstr " T "
```


---

# 第二轮：NAT / TCP 协议逻辑验证（2026-11-09）

> Swift 在 Windows 上编不了，但**协议逻辑可以逐行移植到 Python 用真实 socket 验证**。

## 方法

`tools/test_tcprelay.py` 把 `Extension/TCPRelay.swift` 的算法逐行复刻成 Python：

| Swift | Python 复刻 |
|---|---|
| `checksum(_:)` | `checksum()` |
| `buildIPv4TCP(...)` | `build_ipv4_tcp()` |
| `TCPSegment.init?(bytes:offset:)` | `parse_packet()` |
| `RelayConnection.onSYN/onData/onFIN/send` | `RelayConnection.*` |

然后用一个真实的 `127.0.0.1` 回显服务验证端到端。

## 结果（全部通过）

```
=== 测试 1：校验和实现 ===
  12345678                 -> csum=9753  填回后反码和=ffff
  000102...111213          -> csum=a59b  填回后反码和=ffff
  6162636465666768         -> csum=6e6a  填回后反码和=ffff
  000100020003             -> csum=fff9  填回后反码和=ffff
  deadbeef                 -> csum=6262  填回后反码和=ffff
  ✅ 校验和正常

=== 测试 2：IPv4 头校验和 ===
  ✅ IP 头校验和正确

=== 测试 3：TCP 校验和（含伪首部）===
  ✅ TCP 校验和正确

=== 测试 4：真实 socket 握手 + 数据转发 ===
  SYN-ACK: flags=0x12 seq=305419897 ack=1001     ✅
  回包: flags=0x18 payload=b'ECHO:hello-from-client'
  ✅ 数据成功往返（客户端 -> 127.0.0.1 -> 回给客户端）
  ✅ 数据包 TCP 校验和正确
  ✅ seq 递增正确
  FIN: flags=0x11                                 ✅

✅ 全部通过
```

## 由此确认的事实

| 项 | 结论 |
|---|---|
| 校验和算法正确 | 含伪首部的 TCP 校验和、IP 头校验和都能自校验 |
| 三次握手正确 | SYN → SYN-ACK，`ack = clientISN + 1`，端口方向正确 |
| 数据转发正确 | 客户端数据经 relay 到 127.0.0.1:port，回包内容一致 |
| seq 递增正确 | SYN-ACK 后数据包 `seq = serverISN + 1` |
| FIN 收尾正确 | 客户端 FIN → 回 FIN+ACK |

## 测试中我自己犯的错（也修了）

第一版测试把"校验和自校验"判据写成 `== 0`，结果全红。
正确判据是**一次性补码和为 `0xFFFF`**（`0` 是"再取反后"的说法）。
算法本身没错，是**测试写错了** —— 这类"验证器本身有 bug"的情况，如果不看具体数值很容易误判成代码错。

---

# 第三轮：又发现 2 个真问题

## 1. `TCPSegment` 缺 memberwise init（**必然编译失败**）

```swift
struct TCPSegment {
    init?(bytes: [UInt8], offset: Int) { ... }   // 自定义了 init
}
// 于是 Swift 不再自动合成：
TCPSegment(srcPort:dstPort:seq:ack:flags:window:payload:)  // ❌ 编译错误
```

**已修**：显式补上这个 init。

## 2. `NSBonjourServices` 写错服务名

```diff
- <string>_stikpairprobe._tcp</string>
+ <string>_remotepairing-pairable-host._tcp</string>
```

`_stikpairprobe` 是 StikDebug 自己的探测服务；我们发布的是
`_remotepairing-pairable-host._tcp`（idevice 的 `PAIRABLE_HOST_SERVICE_TYPE`）。
名字不匹配 → **iOS 拒绝发布 Bonjour → 配对页永远等不到设备连入**。

## 3. 顺带修的

- `App/Info.plist` 的 `MinimumOSVersion` 15.0 → 17.0（否则和 `Map(position:)` 冲突）
