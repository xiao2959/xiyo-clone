//! 纯手机端配对（rppairing responder）+ 定位注入。
//!
//! 全部 API 均已对照 `idevice 0.1.68` 源码核实：
//!   `remote_pairing::responder::PairableHost::accept(pairing_file, pin_callback)`
//!   `remote_pairing::responder::PairableHostInfo::generate(name, model)`
//!   `remote_pairing::rp_pairing_file::RpPairingFile::{generate, write_to_file}`
//!   `remote_pairing::socket::RpPairingSocket::new_device(socket)`
//!   `services::simulate_location::LocationSimulationService::{connect, set, clear}`
//!
//! 流程：
//!   1. `pair_start()`：在 127.0.0.1 开 TCP listener，返回端口
//!   2. Swift 用 Bonjour 把这个端口发布成 `_stikpairprobe._tcp`（见 README）
//!   3. 设备连入 → `PairableHost::accept` 跑握手 + SRP pair-setup
//!   4. `pin_callback` 收到 6 位码 → 存进共享状态，Swift 轮询显示
//!   5. 配对成功 → pairing file 落盘到 App Group
//!   6. 之后 `simulate()` / `clear()` 走 TcpProvider + LocationSimulationService

use std::ffi::{c_char, CStr};
use std::net::IpAddr;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use idevice::services::simulate_location::LocationSimulationService;
use idevice::IdeviceService;

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

struct State {
    port: u16,
    pin: Option<String>,
    paired: bool,
    peer_udid: Option<String>,
    error: Option<String>,
    tx: Option<Sender<Result<(), String>>>,
    rx: Option<Receiver<Result<(), String>>>,
    log_path: String,
    identifier: String,           // mDNS 服务实例名（= RpPairingFile::identifier）
    txt: Vec<(String, String)>,   // mDNS TXT 记录
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| {
        Mutex::new(State {
            port: 0,
            pin: None,
            paired: false,
            peer_udid: None,
            error: None,
            tx: None,
            rx: None,
            log_path: String::new(),
            identifier: String::new(),
            txt: Vec::new(),
        })
    })
}

// ---------------------------------------------------------------------------
// alt_irk 持久化
//   源码注释要求：alt_irk 必须在多次运行间保持不变，否则已配对设备认不出本机。
//   这里存成 `<pairing.plist 路径>.altirk`（32 个 hex 字符）。
// ---------------------------------------------------------------------------
fn altirk_path(save_path: &str) -> String {
    format!("{save_path}.altirk")
}

fn load_altirk(save_path: &str) -> Option<[u8; 16]> {
    let text = std::fs::read_to_string(altirk_path(save_path)).ok()?;
    let text = text.trim();
    if text.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for i in 0..16 {
        out[i] = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

fn save_altirk(save_path: &str, irk: &[u8; 16]) {
    let hex: String = irk.iter().map(|b| format!("{b:02x}")).collect();
    let _ = std::fs::write(altirk_path(save_path), hex);
}

// ---------------------------------------------------------------------------
// 落盘日志：写到 <pairing.plist>.log，配合 App 的 File Sharing 可直接导出
// ---------------------------------------------------------------------------
fn plog(msg: &str) {
    let path = {
        let s = state().lock().unwrap();
        s.log_path.clone()
    };
    let line = format!("{} {}\n", now_str(), msg);
    if path.is_empty() {
        eprintln!("[pairing] {msg}");
        return;
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

fn now_str() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("[{}.{:03}]", now.as_secs(), now.subsec_millis())
}

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p).to_string_lossy().into_owned() }
}

fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// 把 panic 拦在 FFI 边界内 —— 否则整个 App 会被系统杀掉（用户只看到闪退）。
///
/// `panic = "unwind"`（Cargo.toml）+ catch_unwind 才能生效。
fn guard<T, F: FnOnce() -> T>(fallback: T, f: F) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(e) => {
            let msg = if let Some(s) = e.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = e.downcast_ref::<String>() {
                s.clone()
            } else {
                "unknown panic".to_string()
            };
            plog(&format!("PANIC 被拦截: {msg}"));
            eprintln!("[pairing] PANIC: {msg}");
            fallback
        }
    }
}

