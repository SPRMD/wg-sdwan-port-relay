#!/usr/bin/env bash
set -euo pipefail

WG_IF="${WG_IF:-wg-sdwan}"
WG_PORT="${WG_PORT:-51820}"
WG_NET_V4="${WG_NET_V4:-10.233.233.0/24}"
RELAY_WG_IP_CIDR="${RELAY_WG_IP_CIDR:-10.233.233.1/24}"
ENTRY_WG_IP_CIDR="${ENTRY_WG_IP_CIDR:-10.233.233.2/24}"
RELAY_WG_IP="${RELAY_WG_IP:-10.233.233.1}"
ENTRY_WG_IP="${ENTRY_WG_IP:-10.233.233.2}"

# Relay runtime defaults. Can be overridden in /etc/wg-sdwan-port-relay/config.env
MAX_TCP_CONNECTIONS="${MAX_TCP_CONNECTIONS:-1024}"
MAX_UDP_CLIENTS="${MAX_UDP_CLIENTS:-4096}"
TCP_IDLE_TIMEOUT="${TCP_IDLE_TIMEOUT:-300}"
UDP_IDLE_TIMEOUT="${UDP_IDLE_TIMEOUT:-180}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
LOG_LEVEL="${LOG_LEVEL:-info}"
TARGET_FAMILY="${TARGET_FAMILY:-ipv4}"

CONF_DIR="/etc/wg-sdwan-port-relay"
KEY_DIR="${CONF_DIR}/keys"
FORWARDS="${CONF_DIR}/forwards.csv"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
RELAY_BIN="/usr/local/bin/wg-sdwan-port-relay.py"
RELAY_SERVICE="/etc/systemd/system/wg-sdwan-port-relay.service"
CONFIG_ENV="${CONF_DIR}/config.env"
IPT_COMMENT="wg-sdwan-port-relay"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root, for example: sudo bash $0 ..." >&2
    exit 1
  fi
}

refresh_wg_conf() {
  WG_CONF="/etc/wireguard/${WG_IF}.conf"
}

load_config() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV"
  fi
  refresh_wg_conf
}

ensure_dirs() {
  mkdir -p "$CONF_DIR" "$KEY_DIR" /etc/wireguard
  chmod 700 "$KEY_DIR"
  touch "$FORWARDS"
}

save_config() {
  ensure_dirs
  cat > "$CONFIG_ENV" <<EOF
WG_IF=$(printf '%q' "$WG_IF")
WG_NET_V4=$(printf '%q' "$WG_NET_V4")
MAX_TCP_CONNECTIONS=$(printf '%q' "$MAX_TCP_CONNECTIONS")
MAX_UDP_CLIENTS=$(printf '%q' "$MAX_UDP_CLIENTS")
TCP_IDLE_TIMEOUT=$(printf '%q' "$TCP_IDLE_TIMEOUT")
UDP_IDLE_TIMEOUT=$(printf '%q' "$UDP_IDLE_TIMEOUT")
CONNECT_TIMEOUT=$(printf '%q' "$CONNECT_TIMEOUT")
LOG_LEVEL=$(printf '%q' "$LOG_LEVEL")
TARGET_FAMILY=$(printf '%q' "$TARGET_FAMILY")
EOF
}

ensure_key() {
  ensure_dirs
  if [ ! -f "${KEY_DIR}/privatekey" ]; then
    wg genkey | tee "${KEY_DIR}/privatekey" | wg pubkey > "${KEY_DIR}/publickey"
    chmod 600 "${KEY_DIR}/privatekey"
  fi
}

ensure_psk() {
  ensure_dirs
  if [ ! -s "${KEY_DIR}/presharedkey" ]; then
    wg genpsk > "${KEY_DIR}/presharedkey"
    chmod 600 "${KEY_DIR}/presharedkey"
  fi
}

default_psk() {
  if [ -n "${WG_PSK:-}" ]; then
    printf '%s
' "$WG_PSK"
  elif [ -s "${KEY_DIR}/presharedkey" ]; then
    cat "${KEY_DIR}/presharedkey"
  fi
}

