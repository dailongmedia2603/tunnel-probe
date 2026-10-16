# Tunnel Probe

App test (TrollStore) xác định cách nhúng WireGuard vào app Phone Agent trên iPhone,
thay cho Tailscale. Kết quả quyết định chọn Cách A (PacketTunnel) hay Cách B (root utun).

| Test | Kiểm tra |
|---|---|
| 1 | Root helper tạo được interface `utun` (điều kiện của Cách B) |
| 2 | PacketTunnel extension bật được VPN (điều kiện của Cách A) |
| 3A / 4A | WireGuard qua PacketTunnel: chỉ mạng nội bộ / toàn bộ traffic |
| 3B / 4B | WireGuard qua root utun: chỉ mạng nội bộ / toàn bộ traffic |

Mỗi test WireGuard đo: handshake, điện thoại → server, server → điện thoại, tốc độ,
và (toàn bộ traffic) IP ra internet có phải IP VPS không.

## Cách dùng

1. **VPS**: `sudo bash setup-probe.sh` → in ra IP + token. Mở firewall nhà cung cấp: UDP 51820, TCP 51821.
2. **iPhone**: tắt Tailscale, cài `TunnelProbe.tipa` bằng TrollStore, nhập IP + token, bấm **Chạy tất cả test**.
3. Xem kết quả: trên app, hoặc `sudo bash setup-probe.sh report` trên VPS.
4. Dọn dẹp: xoá app trong TrollStore; `sudo bash setup-probe.sh uninstall` trên VPS; bật lại Tailscale.

## Build

GitHub Actions build mỗi lần push lên `main` → release `latest` có `TunnelProbe.tipa` và `setup-probe.sh`.
Build local: `SDK=/path/iPhoneOS.sdk ./build.sh` (cần Go, clang, ldid).

## Cấu trúc

- `go/` — wireguard-go đóng gói thành C library (`libwg.a`)
- `shared/netutil.c` — utun, gán IP, routing socket
- `helper/` — root helper (Test 1, 3B, 4B)
- `extension/` — PacketTunnel extension (Test 2, 3A, 4A)
- `app/` — giao diện + điều phối test
- `vps/setup-probe.sh` — WireGuard `wgp0` (10.77.0.0/24) + API test, tách biệt hoàn toàn khỏi PhoneAgent