// ---------------------------------------------------------------------------
// 1) 启动配对：开 listener，后台等设备连入
//    返回监听端口（>0）或 -1
// ---------------------------------------------------------------------------
fn pairing_start_inner(name: *const c_char, save_path: *const c_char) -> i32 {
    let host_name = cstr(name);
    let save = cstr(save_path);
    if host_name.is_empty() || save.is_empty() {
        return -1;
    }

    // 建 listener（同步拿端口，再异步 accept）
    // 关键：必须绑 0.0.0.0。设备通过 Bonjour 解析到的是局域网 IP（192.168.x.x），
    // 绑 127.0.0.1 会收不到任何连接（这就是"配对没反应"的原因）。
    let listener = match std::net::TcpListener::bind("0.0.0.0:0") {
        Ok(l) => l,
        Err(_) => return -1,
    };
    let port = match listener.local_addr() {
        Ok(a) => a.port(),
        Err(_) => return -1,
    };
    if listener.set_nonblocking(true).is_err() {
        return -1;
    }

    // 先建 pairing_file / host_info：identifier 与 TXT 记录要给 Swift 发 Bonjour 用
    let mut pairing_file = RpPairingFile::generate(host_name.as_str());
    // iOS 把本机当"电脑"，model 必须是 Mac 标识（源码注释要求）
    let mut host_info = PairableHostInfo::generate(host_name.as_str(), "Mac17,7");
    // alt_irk 复用上次的（跨重启保持一致），首次则落盘
    match load_altirk(&save) {
        Some(irk) => host_info.alt_irk = irk,
        None => save_altirk(&save, &host_info.alt_irk),
    }
    let identifier = pairing_file.identifier().to_string();
    let txt = host_info.mdns_txt_records(&identifier);

    let (tx, rx) = mpsc::channel::<Result<(), String>>();
    {
        let mut s = state().lock().unwrap();
        s.port = port;
        s.pin = None;
        s.paired = false;
        s.error = None;
        s.tx = Some(tx);
        s.rx = Some(rx);
        s.identifier = identifier;
        s.txt = txt;
        s.log_path = format!("{save}.log");
    }

    plog(&format!("pairing_start name={host_name} port={port} save={save}"));

    // 后台跑：tokio 接管这个 listener
    rt().spawn(async move {
        let listener = match tokio::net::TcpListener::from_std(listener) {
            Ok(l) => l,
            Err(e) => {
                finish(Err(format!("listener: {e}")));
                return;
            }
        };

        plog("listener ready, waiting for device");

        // 等设备连入（60 秒超时）
        // 5 分钟：用户要切到设置 -> 点配对 -> 输 6 位码 -> 输锁屏密码，60 秒根本不够
        let accept = tokio::time::timeout(Duration::from_secs(300), listener.accept()).await;
        let stream = match accept {
            Ok(Ok((s, _addr))) => s,
            Ok(Err(e)) => {
                finish(Err(format!("accept: {e}")));
                return;
            }
            Err(_) => {
                finish(Err("等待设备连接超时（300s）".into()));
                return;
            }
        };

        plog("device connected");

        // 设备发起的配对：responder 角色（pairing_file / host_info 已在 pairing_start 里建好）
        let sock = RpPairingSocket::new_device(stream);
        let mut host = PairableHost::new(sock, host_info);

        // pin_callback：把 6 位码写进共享状态，Swift 轮询取
        let pin_cb = {
            move |pin: String| {
                plog(&format!("pin generated: {}", pin));
                {
                    let mut s = state().lock().unwrap();
                    s.pin = Some(pin);
                } // 作用域结束，Guard 先释放，再返回 future
                std::future::ready(())
            }
        };

        plog("accept() start: handshake + SRP pair-setup");
        let result = host.accept(&mut pairing_file, pin_cb).await;
        match &result {
            Ok(_) => plog("accept() returned Ok"),
            Err(e) => plog(&format!("accept() returned Err: {e}")),
        }
        match result {
            Ok(peer) => {
                // 落盘 pairing file（App Group 容器里的路径由 Swift 传入）
                plog("writing pairing file...");
                let saved = pairing_file.write_to_file(&save).await;
                match saved {
                    Ok(()) => {
                        plog("pairing file saved OK");
                        let mut s = state().lock().unwrap();
                        s.paired = true;
                        s.peer_udid = Some(peer.remotepairing_udid.clone());
                        drop(s);
                        finish(Ok(()));
                    }
                    Err(e) => finish(Err(format!("写 pairing file 失败: {e}"))),
                }
            }
            Err(e) => finish(Err(format!("配对失败: {e}"))),
        }
    });

    port as i32
}

