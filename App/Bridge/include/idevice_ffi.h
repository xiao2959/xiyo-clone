/* idevice_ffi.h —— 与 Rust 静态库的 C ABI
 * 源码：Rust/src/pairing.rs；符号核对：nm -gU libidevice_ffi.a | grep -E 'pairing_|_location'
 */
#ifndef IDEVICE_FFI_H
#define IDEVICE_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- 配对（纯手机端，设备主动连入） ---------- */
// 启动本地 listener，返回端口（>0）；失败 -1
int32_t pairing_start(const char *name, const char *save_path);
// 取 6 位码：>0 长度，0 还没生成，-1 参数错
int32_t pairing_take_pin(char *buf, int32_t cap);
// 等结果：0 成功，-1 超时/进行中，-2 失败，-3 无会话
int32_t pairing_wait(int32_t timeout_ms);
// 状态文本："paired:<udid>" / "waiting_pin" / "error:..." / "idle"
int32_t pairing_status(char *buf, int32_t cap);
// Bonjour：服务类型 / 实例名 / TXT(每行 k=v)
int32_t pairing_service_type(char *buf, int32_t cap);
int32_t pairing_identifier(char *buf, int32_t cap);
int32_t pairing_txt(char *buf, int32_t cap);

/* ---------- 注入（lockdown 直连路线，需 lockdown 证书） ---------- */
// 0 成功；-1 参数/pairing 文件错；-2 连接或注入失败
int32_t simulate_location(const char *pairing_path, const char *host, double lat, double lng);
int32_t clear_location(const char *pairing_path, const char *host);

/* ---------- C3：rppairing 用户态隧道（不需要 utun / NetworkExtension） ----------
 *
 * 返回码：
 *   0  OK
 *  -1  隧道还没建立（先调 tunnel_open）
 *  -2  建隧道失败
 *  -3  RSD 服务表里没有 com.apple.coredevice.locationservice
 *  -4  连不上服务端口 / CoreDevice 握手失败
 *  -5  所有候选 action 都失败
 *  -6  配对文件问题
 *  -7  参数非法
 */

// 建立隧道。host 传 NULL 用 127.0.0.1；rp_port 传 0 自动探测。
// out_buf 收到诊断 JSON + 服务列表
int32_t tunnel_open(const char *host, int32_t rp_port,
                    const char *pairing_path, char *out_buf, int32_t cap);

// 注入坐标（内部按候选 action 逐个试，成功的那个会回显）
int32_t tunnel_inject(double lat, double lon, char *out_buf, int32_t cap);

// 清除模拟位置
int32_t tunnel_clear(char *out_buf, int32_t cap);

/* ---------- DVT 通路注入（com.apple.instruments.dtservicehub） ----------
 * iOS 27 的 RSD 表里没有 coredevice.locationservice，但有 dtservicehub，
 * 定位模拟走 DVT。连接必须保持，断开即停止模拟。
 */
int32_t tunnel_inject_dvt(double lat, double lon, char *out_buf, int32_t cap);

/* 隧道是否还持有：1 = 在，0 = 没了 */
int32_t tunnel_alive(char *out_buf, int32_t cap);
int32_t tunnel_clear_dvt(char *out_buf, int32_t cap);

// 列出全部 RSD 服务名（排查用）
int32_t tunnel_services(char *out_buf, int32_t cap);

// 诊断：隧道 JSON + 上次 action + 上次错误
int32_t tunnel_diag(char *out_buf, int32_t cap);

// 探测 _remotepairing._tcp 端口；成功返回端口号，失败 -1
int32_t tunnel_probe_port(const char *host);

// 释放隧道
int32_t tunnel_close(void);

#ifdef __cplusplus
}
#endif

#endif