save_psk() {
  local psk="$1"
  [ -n "$psk" ] || return 0
  ensure_dirs
  printf '%s
' "$psk" > "${KEY_DIR}/presharedkey"
  chmod 600 "${KEY_DIR}/presharedkey"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

missing_deps() {
  local missing=0
  for cmd in wg ip iptables python3 systemctl awk; do
    if ! have_cmd "$cmd"; then
      echo "missing: $cmd"
      missing=1
    fi
  done
  return "$missing"
}

require_deps() {
  if ! missing_deps >/tmp/wg_sdw_relay_missing.$$; then
    echo "Missing dependencies:" >&2
    cat /tmp/wg_sdw_relay_missing.$$ >&2
    rm -f /tmp/wg_sdw_relay_missing.$$
    echo >&2
    echo "Install dependencies manually or run:" >&2
    echo "  sudo bash $0 install-deps" >&2
    exit 1
  fi
  rm -f /tmp/wg_sdw_relay_missing.$$
}

cmd_check() {
  local tmp=""
  tmp="$(mktemp)"
  if ! missing_deps > "$tmp"; then
    echo "Missing dependencies:"
    cat "$tmp"
    rm -f "$tmp"
    echo
    echo "Some dependencies are missing. Run: sudo bash $0 install-deps"
    exit 1
  fi
  rm -f "$tmp"
  echo "All required dependencies are present."
}

cmd_install_deps() {
  need_root
  echo "This will install system packages required by wg-sdwan-port-relay."
  echo "No configuration will be changed by this command."
  confirm_or_exit "Type YES to continue"

  if have_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 iptables python3 coreutils gawk
  elif have_cmd dnf; then
    dnf install -y wireguard-tools iproute iptables python3 coreutils gawk
  elif have_cmd yum; then
    yum install -y wireguard-tools iproute iptables python3 coreutils gawk
  else
    echo "Unsupported package manager. Please install: wireguard-tools, iproute2/iproute, iptables, python3, coreutils, awk" >&2
    exit 1
  fi
}

validate_port() {
  local p="$1" label="${2:-port}"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    echo "Invalid ${label}: must be an integer between 1 and 65535" >&2
    exit 1
  fi
}

validate_int_range() {
  local value="$1" label="$2" min="$3" max="$4"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    echo "Invalid ${label}: must be an integer between ${min} and ${max}" >&2
    exit 1
  fi
}

validate_iface() {
  local name="$1"
  if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]]; then
    echo "Invalid interface name: ${name}" >&2
    echo "Use 1-15 chars: letters, numbers, dot, underscore, hyphen; must start with letter or number." >&2
    exit 1
  fi
}

validate_target_name() {
  local name="$1"
  if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
    echo "Invalid target name: ${name}" >&2
    exit 1
  fi
}

validate_host() {
  local host="$1"
  python3 - "$host" <<'PY'
import ipaddress, re, sys
host = sys.argv[1].strip()
if not host or len(host) > 253:
    raise SystemExit("invalid host: empty or too long")
try:
    h = host.strip("[]")
    ipaddress.ip_address(h)
    raise SystemExit(0)
except ValueError:
    pass
label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
if not re.fullmatch(label + r"(?:\." + label + r")*", host):
    raise SystemExit("invalid host: must be an IP address or DNS hostname")
PY
}

validate_cidr() {
  local cidr="$1" label="${2:-CIDR}"
  python3 - "$cidr" "$label" <<'PY'
import ipaddress, sys
cidr, label = sys.argv[1], sys.argv[2]
try:
    ipaddress.ip_network(cidr, strict=False)
except Exception as exc:
    raise SystemExit(f"invalid {label}: {exc}")
PY
}

validate_ipv4_cidr() {
  local cidr="$1" label="${2:-IPv4 CIDR}"
  python3 - "$cidr" "$label" <<'PY'
import ipaddress, sys
cidr, label = sys.argv[1], sys.argv[2]
try:
    net = ipaddress.ip_network(cidr, strict=False)
except Exception as exc:
    raise SystemExit(f"invalid {label}: {exc}")
if net.version != 4:
    raise SystemExit(f"invalid {label}: must be IPv4")
PY
}

validate_ip() {
  local ip="$1" label="${2:-IP}"
  python3 - "$ip" "$label" <<'PY'
import ipaddress, sys
ip, label = sys.argv[1], sys.argv[2]
try:
    ipaddress.ip_address(ip)
except Exception as exc:
    raise SystemExit(f"invalid {label}: {exc}")
PY
}

validate_wg_pubkey() {
  local key="$1" label="${2:-WireGuard public key}"
  python3 - "$key" "$label" <<'PY'
import base64, sys
key, label = sys.argv[1], sys.argv[2]
try:
    raw = base64.b64decode(key, validate=True)
except Exception:
    raise SystemExit(f"invalid {label}: not valid base64")
if len(raw) != 32:
    raise SystemExit(f"invalid {label}: decoded length must be 32 bytes")
PY
}

validate_wg_psk() {
  local key="$1" label="${2:-WireGuard preshared key}"
  python3 - "$key" "$label" <<'PY'
import base64, sys
key, label = sys.argv[1], sys.argv[2]
try:
    raw = base64.b64decode(key, validate=True)
except Exception:
    raise SystemExit(f"invalid {label}: not valid base64")
if len(raw) != 32:
    raise SystemExit(f"invalid {label}: decoded length must be 32 bytes")
PY
}

validate_proto() {
  local proto="$1"
  case "$proto" in tcp|udp|both) :;; *) echo "Invalid protocol: ${proto}. Use tcp, udp, or both." >&2; exit 1;; esac
}

psk_line() {
  local psk="${1:-}"
  if [ -n "$psk" ]; then
    printf 'PresharedKey = %s\n' "$psk"
  fi
}

validate_allowed_ips() {
  local value="$1"
  python3 - "$value" <<'PY'
import ipaddress, sys
value = sys.argv[1]
items = [x.strip() for x in value.split(',')]
if not items or any(not x for x in items):
    raise SystemExit("invalid AllowedIPs: empty item")
for item in items:
    try:
        ipaddress.ip_network(item, strict=False)
    except Exception as exc:
        raise SystemExit(f"invalid AllowedIPs item {item}: {exc}")
PY
}

