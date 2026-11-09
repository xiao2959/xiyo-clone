//! idevice_ffi —— iOS 端 FFI 静态库入口
//!
//! 所有导出都在 `pairing` 模块（配对 + 注入），这里只声明模块。
//!
//! 导出清单（与 App/Bridge/include/idevice_ffi.h 一一对应）：
//!   配对：pairing_start / pairing_take_pin / pairing_wait / pairing_status
//!         pairing_service_type / pairing_identifier / pairing_txt
//!   注入：simulate_location / clear_location
//!
//! 依赖 idevice 0.1.68，API 已按 crates.io 源码核对（docs/API-VERIFIED.md）。

pub mod pairing;
