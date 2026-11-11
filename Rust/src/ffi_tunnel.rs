//
//  src/ffi_tunnel.rs —— C3 的 C 接口（给 Swift 调）
//
//  调用顺序（Swift 侧）：
//    tunnel_open(host, rp_port, pairing_path, buf, cap)  → 建立隧道，返回诊断 JSON
//    tunnel_inject(lat, lon, buf, cap)                   → 注入坐标
//    tunnel_clear(buf, cap)                              → 清除
//    tunnel_close()                                      → 释放
//
//  所有函数都是阻塞的（内部 block_on），Swift 侧放到后台队列调用。
//

use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use crate::coredevice_location::{CLEAR_ACTIONS, FEATURE_SIMULATE_LOCATION, SET_ACTIONS};
use crate::tunnel::{OpenTunnel, open_tunnel};

/// 返回码
pub mod rc {
    pub const OK: i32 = 0;
    pub const NO_TUNNEL: i32 = -1;      // 还没 open
    pub const OPEN_FAILED: i32 = -2;    // 建隧道失败
    pub const NO_SERVICE: i32 = -3;     // RSD 表里没有 locationservice
    pub const CONNECT_FAILED: i32 = -4; // 连不上服务端口
    pub const ACTION_FAILED: i32 = -5;  // 所有候选 action 都失败
    pub const BAD_PAIRING: i32 = -6;    // 配对文件问题
    pub const BAD_ARG: i32 = -7;
}

struct Held {
    tunnel: Option<OpenTunnel>,
    last_action: String,
    last_error: String,
}

static HELD: OnceLock<Mutex<Held>> = OnceLock::new();

fn held() -> &'static Mutex<Held> {
    HELD.get_or_init(|| {
        Mutex::new(Held {
            tunnel: None,
            last_action: String::new(),
            last_error: String::new(),
        })
    })
}

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned()
}

fn write_out(buf: *mut c_char, cap: i32, text: &str) -> i32 {
    if buf.is_null() || cap <= 1 {
        return text.len() as i32;
    }
    let bytes = text.as_bytes();
    let n = bytes.len().min((cap as usize) - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *((buf as *mut u8).add(n)) = 0;
    }
    n as i32
}

fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

// ---------------------------------------------------------------------------
// 建立隧道
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn tunnel_open(
    host: *const c_char,
    rp_port: i32,
    pairing_path: *const c_char,
    out_buf: *mut c_char,
    cap: i32,
) -> i32 {
    let host = {
        let h = cstr(host);
        if h.is_empty() { "127.0.0.1".to_string() } else { h }
    };
    let pairing = cstr(pairing_path);
    if pairing.is_empty() {
        return write_out(out_buf, cap, "配对文件路径为空") ;
    }

    let res = rt().block_on(open_tunnel(&host, rp_port.max(0) as u16, &pairing));

    match res {
        Ok(t) => {
            let json = t.diag.to_json();
            let names = crate::tunnel::service_names(&t);
            {
                let mut h = held().lock().unwrap();
                h.tunnel = Some(t);
                h.last_error.clear();
            }
            let mut msg = json;
            msg.push_str("\n服务数: ");
            msg.push_str(&names.len().to_string());
            if msg.len() < 900 {
                msg.push_str("\n前 12 个服务: ");
                msg.push_str(&names.iter().take(12).cloned().collect::<Vec<_>>().join(", "));
            }
            write_out(out_buf, cap, &msg);
            rc::OK
        }
        Err(e) => {
            held().lock().unwrap().last_error = e.clone();
            write_out(out_buf, cap, &e);
            if e.contains("配对") { rc::BAD_PAIRING } else { rc::OPEN_FAILED }
        }
    }
}

