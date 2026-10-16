#!/bin/bash
# Tunnel Probe — test server for the VPS (Ubuntu/Debian, run as root).
#
#   bash setup-probe.sh            install / restart, prints IP + token for the app
#   bash setup-probe.sh report     show the latest report sent by the phone
#   bash setup-probe.sh uninstall  remove everything (interface, rules, service)
#
# Self-contained and separate from PhoneAgent: own interface (wgp0), own
# subnet (10.77.0.0/24), own ports (UDP 51820, TCP 51821). Does not touch
# Tailscale, Docker or sing-box.
set -euo pipefail

DIR=/opt/tunnel-probe
IFACE=wgp0
SUBNET=10.77.0
WG_PORT=51820
API_PORT=51821
SERVICE=tunnel-probe

[ "$(id -u)" = 0 ] || { echo "Hãy chạy bằng root:  sudo bash $0 $*"; exit 1; }

ipt_del_all() { while iptables "$@" 2>/dev/null; do :; done; }

remove_rules() {
  local def_if="$1"
  ipt_del_all -D FORWARD -i $IFACE -j ACCEPT
  ipt_del_all -D FORWARD -o $IFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt_del_all -D INPUT -p udp --dport $WG_PORT -j ACCEPT
  ipt_del_all -D INPUT -p tcp --dport $API_PORT -j ACCEPT
  [ -n "$def_if" ] && ipt_del_all -t nat -D POSTROUTING -s $SUBNET.0/24 -o "$def_if" -j MASQUERADE
  return 0
}

DEFAULT_IF=$(ip -4 route show default | awk '{print $5; exit}')

case "${1:-install}" in
uninstall)
  systemctl disable --now $SERVICE 2>/dev/null || true
  rm -f /etc/systemd/system/$SERVICE.service
  systemctl daemon-reload 2>/dev/null || true
  ip link del $IFACE 2>/dev/null || true
  remove_rules "$DEFAULT_IF"
  if [ -d $DIR/reports ]; then
    mkdir -p /root/tunnel-probe-reports && cp -r $DIR/reports/. /root/tunnel-probe-reports/ || true
    echo "Đã giữ lại báo cáo ở /root/tunnel-probe-reports"
  fi
  rm -rf $DIR
  echo "Đã gỡ Tunnel Probe khỏi VPS."
  exit 0
  ;;
