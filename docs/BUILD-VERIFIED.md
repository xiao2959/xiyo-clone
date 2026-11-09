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