// ---------------------------------------------------------------------------
// 注入 / 清除
// ---------------------------------------------------------------------------
fn with_service<F>(f: F) -> Result<String, (i32, String)>
where
    F: FnOnce(
        idevice::services::core_device::CoreDeviceServiceClient<Box<dyn idevice::ReadWrite>>,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<String, String>> + Send>,
    >,
{
    let mut guard = held().lock().unwrap();
    let tunnel = guard
        .tunnel
        .as_mut()
        .ok_or((rc::NO_TUNNEL, "隧道还没建立，先调 tunnel_open".to_string()))?;

    // 先精确、再模糊匹配（iOS 27 的表里全是 *.shim.remote 名字）
    let (svc_name, port) = crate::tunnel::find_location_service(tunnel).ok_or_else(|| {
        let cands = crate::tunnel::location_candidates(tunnel);
        (
            rc::NO_SERVICE,
            if cands.is_empty() {
                format!("RSD 表共 {} 个服务，里面没有任何含 location/simulate 的", tunnel.services.len())
            } else {
                format!("找到候选但都不匹配: {}", cands.join(", "))
            },
        )
    })?;
    let _ = &svc_name;

    let result: Result<String, (i32, String)> = rt().block_on(async {
        use idevice::provider::RsdProvider;
        let stream = tunnel
            .handle
            .connect_to_service_port(port)
            .await
            .map_err(|e| (rc::CONNECT_FAILED, format!("连服务端口 {port} 失败: {e}")))?;
        let client = idevice::services::core_device::CoreDeviceServiceClient::new(stream)
            .await
            .map_err(|e| (rc::CONNECT_FAILED, format!("CoreDevice 握手失败: {e}")))?;
        f(client).await.map_err(|e| (rc::ACTION_FAILED, e))
    });

    match result {
        Ok(action) => {
            guard.last_action = action.clone();
            Ok(action)
        }
        Err((code, msg)) => {
            guard.last_error = msg.clone();
            Err((code, msg))
        }
    }
}

#[no_mangle]
pub extern "C" fn tunnel_inject(
    lat: f64,
    lon: f64,
    out_buf: *mut c_char,
    cap: i32,
) -> i32 {
    if let Err(e) = crate::coredevice_location::validate_coordinate(lat, lon) {
        write_out(out_buf, cap, &e);
        return rc::BAD_ARG;
    }

    let payload = crate::coredevice_location::build_set_payload(lat, lon);
    let feature = FEATURE_SIMULATE_LOCATION.to_string();

    let r = with_service(move |mut client| {
        Box::pin(async move {
            let mut last = String::new();
            for action in SET_ACTIONS {
                match client
                    .invoke_with_plist_action(feature.clone(), payload.clone(), *action)
                    .await
                {
                    Ok(_) => return Ok((*action).to_string()),
                    Err(e) => last = format!("{action}: {e}"),
                }
            }
            Err(last)
        })
    });

    match r {
        Ok(action) => {
            let msg = format!("注入成功，生效的 action = {action}\n坐标 = {lat}, {lon}");
            write_out(out_buf, cap, &msg);
            rc::OK
        }
        Err((code, msg)) => {
            write_out(out_buf, cap, &msg);
            code
        }
    }
}

#[no_mangle]
pub extern "C" fn tunnel_clear(out_buf: *mut c_char, cap: i32) -> i32 {
    let payload = crate::coredevice_location::build_clear_payload();
    let feature = FEATURE_SIMULATE_LOCATION.to_string();

    let r = with_service(move |mut client| {
        Box::pin(async move {
            let mut last = String::new();
            for action in CLEAR_ACTIONS {
                match client
                    .invoke_with_plist_action(feature.clone(), payload.clone(), *action)
                    .await
                {
                    Ok(_) => return Ok((*action).to_string()),
                    Err(e) => last = format!("{action}: {e}"),
                }
            }
            Err(last)
        })
    });

    match r {
        Ok(action) => {
            write_out(out_buf, cap, &format!("已清除模拟位置，action = {action}"));
            rc::OK
        }
        Err((code, msg)) => {
            write_out(out_buf, cap, &msg);
            code
        }
    }
}

// ---------------------------------------------------------------------------
// DVT 通路注入（com.apple.instruments.dtservicehub）
//
// iOS 27 的 RSD 表里没有 com.apple.coredevice.locationservice，
// 但有 com.apple.instruments.dtservicehub —— 这是 DVT 服务枢纽，
// 定位模拟走它：开通道 com.apple.instruments.server.services.LocationSimulation
// 然后调用 simulateLocationWithLatitude:longitude:（库里有现成实现）。
//
// 注意：DVT 要求连接保持，连接一断模拟就停 —— 所以这里 spawn 一个
// 常驻任务把连接撑住，clear 时 abort 它。
// ---------------------------------------------------------------------------

static DVT_TASK: OnceLock<Mutex<Option<tokio::task::JoinHandle<()>>>> = OnceLock::new();

fn dvt_task() -> &'static Mutex<Option<tokio::task::JoinHandle<()>>> {
    DVT_TASK.get_or_init(|| Mutex::new(None))
}