validate_runtime_limits() {
  validate_int_range "$MAX_TCP_CONNECTIONS" MAX_TCP_CONNECTIONS 1 1048576
  validate_int_range "$MAX_UDP_CLIENTS" MAX_UDP_CLIENTS 1 1048576
  validate_int_range "$TCP_IDLE_TIMEOUT" TCP_IDLE_TIMEOUT 1 86400
  validate_int_range "$UDP_IDLE_TIMEOUT" UDP_IDLE_TIMEOUT 1 86400
  validate_int_range "$CONNECT_TIMEOUT" CONNECT_TIMEOUT 1 3600
  case "$LOG_LEVEL" in debug|info|warning|error) :;; *) echo "Invalid LOG_LEVEL: ${LOG_LEVEL}" >&2; exit 1;; esac
  case "$TARGET_FAMILY" in ipv4|any) :;; *) echo "Invalid TARGET_FAMILY: ${TARGET_FAMILY}" >&2; exit 1;; esac
}

ask() {
  local __ask_var="$1" __ask_prompt="$2" __ask_default="${3:-}" __ask_reply=""
  read -rp "${__ask_prompt}${__ask_default:+ [$__ask_default]}: " __ask_reply
  printf -v "$__ask_var" '%s' "${__ask_reply:-$__ask_default}"
}

ask_required() {
  local __ask_var="$1" __ask_prompt="$2" __ask_reply=""
  while true; do
    read -rp "${__ask_prompt}: " __ask_reply
    if [ -n "$__ask_reply" ]; then
      printf -v "$__ask_var" '%s' "$__ask_reply"
      return 0
    fi
    echo "Value cannot be empty."
  done
}

ask_port() {
  local var="$1" prompt="$2" default_value="$3" input=""
  while true; do
    ask input "$prompt" "$default_value"
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
    echo "Port must be an integer between 1 and 65535."
  done
}

run_validator() {
  local value="$1" validator="$2" err=""
  shift 2
  if err="$($validator "$value" "$@" 2>&1)"; then
    return 0
  fi
  [ -n "$err" ] && echo "$err" >&2
  return 1
}

ask_validated() {
  local var="$1" prompt="$2" default_value="$3" validator="$4" input=""
  shift 4
  while true; do
    ask input "$prompt" "$default_value"
    if run_validator "$input" "$validator" "$@"; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
  done
}

ask_required_validated() {
  local var="$1" prompt="$2" validator="$3" input=""
  shift 3
  while true; do
    ask_required input "$prompt"
    if run_validator "$input" "$validator" "$@"; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
  done
}

ask_optional_psk() {
  local var="$1" prompt="$2" default_value="$3" input=""
  while true; do
    ask input "$prompt" "$default_value"
    if [ -z "$input" ] || run_validator "$input" validate_wg_psk "WireGuard preshared key"; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
  done
}

ask_proto() {
  local var="$1" prompt="$2" default_value="$3" input=""
  while true; do
    ask input "$prompt" "$default_value"
    if run_validator "$input" validate_proto; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
  done
}

confirm_or_exit() {
  local prompt="${1:-Type YES to continue}"
  local confirm=""
  read -rp "${prompt}: " confirm
  if [ "$confirm" != "YES" ]; then
    echo "Cancelled."
    exit 0
  fi
}

endpoint() {
  local host="$1" port="$2"
  if [[ "$host" == \[*\] ]]; then
    echo "${host}:${port}"
  elif [[ "$host" == *:* ]]; then
    echo "[${host}]:${port}"
  else
    echo "${host}:${port}"
  fi
}

