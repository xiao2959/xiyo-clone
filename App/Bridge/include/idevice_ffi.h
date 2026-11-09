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

/* ---------- 注入 ---------- */
// 0 成功；-1 参数/pairing 文件错；-2 连接或注入失败
int32_t simulate_location(const char *pairing_path, const char *host, double lat, double lng);
int32_t clear_location(const char *pairing_path, const char *host);

#ifdef __cplusplus
}
#endif

#endif