fn stop_dvt_task() {
    if let Ok(mut g) = dvt_task().lock() {
        if let Some(h) = g.take() {
            h.abort();
        }
    }
}

#[no_mangle]
pub extern "C" fn tunnel_inject_dvt(
    lat: f64,
    lon: f64,
    out_buf: *mut c_char,
    cap: i32,
) -> i32 {
    if let Err(e) = crate::coredevice_location::validate_coordinate(lat, lon) {
        write_out(out_buf, cap, &e);
        return rc::BAD_ARG;
    }

    // 连上 dtservicehub（需要 &mut handle，所以先同步做）
    let stream = {
        let mut guard = match held().lock() {
            Ok(g) => g,
            Err(_) => {
                write_out(out_buf, cap, "状态锁失效");
                return rc::NO_TUNNEL;
            }
        };
        let tunnel = match guard.tunnel.as_mut() {
            Some(t) => t,
            None => {
                write_out(out_buf, cap, "隧道还没建立，先调 tunnel_open");
                return rc::NO_TUNNEL;
            }
        };
        let port = match tunnel.services.get("com.apple.instruments.dtservicehub") {
            Some(p) => *p,
            None => {
                let cands = crate::tunnel::location_candidates(tunnel);
                let msg = format!(
                    "RSD 表里没有 com.apple.instruments.dtservicehub（共 {} 个服务；dt 候选: {}）",
                    tunnel.services.len(),
                    if cands.is_empty() { "无".to_string() } else { cands.join(",") }
                );
                write_out(out_buf, cap, &msg);
                return rc::NO_SERVICE;
            }
        };
        use idevice::provider::RsdProvider;
        match rt().block_on(tunnel.handle.connect_to_service_port(port)) {
            Ok(s) => s,
            Err(e) => {
                let msg = format!("连 dtservicehub({port}) 失败: {e}");
                write_out(out_buf, cap, &msg);
                return rc::CONNECT_FAILED;
            }
        }
    };

    // 旧任务先停掉
    stop_dvt_task();

    let (task, result) = rt().block_on(async move {
        use idevice::services::dvt::location_simulation::LocationSimulationClient;
        use idevice::services::dvt::remote_server::RemoteServerClient;

        let (tx, rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
        let handle = tokio::spawn(async move {
            let mut rsc = RemoteServerClient::new(stream);
            let mut loc = match LocationSimulationClient::new(&mut rsc).await {
                Ok(l) => l,
                Err(e) => {
                    let _ = tx.send(Err(format!("开 LocationSimulation 通道失败: {e}")));
                    return;
                }
            };
            if let Err(e) = loc.set(lat, lon).await {
                let _ = tx.send(Err(format!("simulateLocation 失败: {e}")));
                return;
            }
            let _ = tx.send(Ok(()));
            // 连接必须保持，否则模拟会停
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
            }
        });
        let r = match rx.await {
            Ok(v) => v,
            Err(_) => Err("任务提前结束".to_string()),
        };
        (handle, r)
    });

    match result {
        Ok(()) => {
            if let Ok(mut g) = dvt_task().lock() {
                *g = Some(task);
            }
            let msg = format!("DVT 注入成功：{lat}, {lon}（连接已保持）");
            write_out(out_buf, cap, &msg);
            rc::OK
        }
        Err(msg) => {
            task.abort();
            if let Ok(mut g) = held().lock() {
                g.last_error = msg.clone();
            }
            write_out(out_buf, cap, &msg);
            rc::ACTION_FAILED
        }
    }
}