install_relay() {
  validate_iface "$WG_IF"
  validate_runtime_limits
  cat > "$RELAY_BIN" <<'PY'
#!/usr/bin/env python3
import csv
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import time

CONFIG = sys.argv[1] if len(sys.argv) > 1 else "/etc/wg-sdwan-port-relay/forwards.csv"
WG_IF = os.environ.get("WG_IF", "wg-sdwan")
TARGET_FAMILY = os.environ.get("TARGET_FAMILY", "ipv4")
MAX_TCP_CONNECTIONS = int(os.environ.get("MAX_TCP_CONNECTIONS", "1024"))
MAX_UDP_CLIENTS = int(os.environ.get("MAX_UDP_CLIENTS", "4096"))
TCP_IDLE_TIMEOUT = int(os.environ.get("TCP_IDLE_TIMEOUT", "300"))
UDP_IDLE_TIMEOUT = int(os.environ.get("UDP_IDLE_TIMEOUT", "180"))
CONNECT_TIMEOUT = int(os.environ.get("CONNECT_TIMEOUT", "15"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").lower()

LEVELS = {"debug": 10, "info": 20, "warning": 30, "error": 40}
LOG_THRESHOLD = LEVELS.get(LOG_LEVEL, 20)
stop_event = threading.Event()
tcp_sem = threading.BoundedSemaphore(MAX_TCP_CONNECTIONS)
udp_total_lock = threading.Lock()
udp_total_clients = 0


def log(level, message):
    if LEVELS.get(level, 20) >= LOG_THRESHOLD:
        print(time.strftime("[%F %T]"), level.upper(), message, flush=True)


def validate_runtime():
    if MAX_TCP_CONNECTIONS < 1 or MAX_UDP_CLIENTS < 1:
        raise SystemExit("MAX_TCP_CONNECTIONS and MAX_UDP_CLIENTS must be positive")
    if TCP_IDLE_TIMEOUT < 1 or UDP_IDLE_TIMEOUT < 1 or CONNECT_TIMEOUT < 1:
        raise SystemExit("timeouts must be positive")
    if TARGET_FAMILY not in {"ipv4", "any"}:
        raise SystemExit("TARGET_FAMILY must be ipv4 or any")


def route_v4(ip):
    subprocess.run(
        ["ip", "route", "replace", f"{ip}/32", "dev", WG_IF],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def resolve_target(host, port, socktype):
    family = socket.AF_INET if TARGET_FAMILY == "ipv4" else socket.AF_UNSPEC
    infos = socket.getaddrinfo(host, port, family, socktype)
    if not infos:
        raise RuntimeError(f"cannot resolve target {host}:{port}")
    infos.sort(key=lambda x: 0 if x[0] == socket.AF_INET else 1)
    af, _, _, _, sockaddr = infos[0]
    if af == socket.AF_INET:
        route_v4(sockaddr[0])
    return af, sockaddr, sockaddr[0]


def load_forwards():
    rows = []
    if not os.path.exists(CONFIG):
        return rows
    with open(CONFIG, newline="") as f:
        for row in csv.reader(f):
            if not row or row[0].strip().startswith("#"):
                continue
            row = [x.strip() for x in row]
            # Backward compatible formats:
            #   old: name,target_host,target_port,listen_port  (defaults to both)
            #   new: name,proto,target_host,target_port,listen_port
            if len(row) == 4:
                name, target_host, target_port, listen_port = row
                proto = "both"
            elif len(row) == 5:
                name, proto, target_host, target_port, listen_port = row
                proto = proto.lower()
            else:
                log("warning", f"skip invalid row: {row}")
                continue
            if proto not in {"tcp", "udp", "both"}:
                log("warning", f"skip invalid protocol {proto!r} in row: {row}")
                continue
            try:
                rows.append((name, proto, target_host, int(target_port), int(listen_port)))
            except ValueError:
                log("warning", f"skip row with non-integer port: {row}")
    return rows


def enabled_protocols(proto):
    return ("tcp", "udp") if proto == "both" else (proto,)


def recv_with_timeout(sock, size, timeout):
    readable, _, _ = select.select([sock], [], [], timeout)
    if not readable:
        raise TimeoutError("idle timeout")
    return sock.recv(size)


def tcp_pipe(client, target_host, target_port):
    upstream = None
    try:
        af, sockaddr, resolved_ip = resolve_target(target_host, target_port, socket.SOCK_STREAM)
        upstream = socket.socket(af, socket.SOCK_STREAM)
        upstream.settimeout(CONNECT_TIMEOUT)
        upstream.connect(sockaddr)
        upstream.settimeout(None)
        client.settimeout(None)
        log("info", f"TCP -> {target_host}:{target_port} resolved={resolved_ip}")

        sockets = [client, upstream]
        while not stop_event.is_set():
            readable, _, _ = select.select(sockets, [], [], TCP_IDLE_TIMEOUT)
            if not readable:
                raise TimeoutError("tcp idle timeout")
            for sock in readable:
                data = sock.recv(65536)
                if not data:
                    return
                peer = upstream if sock is client else client
                peer.sendall(data)
    except Exception as exc:
        log("debug", f"TCP end {target_host}:{target_port}: {exc}")
    finally:
        try:
            client.close()
        except Exception:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except Exception:
                pass
        tcp_sem.release()


def tcp_listener(target_host, target_port, listen_port):
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("::", listen_port))
    server.listen(1024)
    server.settimeout(1)
    log("info", f"TCP listen [::]:{listen_port} -> {target_host}:{target_port}")

    while not stop_event.is_set():
        try:
            client, addr = server.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        if not tcp_sem.acquire(blocking=False):
            log("warning", f"TCP limit reached, reject {addr}")
            try:
                client.close()
            except Exception:
                pass
            continue
        threading.Thread(target=tcp_pipe, args=(client, target_host, target_port), daemon=True).start()


class UDPRelay:
    def __init__(self, target_host, target_port, listen_port):
        self.target_host = target_host
        self.target_port = target_port
        self.listen_port = listen_port
        self.clients = {}
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        self.server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("::", listen_port))
        self.server.settimeout(1)

    def reserve_udp_client(self):
        global udp_total_clients
        with udp_total_lock:
            if udp_total_clients >= MAX_UDP_CLIENTS:
                return False
            udp_total_clients += 1
            return True

    def release_udp_client(self):
        global udp_total_clients
        with udp_total_lock:
            if udp_total_clients > 0:
                udp_total_clients -= 1

    def start(self):
        log("info", f"UDP listen [::]:{self.listen_port} -> {self.target_host}:{self.target_port}")
        threading.Thread(target=self.cleanup_loop, daemon=True).start()
        while not stop_event.is_set():
            try:
                data, client_addr = self.server.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            entry = self.get_or_create_client(client_addr)
            if entry is None:
                continue
            upstream = entry[0]
            try:
                upstream.send(data)
            except Exception as exc:
                log("debug", f"UDP send error {client_addr}: {exc}")
                self.drop_client(client_addr)

    def get_or_create_client(self, client_addr):
        with self.lock:
            entry = self.clients.get(client_addr)
            if entry is not None:
                entry[1] = time.time()
                return entry
        if not self.reserve_udp_client():
            log("warning", f"UDP limit reached, drop {client_addr}")
            return None
        try:
            af, sockaddr, resolved_ip = resolve_target(self.target_host, self.target_port, socket.SOCK_DGRAM)
            upstream = socket.socket(af, socket.SOCK_DGRAM)
            upstream.settimeout(1)
            upstream.connect(sockaddr)
            entry = [upstream, time.time()]
        except Exception as exc:
            self.release_udp_client()
            log("debug", f"UDP create upstream failed {client_addr}: {exc}")
            return None
        with self.lock:
            old = self.clients.get(client_addr)
            if old is not None:
                try:
                    upstream.close()
                except Exception:
                    pass
                self.release_udp_client()
                old[1] = time.time()
                return old
            self.clients[client_addr] = entry
        log("info", f"UDP {client_addr} -> {self.target_host}:{self.target_port} resolved={resolved_ip}")
        threading.Thread(target=self.reply_loop, args=(client_addr, upstream), daemon=True).start()
        return entry

    def reply_loop(self, client_addr, upstream):
        try:
            while not stop_event.is_set():
                try:
                    data = upstream.recv(65535)
                except socket.timeout:
                    continue
                if not data:
                    break
                self.server.sendto(data, client_addr)
        except Exception:
            pass
        self.drop_client(client_addr)

    def drop_client(self, client_addr):
        with self.lock:
            entry = self.clients.pop(client_addr, None)
        if entry is not None:
            try:
                entry[0].close()
            except Exception:
                pass
            self.release_udp_client()

    def cleanup_loop(self):
        while not stop_event.is_set():
            time.sleep(30)
            now = time.time()
            with self.lock:
                stale = [addr for addr, entry in self.clients.items() if now - entry[1] > UDP_IDLE_TIMEOUT]
            for addr in stale:
                self.drop_client(addr)
            if stale:
                log("debug", f"UDP cleaned {len(stale)} stale clients on :{self.listen_port}")


def metrics_loop():
    while not stop_event.is_set():
        time.sleep(60)
        with udp_total_lock:
            udp_count = udp_total_clients
        tcp_used = MAX_TCP_CONNECTIONS - tcp_sem._value  # best-effort runtime metric
        log("info", f"health tcp_active={tcp_used} udp_clients={udp_count} max_tcp={MAX_TCP_CONNECTIONS} max_udp={MAX_UDP_CLIENTS}")


def handle_signal(signum, frame):
    log("info", f"received signal {signum}, shutting down")
    stop_event.set()


def main():
    validate_runtime()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    rows = load_forwards()
    if not rows:
        log("warning", f"no forwarding config found: {CONFIG}")
        while not stop_event.is_set():
            time.sleep(60)
        return
    used_ports = set()
    for _, proto, target_host, target_port, listen_port in rows:
        for enabled_proto in enabled_protocols(proto):
            key = (enabled_proto, listen_port)
            if key in used_ports:
                raise SystemExit(f"duplicate {enabled_proto.upper()} listen port: {listen_port}")
            used_ports.add(key)
    for _, proto, target_host, target_port, listen_port in rows:
        if proto in {"tcp", "both"}:
            threading.Thread(target=tcp_listener, args=(target_host, target_port, listen_port), daemon=True).start()
        if proto in {"udp", "both"}:
            threading.Thread(target=UDPRelay(target_host, target_port, listen_port).start, daemon=True).start()
    threading.Thread(target=metrics_loop, daemon=True).start()
    while not stop_event.is_set():
        time.sleep(1)


if __name__ == "__main__":
    main()
PY

  chmod +x "$RELAY_BIN"

  cat > "$RELAY_SERVICE" <<EOF
[Unit]
Description=IPv6 TCP/UDP relay over WireGuard
After=network-online.target wg-quick@${WG_IF}.service
Wants=network-online.target wg-quick@${WG_IF}.service

[Service]
Type=simple
Environment=WG_IF=${WG_IF}
Environment=TARGET_FAMILY=${TARGET_FAMILY}
Environment=MAX_TCP_CONNECTIONS=${MAX_TCP_CONNECTIONS}
Environment=MAX_UDP_CLIENTS=${MAX_UDP_CLIENTS}
Environment=TCP_IDLE_TIMEOUT=${TCP_IDLE_TIMEOUT}
Environment=UDP_IDLE_TIMEOUT=${UDP_IDLE_TIMEOUT}
Environment=CONNECT_TIMEOUT=${CONNECT_TIMEOUT}
Environment=LOG_LEVEL=${LOG_LEVEL}
ExecStart=/usr/bin/python3 ${RELAY_BIN} ${FORWARDS}
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${CONF_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

cmd_keygen() {
  need_root
  require_deps
  ensure_key
  ensure_psk
  echo
  echo "WireGuard public key:"
  cat "${KEY_DIR}/publickey"
  echo
  echo "WireGuard preshared key (secret; use the same value on both relay and entry nodes):"
  cat "${KEY_DIR}/presharedkey"
  echo
}

cmd_genpsk() {
  need_root
  require_deps
  ensure_psk
  echo
  echo "WireGuard preshared key (secret; use the same value on both relay and entry nodes):"
  cat "${KEY_DIR}/presharedkey"
  echo
}

cmd_init_relay() {
  need_root
  require_deps
  ensure_key

  local entry_pub="" psk="" listen_port="$WG_PORT" wg_if="$WG_IF" relay_ip_cidr="$RELAY_WG_IP_CIDR" entry_ip="$ENTRY_WG_IP" wg_net="$WG_NET_V4"
  psk="$(default_psk)"

  while [ $# -gt 0 ]; do
    case "$1" in
      --entry-pub) entry_pub="$2"; shift 2;;
      --psk) psk="$2"; shift 2;;
      --no-psk) psk=""; shift;;
      --listen-port) listen_port="$2"; shift 2;;
      --wg-if) wg_if="$2"; shift 2;;
      --relay-wg-ip-cidr) relay_ip_cidr="$2"; shift 2;;
      --entry-wg-ip) entry_ip="$2"; shift 2;;
      --wg-net-v4) wg_net="$2"; shift 2;;
      --max-tcp-connections) MAX_TCP_CONNECTIONS="$2"; shift 2;;
      --max-udp-clients) MAX_UDP_CLIENTS="$2"; shift 2;;
      --log-level) LOG_LEVEL="$2"; shift 2;;
      *) echo "Unknown argument: $1" >&2; exit 1;;
    esac
  done

  if [ -t 0 ]; then
    echo
    echo "=== Relay node initialization ==="
    ask_validated wg_if "WireGuard interface name" "$wg_if" validate_iface
    ask_port listen_port "WireGuard UDP listen port" "$listen_port"
    ask_validated relay_ip_cidr "Relay node WireGuard address CIDR" "$relay_ip_cidr" validate_cidr "relay WireGuard address CIDR"
    ask_validated entry_ip "Entry node WireGuard IP without CIDR" "$entry_ip" validate_ip "entry WireGuard IP"
    ask_validated wg_net "WireGuard IPv4 subnet for NAT" "$wg_net" validate_ipv4_cidr "WireGuard IPv4 subnet"
    [ -n "$entry_pub" ] || ask_required_validated entry_pub "Entry node WireGuard public key" validate_wg_pubkey "entry public key"
    ask_optional_psk psk "WireGuard preshared key, optional" "$psk"
  elif [ -z "$entry_pub" ]; then
    echo "Missing --entry-pub" >&2
    exit 1
  fi

  validate_iface "$wg_if"
  validate_port "$listen_port" "listen port"
  validate_cidr "$relay_ip_cidr" "relay WireGuard address CIDR"
  validate_ip "$entry_ip" "entry WireGuard IP"
  validate_ipv4_cidr "$wg_net" "WireGuard IPv4 subnet"
  validate_wg_pubkey "$entry_pub" "entry public key"
  [ -z "$psk" ] || validate_wg_psk "$psk" "WireGuard preshared key"
  validate_runtime_limits
  save_psk "$psk"

  WG_IF="$wg_if"
  WG_PORT="$listen_port"
  RELAY_WG_IP_CIDR="$relay_ip_cidr"
  ENTRY_WG_IP="$entry_ip"
  WG_NET_V4="$wg_net"
  refresh_wg_conf

  save_config
  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${RELAY_WG_IP_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${KEY_DIR}/privatekey")
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -C POSTROUTING -s ${WG_NET_V4} -m comment --comment ${IPT_COMMENT} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NET_V4} -m comment --comment ${IPT_COMMENT} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET_V4} -m comment --comment ${IPT_COMMENT} -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${entry_pub}
EOF
  psk_line "$psk" >> "$WG_CONF"
  cat >> "$WG_CONF" <<EOF