fn finish(r: Result<(), String>) {
    match &r {
        Ok(()) => plog("finish: OK"),
        Err(e) => plog(&format!("finish: ERR {e}")),
    }
    let mut s = state().lock().unwrap();
    if let Err(e) = &r {
        s.error = Some(e.clone());
    }
    if let Some(tx) = s.tx.take() {
        let _ = tx.send(r);
    }
}

/// 对外入口（带 panic 拦截）
#[no_mangle]
pub extern "C" fn pairing_start(name: *const c_char, save_path: *const c_char) -> i32 {
    guard(-1, || pairing_start_inner(name, save_path))
}

// ---------------------------------------------------------------------------
// 2) 取 6 位码（Swift 轮询）
//    返回值：>0 = 长度（已写入 buf）；0 = 还没有；-1 = 出错
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn pairing_take_pin(buf: *mut c_char, cap: i32) -> i32 {
    if buf.is_null() || cap <= 1 {
        return -1;
    }
    let mut s = state().lock().unwrap();
    let Some(pin) = s.pin.take() else {
        return 0;
    };
    let bytes = pin.as_bytes();
    let n = bytes.len().min((cap as usize) - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

// ---------------------------------------------------------------------------
// 3) 等配对结果（阻塞 timeout_ms）
//    0 = 成功；-1 = 超时/还没结束；-2 = 失败；-3 = 没有进行中的配对
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn pairing_wait(timeout_ms: i32) -> i32 {
    guard(-2, || pairing_wait_inner(timeout_ms))
}

fn pairing_wait_inner(timeout_ms: i32) -> i32 {
    let rx = {
        let mut s = state().lock().unwrap();
        s.rx.take()
    };
    let Some(rx) = rx else {
        // 没有进行中的配对：看是不是已经成功过
        let s = state().lock().unwrap();
        if s.paired {
            return 0;
        }
        if s.error.is_some() {
            return -2;
        }
        return -3;
    };

    let to = Duration::from_millis(u64::try_from(timeout_ms).unwrap_or(0));
    let res = rx.recv_timeout(to);
    let out = match res {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -2,
        Err(_) => {
            // 超时：把 rx 放回去，下次还能等
            let mut s = state().lock().unwrap();
            s.rx = Some(rx);
            -1
        }
    };
    out
}

// ---------------------------------------------------------------------------
// 3.5) Bonjour 需要的东西：服务类型 + 实例名 + TXT 记录
//       Swift 用 NetService(domain:type:name:port:) 发布
// ---------------------------------------------------------------------------

/// 服务类型常量（= idevice 的 PAIRABLE_HOST_SERVICE_TYPE，去掉 .local. 后缀给 NetService 用）
#[no_mangle]
pub extern "C" fn pairing_service_type(buf: *mut c_char, cap: i32) -> i32 {
    // NetService 需要 "服务名.协议." 形式，不带 .local.
    let t = "_remotepairing-pairable-host._tcp.";
    if buf.is_null() || cap <= 1 { return -1; }
    let b = t.as_bytes();
    let n = b.len().min((cap as usize) - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(b.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

/// mDNS 服务实例名（= RpPairingFile::identifier）
#[no_mangle]
pub extern "C" fn pairing_identifier(buf: *mut c_char, cap: i32) -> i32 {
    let id = { state().lock().unwrap().identifier.clone() };
    if buf.is_null() || cap <= 1 { return -1; }
    let b = id.as_bytes();
    let n = b.len().min((cap as usize) - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(b.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

/// TXT 记录，每行 `key=value`（Swift 解析成 [String: Data] 给 NetService.setTXTRecord）
#[no_mangle]
pub extern "C" fn pairing_txt(buf: *mut c_char, cap: i32) -> i32 {
    let lines = {
        let s = state().lock().unwrap();
        s.txt.iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("\n")
    };
    if buf.is_null() || cap <= 1 { return -1; }
    let b = lines.as_bytes();
    let n = b.len().min((cap as usize) - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(b.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

// ---------------------------------------------------------------------------
// 4) 配对是否完成 + 设备 UDID
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn pairing_status(buf: *mut c_char, cap: i32) -> i32 {
    let s = state().lock().unwrap();
    let text = if let Some(e) = &s.error {
        format!("error:{e}")
    } else if s.paired {
        format!("paired:{}", s.peer_udid.clone().unwrap_or_default())
    } else if s.pin.is_some() {
        "waiting_pin".to_string()
    } else {
        "idle".to_string()
    };
    if buf.is_null() || cap <= 1 {
        return -1;
    }
    let b = text.as_bytes();
    let n = b.len().min((cap as usize) - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(b.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

// ---------------------------------------------------------------------------
// 5) 注入 / 清除（走 TcpProvider + LocationSimulationService）
// ---------------------------------------------------------------------------
fn make_provider(pairing_path: &str, host: &str) -> Result<TcpProvider, String> {
    let pf = PairingFile::read_from_file(pairing_path)
        .map_err(|e| format!("pairing file 读取失败: {e}"))?;
    let addr: IpAddr = host.parse().map_err(|_| "host 非法".to_string())?;
    Ok(TcpProvider {
        addr,
        scope_id: None,
        pairing_file: pf,
        label: "lab-sim".to_string(),
    })
}

// ---------------------------------------------------------------------------
// 5.5) 配对文件体检（A 轮修正）
//
//  旧实现用 PairingFile::read_from_file 去读 iOS 27 的 rppairing 文件，
//  必然失败 → 误报「格式不对 501B」，并导致注入返回 -1。
//
//  新实现按内容区分两种体系（见 docs/A-RSD-ARCHITECTURE.md）：
//    0  = lockdown 配对文件（可直接注入）
//    1  = rppairing 配对文件（有效；注入需走 TLS-PSK/CDTunnel/RSD）
//   -1  = 文件不存在
//   -2  = 空文件
//   -3  = 未知格式
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn pairing_file_check(path: *const c_char) -> i32 {
    let p = cstr(path);
    if p.is_empty() {
        return -1;
    }
    let meta = match std::fs::metadata(&p) {
        Ok(m) => m,
        Err(_) => {
            plog(&format!("file_check: 文件不存在 {p}"));
            return -1;
        }
    };
    plog(&format!("file_check: {p} 大小={} 字节", meta.len()));
    if meta.len() == 0 {
        return -2;
    }

    let bytes = match std::fs::read(&p) {
        Ok(b) => b,
        Err(e) => {
            plog(&format!("file_check: 读取失败 {e}"));
            return -1;
        }
    };

    use crate::pairing_kind::{PairingKind, classify_pairing};
    let kind = classify_pairing(&bytes);
    match kind {
        PairingKind::RemotePairing => {
            // 再用库自己的解析器确认一次，避免只靠头部猜
            match idevice::remote_pairing::RpPairingFile::from_bytes(&bytes) {
                Ok(_) => {
                    plog("file_check: RpPairingFile 解析成功（有效 rppairing 配对）");
                    1
                }
                Err(e) => {
                    plog(&format!("file_check: 疑似 rppairing 但解析失败 {e}"));
                    -3
                }
            }
        }
        PairingKind::Lockdown => {
            match PairingFile::read_from_file(&p) {
                Ok(_) => {
                    plog("file_check: lockdown PairingFile 解析成功");
                    0
                }
                Err(e) => {
                    plog(&format!("file_check: 疑似 lockdown 但解析失败 {e}"));
                    -3
                }
            }
        }
        PairingKind::Missing => -2,
        PairingKind::Unknown => {
            plog("file_check: 未知格式");
            -3
        }
    }
}

#[no_mangle]
pub extern "C" fn simulate_location(
    pairing_path: *const c_char,
    host: *const c_char,
    lat: f64,
    lng: f64,
) -> i32 {
    let path = cstr(pairing_path);
    let host = cstr(host);
    let provider = match make_provider(&path, &host) {
        Ok(p) => p,
        Err(_) => return -1,
    };
    let lat_s = format!("{lat:.7}");
    let lng_s = format!("{lng:.7}");
    let r = rt().block_on(async {
        match LocationSimulationService::connect(&provider).await {
            Ok(mut svc) => svc.set(&lat_s, &lng_s).await.map_err(|e| format!("{e}")),
            Err(e) => Err(format!("connect: {e}")),
        }
    });
    if r.is_ok() { 0 } else { -2 }
}

#[no_mangle]
pub extern "C" fn clear_location(pairing_path: *const c_char, host: *const c_char) -> i32 {
    let path = cstr(pairing_path);
    let host = cstr(host);
    let provider = match make_provider(&path, &host) {
        Ok(p) => p,
        Err(_) => return -1,
    };
    let r = rt().block_on(async {
        match LocationSimulationService::connect(&provider).await {
            Ok(mut svc) => svc.clear().await.map_err(|e| format!("{e}")),
            Err(e) => Err(format!("connect: {e}")),
        }
    });
    if r.is_ok() { 0 } else { -2 }
}