#[no_mangle]
pub extern "C" fn tunnel_clear_dvt(out_buf: *mut c_char, cap: i32) -> i32 {
    stop_dvt_task();
    write_out(out_buf, cap, "已断开定位模拟连接（模拟随之停止）");
    rc::OK
}

// ---------------------------------------------------------------------------
// 其它
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn tunnel_services(out_buf: *mut c_char, cap: i32) -> i32 {
    let g = held().lock().unwrap();
    match g.tunnel.as_ref() {
        None => write_out(out_buf, cap, "隧道未建立"),
        Some(t) => {
            let names = crate::tunnel::service_names(t);
            write_out(out_buf, cap, &names.join("\n"))
        }
    }
}

#[no_mangle]
pub extern "C" fn tunnel_diag(out_buf: *mut c_char, cap: i32) -> i32 {
    let g = held().lock().unwrap();
    let mut s = String::new();
    match g.tunnel.as_ref() {
        Some(t) => s.push_str(&t.diag.to_json()),
        None => s.push_str("{\"state\":\"closed\"}"),
    }
    s.push_str("\n上次 action: ");
    s.push_str(if g.last_action.is_empty() { "-" } else { &g.last_action });
    if g.last_error.is_empty() == false {
        s.push_str("\n上次错误: ");
        s.push_str(&g.last_error);
    }
    write_out(out_buf, cap, &s)
}

/// 隧道是否还持有（1 = 还在，0 = 没了）
///
/// Swift 侧 @State 在视图重建时会丢，但 Rust 里隧道可能仍然活着。
/// 进页面先问这个，避免无谓地重连。
#[no_mangle]
pub extern "C" fn tunnel_alive(out_buf: *mut c_char, cap: i32) -> i32 {
    let alive = held()
        .lock()
        .map(|g| g.tunnel.is_some())
        .unwrap_or(false);
    write_out(
        out_buf,
        cap,
        if alive { "隧道保持中" } else { "隧道未建立" },
    );
    if alive { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn tunnel_close() -> i32 {
    let mut g = held().lock().unwrap();
    g.tunnel = None;
    rc::OK
}

/// 探测设备本机哪个端口是 _remotepairing._tcp
#[no_mangle]
pub extern "C" fn tunnel_probe_port(host: *const c_char) -> i32 {
    let host = {
        let h = cstr(host);
        if h.is_empty() { "127.0.0.1".to_string() } else { h }
    };
    match rt().block_on(crate::tunnel::probe_rp_port(&host)) {
        Some(p) => p as i32,
        None => -1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_out_respects_capacity() {
        let mut buf = [0i8; 8];
        let n = write_out(buf.as_mut_ptr(), 8, "0123456789abcdef");
        assert_eq!(n, 7);
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert_eq!(s, "0123456", "必须截断到 cap-1 并补 NUL");
        println!("✓ write_out 截断正确: {:?}", s);
    }

    #[test]
    fn null_buffer_returns_length() {
        let n = write_out(std::ptr::null_mut(), 0, "hello");
        assert_eq!(n, 5);
        println!("✓ 空缓冲返回长度");
    }

    #[test]
    fn inject_rejects_bad_coordinates_before_touching_tunnel() {
        let mut buf = [0i8; 128];
        let code = tunnel_inject(91.0, 0.0, buf.as_mut_ptr(), 128);
        assert_eq!(code, rc::BAD_ARG);
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert!(s.contains("纬度"), "应提示纬度越界: {}", s);
        println!("✓ 非法坐标在进隧道前就被拒: {}", s);
    }

    #[test]
    fn inject_without_tunnel_reports_no_tunnel() {
        tunnel_close();
        let mut buf = [0i8; 256];
        let code = tunnel_inject(36.7, 119.1, buf.as_mut_ptr(), 256);
        assert_eq!(code, rc::NO_TUNNEL);
        println!("✓ 未建隧道时返回 NO_TUNNEL 而非崩溃");
    }
}