AllowedIPs = ${ENTRY_WG_IP}/32
PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CONF"
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"

  echo
  echo "Relay WireGuard started: ${WG_IF} UDP/${WG_PORT}"
  echo "Relay public key:"
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_init_entry() {
  need_root
  require_deps
  ensure_key

  local relay_host="" relay_pub="" psk="" relay_port="$WG_PORT" wg_if="$WG_IF" entry_ip_cidr="$ENTRY_WG_IP_CIDR" allowed_ips="0.0.0.0/0"
  psk="$(default_psk)"

  while [ $# -gt 0 ]; do
    case "$1" in
      --relay-host) relay_host="$2"; shift 2;;
      --relay-pub) relay_pub="$2"; shift 2;;
      --psk) psk="$2"; shift 2;;
      --no-psk) psk=""; shift;;
      --relay-port) relay_port="$2"; shift 2;;
      --wg-if) wg_if="$2"; shift 2;;
      --entry-wg-ip-cidr) entry_ip_cidr="$2"; shift 2;;
      --allowed-ips) allowed_ips="$2"; shift 2;;
      --max-tcp-connections) MAX_TCP_CONNECTIONS="$2"; shift 2;;
      --max-udp-clients) MAX_UDP_CLIENTS="$2"; shift 2;;
      --tcp-idle-timeout) TCP_IDLE_TIMEOUT="$2"; shift 2;;
      --udp-idle-timeout) UDP_IDLE_TIMEOUT="$2"; shift 2;;
      --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2;;
      --log-level) LOG_LEVEL="$2"; shift 2;;
      --target-family) TARGET_FAMILY="$2"; shift 2;;
      *) echo "Unknown argument: $1" >&2; exit 1;;
    esac
  done

  if [ -t 0 ]; then
    echo
    echo "=== Entry node initialization ==="
    ask_validated wg_if "WireGuard interface name" "$wg_if" validate_iface
    ask_validated entry_ip_cidr "Entry node WireGuard address CIDR" "$entry_ip_cidr" validate_cidr "entry WireGuard address CIDR"
    [ -n "$relay_host" ] || ask_required_validated relay_host "Relay node address or DDNS hostname" validate_host
    ask_port relay_port "Relay WireGuard UDP port" "$relay_port"
    [ -n "$relay_pub" ] || ask_required_validated relay_pub "Relay node WireGuard public key" validate_wg_pubkey "relay public key"
    ask_optional_psk psk "WireGuard preshared key, optional" "$psk"
    ask_validated allowed_ips "AllowedIPs, default is usually recommended" "$allowed_ips" validate_allowed_ips
  elif [ -z "$relay_host" ] || [ -z "$relay_pub" ]; then
    echo "Missing --relay-host or --relay-pub" >&2
    exit 1
  fi

  validate_iface "$wg_if"
  validate_host "$relay_host"
  validate_port "$relay_port" "relay port"
  validate_cidr "$entry_ip_cidr" "entry WireGuard address CIDR"
  validate_wg_pubkey "$relay_pub" "relay public key"
  [ -z "$psk" ] || validate_wg_psk "$psk" "WireGuard preshared key"
  validate_allowed_ips "$allowed_ips"
  validate_runtime_limits
  save_psk "$psk"

  WG_IF="$wg_if"
  WG_PORT="$relay_port"
  ENTRY_WG_IP_CIDR="$entry_ip_cidr"
  refresh_wg_conf

  save_config
  install_relay
  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${ENTRY_WG_IP_CIDR}