report)
  latest=$(ls -t $DIR/reports/*.txt 2>/dev/null | head -1 || true)
  [ -n "$latest" ] || { echo "Chưa có báo cáo nào. Chạy test trên iPhone trước."; exit 1; }
  echo "=== $latest ==="
  cat "$latest"
  exit 0
  ;;
install) ;;
*) echo "Cách dùng: bash $0 [install|report|uninstall]"; exit 1 ;;
esac

echo "==> Cài gói cần thiết"
if ! command -v wg >/dev/null || ! command -v python3 >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools python3 iptables
  elif command -v dnf >/dev/null; then
    dnf install -y wireguard-tools python3 iptables
  elif command -v yum >/dev/null; then
    yum install -y wireguard-tools python3 iptables
  else
    echo "Không tìm thấy apt/dnf/yum — hãy tự cài wireguard-tools và python3"; exit 1
  fi
fi
modprobe wireguard 2>/dev/null || true

mkdir -p $DIR/reports
chmod 700 $DIR
[ -f $DIR/server.key ] || (umask 077 && wg genkey > $DIR/server.key)
wg pubkey < $DIR/server.key > $DIR/server.pub
[ -f $DIR/token ] || python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range(8)), end='')" > $DIR/token

PUBLIC_IP="${PUBLIC_IP:-}"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)
fi
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(ip -4 addr show "$DEFAULT_IF" | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
fi
echo -n "$PUBLIC_IP" > $DIR/public_ip

echo "==> Tạo interface $IFACE ($SUBNET.1/24, UDP $WG_PORT)"
if ! ip link show $IFACE >/dev/null 2>&1; then
  ip link add $IFACE type wireguard || {
    echo "Kernel không hỗ trợ WireGuard (ip link add type wireguard lỗi)."
    echo "Thử: apt-get install -y linux-modules-extra-\$(uname -r) rồi chạy lại."
    exit 1
  }
fi
wg set $IFACE listen-port $WG_PORT private-key $DIR/server.key
ip addr replace $SUBNET.1/24 dev $IFACE
ip link set $IFACE up mtu 1420

echo "==> Bật forward + NAT cho $SUBNET.0/24 qua $DEFAULT_IF"
sysctl -q -w net.ipv4.ip_forward=1
remove_rules "$DEFAULT_IF"
iptables -I FORWARD 1 -i $IFACE -j ACCEPT
iptables -I FORWARD 1 -o $IFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I INPUT 1 -p udp --dport $WG_PORT -j ACCEPT
iptables -I INPUT 1 -p tcp --dport $API_PORT -j ACCEPT
iptables -t nat -A POSTROUTING -s $SUBNET.0/24 -o "$DEFAULT_IF" -j MASQUERADE
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow $WG_PORT/udp >/dev/null
  ufw allow $API_PORT/tcp >/dev/null
fi

echo "==> Ghi probe_server.py"
cat > $DIR/probe_server.py <<'PYEOF'
#!/usr/bin/env python3
"""Tunnel Probe API: enroll WireGuard peers, echo/speed tests, reverse
connection test (server -> phone), and test reports from the iPhone app."""
import base64, ipaddress, json, os, re, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DIR = os.environ.get("PROBE_DIR", "/opt/tunnel-probe")
IFACE, SUBNET, WG_PORT, API_PORT = "wgp0", "10.77.0", 51820, 51821
NET = ipaddress.ip_network(SUBNET + ".0/24")
read = lambda f: open(os.path.join(DIR, f)).read().strip()
TOKEN, SERVER_PUB, PUBLIC_IP = read("token"), read("server.pub"), read("public_ip")
PEERS = os.path.join(DIR, "peers.json")
lock = threading.Lock()


def load_peers():
    try:
        return json.load(open(PEERS))
    except Exception:
        return {}


def wg_add(pub, ip):
    subprocess.run(["wg", "set", IFACE, "peer", pub, "allowed-ips", ip + "/32"], check=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "TunnelProbe/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    def send_json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/ping":
            return self.send_json(200, {"ok": True, "remote": self.client_address[0], "time": time.time()})
        if u.path == "/speed":
            mb = max(1, min(int(parse_qs(u.query).get("mb", ["5"])[0]), 50))
            total = mb * 1024 * 1024
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(total))
            self.end_headers()
            chunk = b"\0" * 65536
            for _ in range(total // len(chunk)):
                self.wfile.write(chunk)
            return
        if u.path == "/":
            return self.send_json(200, {"ok": True, "service": "tunnel-probe"})
        self.send_json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}") if n < 8 * 1024 * 1024 else {}
        except Exception:
            return self.send_json(400, {"ok": False, "error": "JSON không hợp lệ"})
        if body.get("token") != TOKEN:
            return self.send_json(403, {"ok": False, "error": "sai token"})
        if u.path == "/enroll":
            return self.enroll(body)
        if u.path == "/callback":
            return self.callback(body)
        if u.path == "/report":
            return self.report(body)
        self.send_json(404, {"ok": False, "error": "not found"})

    def enroll(self, body):
        pub = (body.get("publicKey") or "").strip()
        try:
            assert len(base64.b64decode(pub, validate=True)) == 32
        except Exception:
            return self.send_json(400, {"ok": False, "error": "publicKey không hợp lệ"})
        with lock:
            peers = load_peers()
            ip = peers.get(pub, {}).get("ip")
            if not ip:
                used = {p["ip"] for p in peers.values()}
                ip = next((f"{SUBNET}.{i}" for i in range(2, 255) if f"{SUBNET}.{i}" not in used), None)
                if not ip:
                    return self.send_json(500, {"ok": False, "error": "hết IP trong subnet"})
            peers[pub] = {"ip": ip, "name": body.get("name", ""), "time": int(time.time())}
            json.dump(peers, open(PEERS, "w"), indent=2)
            try:
                wg_add(pub, ip)
            except Exception as e:
                return self.send_json(500, {"ok": False, "error": "wg set lỗi: %s" % e})
        print("enrolled %s -> %s (%s)" % (pub[:8], ip, body.get("name", "")), flush=True)
        self.send_json(200, {
            "ok": True, "address": ip, "peerAddress": SUBNET + ".1",
            "subnet": SUBNET + ".0", "subnetMask": "255.255.255.0",
            "serverPublicKey": SERVER_PUB, "endpoint": "%s:%d" % (PUBLIC_IP, WG_PORT),
            "publicIP": PUBLIC_IP,
        })

    def callback(self, body):
        ip, port = body.get("ip", ""), int(body.get("port") or 8099)
        try:
            assert ipaddress.ip_address(ip) in NET
        except Exception:
            return self.send_json(400, {"ok": False, "error": "ip phải thuộc " + str(NET)})
        try:
            t0 = time.time()
            with socket.create_connection((ip, port), timeout=6) as s:
                s.settimeout(6)
                got = s.recv(256).decode(errors="replace").strip()
            self.send_json(200, {"ok": True, "got": got, "ms": int((time.time() - t0) * 1000)})
        except Exception as e:
            self.send_json(200, {"ok": False, "error": "server không kết nối được %s:%d (%s)" % (ip, port, e)})

    def report(self, body):
        r = body.get("report") or {}
        dev = r.get("device") or {}
        tag = re.sub(r"[^A-Za-z0-9,._-]", "_", dev.get("model", "iphone"))
        base = os.path.join(DIR, "reports", time.strftime("%Y%m%d-%H%M%S") + "-" + tag)
        json.dump(r, open(base + ".json", "w"), ensure_ascii=False, indent=2)
        lines = ["Thiết bị: %s (%s), iOS %s" % (dev.get("name"), dev.get("model"), dev.get("ios")), ""]
        for k in r.get("order") or []:
            res = (r.get("results") or {}).get(k) or {}
            lines.append("%s %s: %s" % ("PASS" if res.get("pass") else "FAIL", k, res.get("detail", "")))
        lines += ["", r.get("conclusion", ""), "", "----- LOG -----", r.get("log", "")]
        open(base + ".txt", "w").write("\n".join(lines))
        print("report saved: " + base + ".txt", flush=True)
        self.send_json(200, {"ok": True, "file": base + ".txt"})


def main():
    for pub, p in load_peers().items():
        try:
            wg_add(pub, p["ip"])
        except Exception as e:
            print("restore peer failed: %s" % e, flush=True)
    srv = ThreadingHTTPServer(("0.0.0.0", API_PORT), Handler)
    srv.daemon_threads = True
    print("tunnel-probe listening on :%d, endpoint %s:%d" % (API_PORT, PUBLIC_IP, WG_PORT), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

echo "==> Tạo service $SERVICE"
IP_BIN=$(command -v ip); WG_BIN=$(command -v wg); PY_BIN=$(command -v python3)
cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=Tunnel Probe test server
After=network-online.target

[Service]
ExecStartPre=-$IP_BIN link add $IFACE type wireguard
ExecStartPre=$WG_BIN set $IFACE listen-port $WG_PORT private-key $DIR/server.key
ExecStartPre=$IP_BIN addr replace $SUBNET.1/24 dev $IFACE
ExecStartPre=$IP_BIN link set $IFACE up mtu 1420
ExecStart=$PY_BIN $DIR/probe_server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable $SERVICE >/dev/null 2>&1 || true
systemctl restart $SERVICE
sleep 2

if curl -s --max-time 5 http://127.0.0.1:$API_PORT/ping >/dev/null; then
  STATUS="ĐANG CHẠY"
else
  STATUS="LỖI — xem: journalctl -u $SERVICE -n 50"
fi

cat <<EOF

==========================================================
  Tunnel Probe server: $STATUS

  Nhập vào app "Tunnel Probe" trên iPhone:
     IP VPS : $PUBLIC_IP
     Token  : $(cat $DIR/token)

  Nếu nhà cung cấp VPS có firewall riêng (Security Group,
  Cloud Firewall...), hãy mở thêm:
     UDP $WG_PORT   và   TCP $API_PORT

  Xem kết quả sau khi test:  bash $0 report
  Gỡ sạch sau khi test xong:  bash $0 uninstall
==========================================================
EOF
