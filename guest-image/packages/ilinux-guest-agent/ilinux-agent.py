#!/usr/bin/env python3
import json, os, sys, time, uuid, signal, threading, subprocess

PORT = os.environ.get("ILINUX_AGENT_PORT", "/dev/vport0p1")
PROTO_VERSION = 1
RECONNECT_DELAY = 2.0

def log(*args):
    print("[ilinux-agent]", *args, file=sys.stderr, flush=True)

class Channel:
    def __init__(self, path):
        self.path = path
        self.fh = None
        self._wlock = threading.Lock()

    def open(self):
        self.fh = open(self.path, "r+b", buffering=0)

    def send(self, msg):
        line = (json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8")
        with self._wlock:
            self.fh.write(line)

    def lines(self):
        buf = b""
        while True:
            chunk = self.fh.read(4096)
            if not chunk:
                time.sleep(0.05)
                continue
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    yield json.loads(raw.decode("utf-8"))
                except Exception as e:
                    log("bad message:", e)

class Agent:
    def __init__(self, channel):
        self.ch = channel
        self.sensors = {}
        self.handlers = {
            "hello": self.on_hello,
            "clipboard.push": self.on_clipboard_push,
            "clipboard.request": self.on_clipboard_request,
            "net.status": self.on_net_status,
            "sensors.update": self.on_sensors_update,
            "files.shared": self.on_files_shared,
            "ping": self.on_ping,
        }

    def emit(self, type_, data=None, mid=None):
        self.ch.send({
            "v": PROTO_VERSION,
            "type": type_,
            "id": mid or str(uuid.uuid4()),
            "data": data or {},
        })

    def announce(self):
        try:
            with open("/etc/os-release") as f:
                distro = next((l.split("=",1)[1].strip().strip('"')
                    for l in f if l.startswith("PRETTY_NAME=")), "unknown")
        except OSError:
            distro = "unknown"
        self.emit("guest.hello", {
            "agent": "ilinux-guest-agent",
            "proto": PROTO_VERSION,
            "distro": distro,
            "kernel": os.uname().release,
            "arch": os.uname().machine,
        })

    def on_hello(self, msg): self.announce()
    def on_ping(self, msg): self.emit("pong", {"t": time.time()}, mid=msg.get("id"))
    def on_net_status(self, msg): log("net:", msg.get("data"))
    def on_files_shared(self, msg): log("file shared:", msg.get("data", {}).get("name"))

    def on_clipboard_push(self, msg):
        text = msg.get("data", {}).get("text", "")
        for cmd in (["wl-copy"], ["xclip", "-selection", "clipboard"]):
            try:
                if subprocess.run(cmd, input=text.encode(), timeout=2).returncode == 0:
                    return
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue
        try:
            os.makedirs("/run/ilinux", exist_ok=True)
            open("/run/ilinux/clipboard","w").write(text)
        except OSError: pass

    def on_clipboard_request(self, msg):
        text = ""
        for cmd in (["wl-paste","-n"], ["xclip","-selection","clipboard","-o"]):
            try:
                p = subprocess.run(cmd, capture_output=True, timeout=2)
                if p.returncode == 0:
                    text = p.stdout.decode("utf-8","replace"); break
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue
        self.emit("clipboard.value", {"text": text}, mid=msg.get("id"))

    def on_sensors_update(self, msg):
        self.sensors = msg.get("data", {})
        try:
            os.makedirs("/run/ilinux", exist_ok=True)
            with open("/run/ilinux/sensors.json","w") as f:
                json.dump(self.sensors, f)
        except OSError: pass

    def run(self):
        self.announce()
        for msg in self.ch.lines():
            handler = self.handlers.get(msg.get("type"))
            if handler:
                try: handler(msg)
                except Exception as e: log("error:", e)

def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        try:
            ch = Channel(PORT)
            ch.open()
            log("connected on", PORT)
            Agent(ch).run()
        except Exception as e:
            log("error:", e)
        time.sleep(RECONNECT_DELAY)

if __name__ == "__main__":
    main()