PrivateKey = $(cat "${KEY_DIR}/privatekey")
Table = off

[Peer]
PublicKey = ${relay_pub}
EOF
  psk_line "$psk" >> "$WG_CONF"
  cat >> "$WG_CONF" <<EOF
Endpoint = $(endpoint "$relay_host" "$relay_port")
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CONF"
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"

  echo
  echo "Entry WireGuard started: ${WG_IF} -> $(endpoint "$relay_host" "$relay_port")"
  echo "Entry public key:"
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_add_target() {
  need_root
  require_deps
  ensure_dirs
  load_config
  validate_runtime_limits
  install_relay

  local proto="both" name="" target_host="" target_port="" listen_port="" tmp=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --proto) proto="$2"; shift 2;;
      *) break;;
    esac
  done

  if [ $# -eq 5 ]; then
    name="$1"
    proto="$2"
    target_host="$3"
    target_port="$4"
    listen_port="$5"
  elif [ $# -eq 4 ]; then
    name="$1"
    target_host="$2"
    target_port="$3"
    listen_port="$4"
  elif [ $# -eq 0 ] && [ -t 0 ]; then
    echo
    echo "=== Add forwarding target ==="
    ask_required_validated name "Target name" validate_target_name
    ask_proto proto "Protocol" "$proto"
    ask_required_validated target_host "Target host or IPv4" validate_host
    ask_port target_port "Target port" "54677"
    ask_port listen_port "Entry listen port" "$target_port"
  else
    echo "Usage: bash $0 add-target [--proto tcp|udp|both] <name> <target-host-or-ipv4> <target-port> <entry-listen-port>" >&2
    echo "   or: bash $0 add-target <name> <tcp|udp|both> <target-host-or-ipv4> <target-port> <entry-listen-port>" >&2
    echo "Example: bash $0 add-target --proto tcp target1 203.0.113.10 54677 54677" >&2
    echo "Example: bash $0 add-target target2 udp exit.example.com 54677 54678" >&2
    echo "Example: bash $0 add-target target3 203.0.113.10 54677 54679  # both TCP and UDP" >&2
    exit 1
  fi

  validate_target_name "$name"
  validate_proto "$proto"
  validate_host "$target_host"
  validate_port "$target_port" "target port"
  validate_port "$listen_port" "listen port"

  python3 - "$target_host" "$target_port" <<'PY'
import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
try:
    socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror as exc:
    print(
        f"Warning: cannot resolve IPv4 A record for {host}: {exc}\n"
        "Config will still be saved. The relay will try resolving on new connections.",
        file=sys.stderr,
    )
PY

  tmp="$(mktemp)"
  awk -F, -v name="$name" '$1 != name { print }' "$FORWARDS" > "$tmp"
  mv "$tmp" "$FORWARDS"
  echo "${name},${proto},${target_host},${target_port},${listen_port}" >> "$FORWARDS"

  systemctl enable --now wg-sdwan-port-relay.service
  systemctl restart wg-sdwan-port-relay.service

  echo
  echo "Added target:"
  echo "  name: ${name}"
  echo "  protocol: ${proto}"
  echo "  listen: [::]:${listen_port}"
  echo "  target: ${target_host}:${target_port}"
  echo
}

cmd_del_target() {
  need_root
  ensure_dirs
  load_config
  [ $# -eq 1 ] || { echo "Usage: bash $0 del-target <name>" >&2; exit 1; }
  validate_target_name "$1"

  local tmp=""
  tmp="$(mktemp)"
  awk -F, -v name="$1" '$1 != name { print }' "$FORWARDS" > "$tmp"
  mv "$tmp" "$FORWARDS"
  systemctl restart wg-sdwan-port-relay.service >/dev/null 2>&1 || true
  echo "Deleted target: $1"
}

cmd_list() {
  ensure_dirs
  echo
  echo "Current targets:"
  if [ -s "$FORWARDS" ]; then
    column -s, -t "$FORWARDS" 2>/dev/null || cat "$FORWARDS"
  else
    echo "None"
  fi
  echo
}

cmd_status() {
  load_config
  echo
  echo "WireGuard status:"
  wg show "$WG_IF" || true
  echo
  echo "Relay service status:"
  systemctl status wg-sdwan-port-relay.service --no-pager || true
  echo
  echo "Targets:"
  if [ -f "$FORWARDS" ]; then
    cat "$FORWARDS"
  else
    echo "None: ${FORWARDS}"
  fi
  echo
}

cmd_rollback() {
  need_root
  local yes=0 wg_if="$WG_IF" net="$WG_NET_V4"

  load_config
  wg_if="$WG_IF"
  net="$WG_NET_V4"

  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) yes=1; shift;;
      --wg-if) wg_if="$2"; shift 2;;
      --wg-net-v4) net="$2"; shift 2;;
      *) echo "Unknown argument: $1" >&2; exit 1;;
    esac
  done

  validate_iface "$wg_if"
  validate_ipv4_cidr "$net" "WireGuard IPv4 subnet"

  echo
  echo "Rollback will remove this installation from this machine:"
  echo "  WireGuard interface: ${wg_if}"
  echo "  WireGuard config: /etc/wireguard/${wg_if}.conf"
  echo "  Relay config dir: ${CONF_DIR}"
  echo "  Relay service: ${RELAY_SERVICE}"
  echo "  Relay binary: ${RELAY_BIN}"
  echo "  NAT source subnet: ${net}"
  echo

  if [ "$yes" -ne 1 ]; then
    confirm_or_exit "Type YES to continue"
  fi

  systemctl disable --now wg-sdwan-port-relay.service >/dev/null 2>&1 || true
  systemctl disable --now "wg-quick@${wg_if}.service" >/dev/null 2>&1 || true
  wg-quick down "$wg_if" >/dev/null 2>&1 || true
  ip link del "$wg_if" >/dev/null 2>&1 || true

  while iptables -t nat -D POSTROUTING -s "$net" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1; do :; done

  rm -f "$RELAY_BIN" "$RELAY_SERVICE" "/etc/wireguard/${wg_if}.conf"
  rm -rf "$CONF_DIR" /var/lib/wg-sdwan-port-relay /var/backups/wg-sdwan-port-relay

  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "Rollback completed."
}

usage() {
  cat <<EOF
Usage:
  bash $0 check
  bash $0 install-deps
  bash $0 keygen        # generates local WireGuard key pair and PSK
  bash $0 genpsk        # prints/saves the local PSK, creating it if missing

  bash $0 init-relay
  bash $0 init-entry

  bash $0 add-target       # interactive
  bash $0 add-target target1 203.0.113.10 54677 54677
  bash $0 add-target --proto tcp target2 exit.example.com 54677 54678
  bash $0 add-target target3 udp exit.example.com 54677 54679
  bash $0 del-target target1
  bash $0 list-targets
  bash $0 status

  bash $0 rollback

Non-interactive examples:
  bash $0 init-relay \\
    --entry-pub <ENTRY_PUBLIC_KEY> \\
    --psk <PRESHARED_KEY_FROM_KEYGEN> \\
    --listen-port 51820 \\
    --wg-if wg-sdwan \\
    --relay-wg-ip-cidr 10.233.233.1/24 \\
    --entry-wg-ip 10.233.233.2 \\
    --wg-net-v4 10.233.233.0/24

  bash $0 init-entry \\
    --relay-host sdwan.example.com \\
    --relay-pub <RELAY_PUBLIC_KEY> \\
    --psk <PRESHARED_KEY_FROM_KEYGEN> \\
    --relay-port 51820 \\
    --wg-if wg-sdwan \\
    --entry-wg-ip-cidr 10.233.233.2/24 \\
    --allowed-ips 0.0.0.0/0

Optional relay limits on entry node:
  --max-tcp-connections 1024
  --max-udp-clients 4096
  --tcp-idle-timeout 300
  --udp-idle-timeout 180
  --connect-timeout 15
  --log-level info
  --target-family ipv4

PSK behavior:
  keygen creates ${KEY_DIR}/presharedkey and prints it.
  init-relay/init-entry use that saved PSK by default when present.
  Use --psk <value> to provide/save a PSK manually, or --no-psk to omit it.

Target protocol selection:
  bash $0 add-target --proto tcp target1 203.0.113.10 54677 54677
  bash $0 add-target --proto udp target2 203.0.113.10 54677 54678
  bash $0 add-target --proto both target3 203.0.113.10 54677 54679

Compatibility aliases:
  init-sdwan      -> init-relay
  init-a          -> init-entry
  add-exit        -> add-target
  del-exit        -> del-target
  list-exits      -> list-targets
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  check) cmd_check "$@";;
  install-deps) cmd_install_deps "$@";;
  keygen) cmd_keygen "$@";;
  genpsk|pskgen) cmd_genpsk "$@";;
  init-relay|init-sdwan) cmd_init_relay "$@";;
  init-entry|init-a) cmd_init_entry "$@";;
  add-target|add-exit) cmd_add_target "$@";;
  del-target|del-exit) cmd_del_target "$@";;
  list-targets|list-exits) cmd_list "$@";;
  status) cmd_status "$@";;
  rollback) cmd_rollback "$@";;
  *) usage;;
esac
