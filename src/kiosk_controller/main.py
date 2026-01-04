#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import http.client
import ipaddress
import json
import logging
import logging.handlers
import os
import random
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, get_args, get_origin, get_type_hints
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# ----------------------------
# Konfiguration
# ----------------------------

@dataclasses.dataclass(frozen=True)
class Config:
    #Router
    router_port: int = 8765
    
    # AIDA
    aida_port: int = 1111
    aida_health_path: str = "/api?sensors=STIME"
    check_interval_sec: float = 2.0

    # Hysterese gegen Flapping
    fails_to_down: int = 3
    oks_to_up: int = 2

    # Recovery: nach erstem Fail diese Zeit nur letzte IP probieren
    recovery_window_sec: float = 12.0

    # Discovery
    discovery_budget_sec: float = 10.0
    discovery_cooldown_sec: float = 90.0
    discovery_workers: int = 64  # wird intern begrenzt

    # Timeouts (Healthcheck)
    connect_timeout_sec: float = 0.45
    read_timeout_sec: float = 0.75  # bei http.client zusammengefasst

    # Firefox / Watchdog
    firefox_startup_grace_sec: float = 10.0
    firefox_kill_timeout_sec: float = 4.0
    nav_cooldown_sec: float = 2.0
    nav_fails_to_restart: int = 3
    window_missing_to_restart_sec: float = 20.0

    # Pfade
    cache_dir: Path = Path.home() / ".cache" / "aida64"
    cache_file: Path = Path.home() / ".cache" / "aida64" / "target_ips.json"
    profile_dir: Path = Path.home() / ".mozilla" / "kiosk-profile"
    splash_file: Path = Path.home() / ".cache" / "aida64" / "loading.html"
    log_file: Path = Path.home() / ".cache" / "aida64" / "kiosk_controller.log"

    # X defaults
    default_display: str = ":0"
    default_xauthority: Path = Path.home() / ".Xauthority"

    # Optional: spätere Erweiterung
    panel_title_token: str = "AIDA64 RemoteSensor"


@dataclasses.dataclass
class State:
    mode: str = "DOWN"  # "UP" / "DOWN"
    target_ip: Optional[str] = None

    ok_streak: int = 0
    fail_streak: int = 0

    down_since: Optional[float] = None
    last_discovery_ts: float = 0.0


# ----------------------------
# Logging
# ----------------------------

LOG = logging.getLogger("kiosk")


def setup_logging(cfg: Config) -> logging.Logger:
    logger = logging.getLogger("kiosk")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    fmt = logging.Formatter("[%(asctime)s] %(message)s", "%Y-%m-%d %H:%M:%S")

    # log_file kann Path oder str sein (JSON liefert typischerweise str)
    log_file = getattr(cfg, "log_file", None)

    if log_file:
        try:
            log_path = log_file if isinstance(log_file, Path) else Path(str(log_file))
            log_path.parent.mkdir(parents=True, exist_ok=True)

            fh = logging.handlers.RotatingFileHandler(
                log_path, maxBytes=512_000, backupCount=3, encoding="utf-8"
            )
            fh.setFormatter(fmt)
            logger.addHandler(fh)
        except Exception as e:
            # Logging darf niemals den Prozess killen
            # (stdout bleibt aktiv)
            pass

    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    logger.propagate = False
    return logger


@dataclasses.dataclass
class RouterState:
    mode: str = "DOWN"           # "UP"/"DOWN"
    target_ip: Optional[str] = None
    url: str = ""                # Ziel-URL fürs Panel (nur sinnvoll bei UP)
    ts: float = 0.0              # last update (time.time())

class Router:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._lock = threading.Lock()
        self._state = RouterState()

    def update(self, mode: str, target_ip: Optional[str], url: str) -> None:
        with self._lock:
            self._state.mode = mode
            self._state.target_ip = target_ip
            self._state.url = url
            self._state.ts = time.time()

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "mode": self._state.mode,
                "target_ip": self._state.target_ip,
                "url": self._state.url,
                "ts": self._state.ts,
            }

def start_router_server(cfg: Config, router: Router) -> None:
    splash_html = None
    try:
        # Wenn du deine bestehende Splash-Datei weiterverwenden willst:
        splash_html = cfg.splash_file.read_text(encoding="utf-8")
    except Exception:
        splash_html = "<html><body style='background:#000;color:#fff;font-family:sans-serif'>Loading…</body></html>"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            # optional: HTTP-Requests nicht ins Journal spammen
            return

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/" or self.path.startswith("/?"):
                html = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Golden Plate Router</title>
  <style>
    html,body {{ height:100%; margin:0; background:#000; color:#fff; font-family:sans-serif; }}
    #bar {{ position:fixed; top:0; left:0; right:0; padding:6px 10px; font-size:14px; background:rgba(0,0,0,0.6); z-index:2; }}
    #frame {{ position:absolute; top:0; left:0; width:100%; height:100%; border:0; }}
  </style>
</head>
<body>
  <div id="bar">Status: <span id="st">?</span> <span id="ip"></span></div>
  <iframe id="frame" src="/splash"></iframe>

  <script>
    const st = document.getElementById('st');
    const ip = document.getElementById('ip');
    const frame = document.getElementById('frame');
    let lastSrc = "";

    async function poll() {{
      try {{
        const r = await fetch('/state.json', {{cache:'no-store'}});
        const s = await r.json();

        st.textContent = s.mode || '?';
        ip.textContent = s.target_ip ? ('(' + s.target_ip + ')') : '';

        let desired = '/splash';
        if (s.mode === 'UP' && s.url) desired = s.url;

        // Nur umschalten wenn es wirklich geändert hat:
        if (desired !== lastSrc) {{
          lastSrc = desired;
          frame.src = desired;
        }}
      }} catch (e) {{
        st.textContent = 'ERR';
        ip.textContent = '';
        // fallback: splash lassen
      }}
    }}

    poll();
    setInterval(poll, 1000);
  </script>
</body>
</html>
"""
                self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")
                return

            if self.path == "/state.json":
                body = json.dumps(router.snapshot()).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
                return

            if self.path == "/splash":
                self._send(200, splash_html.encode("utf-8"), "text/html; charset=utf-8")
                return

            self._send(404, b"not found", "text/plain; charset=utf-8")

    srv = ThreadingHTTPServer(("127.0.0.1", int(cfg.router_port)), Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    
    
    
# ----------------------------
# Helpers
# ----------------------------

@dataclasses.dataclass(frozen=True)
class CmdResult:
    rc: int
    out: str
    err: str


def run_cmd(cmd: List[str], timeout: float = 5.0, env: Optional[Dict[str, str]] = None) -> CmdResult:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return CmdResult(p.returncode, p.stdout, p.stderr)
    except Exception as e:
        return CmdResult(999, "", str(e))


def which_any(candidates: List[str]) -> Optional[str]:
    for c in candidates:
        p = shutil.which(c)
        if p:
            return p
    return None


def x_env(cfg: Config) -> Dict[str, str]:
    env = os.environ.copy()
    env.setdefault("DISPLAY", cfg.default_display)
    env.setdefault("XAUTHORITY", str(cfg.default_xauthority))
    return env


def atomic_write_text(path: Path, text: str, encoding: str = "utf-8") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding=encoding)
    tmp.replace(path)


def ensure_splash_file(cfg: Config) -> None:
    cfg.cache_dir.mkdir(parents=True, exist_ok=True)
    if cfg.splash_file.exists():
        return
    html = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="30">
  <title>Loading…</title>
  <style>
    html,body { height:100%; margin:0; background:#000; color:#fff; font-family: sans-serif; }
    .wrap { height:100%; display:flex; align-items:center; justify-content:center; flex-direction:column; gap:14px; }
    .spinner {
      width: 48px; height: 48px; border: 4px solid rgba(255,255,255,0.25);
      border-top-color: rgba(255,255,255,0.9); border-radius: 50%;
      animation: spin 1s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .small { opacity: 0.8; font-size: 14px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="spinner"></div>
    <div>Panel wird verbunden…</div>
    <div class="small">Bitte warten</div>
  </div>
</body>
</html>
"""
    cfg.splash_file.write_text(html, encoding="utf-8")


# ----------------------------
# Config Laden: Datei + Env-Overrides
# ----------------------------

_ENV_MAP: Dict[str, str] = {
    # Router
    "KIOSK_ROUTER_PORT": "router_port",
    # AIDA / Loop
    "KIOSK_AIDA_PORT": "aida_port",
    "KIOSK_AIDA_HEALTH_PATH": "aida_health_path",
    "KIOSK_CHECK_INTERVAL_SEC": "check_interval_sec",
    # Hysterese/Recovery
    "KIOSK_FAILS_TO_DOWN": "fails_to_down",
    "KIOSK_OKS_TO_UP": "oks_to_up",
    "KIOSK_RECOVERY_WINDOW_SEC": "recovery_window_sec",
    # Discovery
    "KIOSK_DISCOVERY_BUDGET_SEC": "discovery_budget_sec",
    "KIOSK_DISCOVERY_COOLDOWN_SEC": "discovery_cooldown_sec",
    "KIOSK_DISCOVERY_WORKERS": "discovery_workers",
    # Timeouts
    "KIOSK_CONNECT_TIMEOUT_SEC": "connect_timeout_sec",
    "KIOSK_READ_TIMEOUT_SEC": "read_timeout_sec",
    # Firefox
    "KIOSK_FIREFOX_STARTUP_GRACE_SEC": "firefox_startup_grace_sec",
    "KIOSK_FIREFOX_KILL_TIMEOUT_SEC": "firefox_kill_timeout_sec",
    "KIOSK_NAV_COOLDOWN_SEC": "nav_cooldown_sec",
    "KIOSK_NAV_FAILS_TO_RESTART": "nav_fails_to_restart",
    "KIOSK_WINDOW_MISSING_TO_RESTART_SEC": "window_missing_to_restart_sec",
    # Pfade
    "KIOSK_CACHE_DIR": "cache_dir",
    "KIOSK_CACHE_FILE": "cache_file",
    "KIOSK_PROFILE_DIR": "profile_dir",
    "KIOSK_SPLASH_FILE": "splash_file",
    "KIOSK_LOG_FILE": "log_file",
    # X
    "KIOSK_DISPLAY": "default_display",
    "KIOSK_XAUTHORITY": "default_xauthority",
}


def _coerce_value(field_type: Any, value: Any) -> Any:
    # Optional/Union behandeln (z.B. Optional[Path])
    origin = get_origin(field_type)
    if origin is not None:
        args = [a for a in get_args(field_type) if a is not type(None)]
        # Wenn Union/Optional genau einen sinnvollen Typ enthält, darauf reduzieren
        if len(args) == 1:
            field_type = args[0]

    if field_type is Path:
        return Path(str(value))
    if field_type is int:
        return int(value)
    if field_type is float:
        return float(value)
    if field_type is str:
        return str(value)
    return value

def normalize_loaded_config(data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Einmalige Normalisierung: JSON/Env liefern Strings -> wir wandeln anhand der
    echten (aufgelösten) Typ-Hints von Config.
    """
    try:
        hints = get_type_hints(Config)  # löst Future-Annotations zu echten Typen auf
    except Exception:
        return {}
    
    out: Dict[str, Any] = {}
    for k, v in data.items():
        if k not in hints:
            continue
        try:
            out[k] = _coerce_value(hints[k], v)
        except Exception:
            # bewusst ignorieren: invalides Feld soll Config nicht killen
            pass
    return out    

def apply_overrides(cfg: Config, overrides: Dict[str, Any]) -> Config:
    updates = normalize_loaded_config(overrides)
    return dataclasses.replace(cfg, **updates) if updates else cfg


def load_config_file(path: Path) -> Dict[str, Any]:
    try:
        if not path.exists():
            return {}
        raw = path.read_text(encoding="utf-8")
        data = json.loads(raw)
        if not isinstance(data, dict):
            return {}
        return normalize_loaded_config(data)
    except Exception:
        return {}


def load_env_overrides() -> Dict[str, Any]:
    ov: Dict[str, Any] = {}
    for env_key, field_name in _ENV_MAP.items():
        if env_key in os.environ and os.environ[env_key] != "":
            ov[field_name] = os.environ[env_key]
    return normalize_loaded_config(ov)


def resolve_config(config_path: Optional[str]) -> tuple[Config, Optional[Path]]:
    cfg = Config()
    used_path: Optional[Path] = None

    if config_path:
        used_path = Path(config_path)
        cfg = apply_overrides(cfg, load_config_file(used_path))
    else:
        default_path = Path("/etc/kiosk-controller.json")
        if default_path.exists():
            used_path = default_path
            cfg = apply_overrides(cfg, load_config_file(default_path))

    cfg = apply_overrides(cfg, load_env_overrides())
    return cfg, used_path


# ----------------------------
# Cache
# ----------------------------

class TargetCache:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    def load_ips(self, max_n: int = 5) -> List[str]:
        try:
            if not self.cfg.cache_file.exists():
                return []
            data = json.loads(self.cfg.cache_file.read_text(encoding="utf-8"))
            cand = data.get("candidates", [])
            cand.sort(key=lambda x: int(x.get("last_ok", 0)), reverse=True)
            ips = [c.get("ip") for c in cand if c.get("ip")]
            seen = set()
            out: List[str] = []
            for ip in ips:
                if ip not in seen:
                    seen.add(ip)
                    out.append(ip)
            return out[:max_n]
        except Exception:
            return []

    def save_ok_ip(self, ip: str, max_n: int = 5) -> None:
        now = int(time.time())
        existing: List[dict] = []
        try:
            if self.cfg.cache_file.exists():
                data = json.loads(self.cfg.cache_file.read_text(encoding="utf-8"))
                existing = data.get("candidates", [])
        except Exception:
            existing = []

        new: List[dict] = [{"ip": ip, "last_ok": now}]
        seen = {ip}
        for item in existing:
            old_ip = item.get("ip")
            if not old_ip or old_ip in seen:
                continue
            new.append({"ip": old_ip, "last_ok": int(item.get("last_ok", 0))})
            seen.add(old_ip)

        atomic_write_text(self.cfg.cache_file, json.dumps({"candidates": new[:max_n]}, indent=2))


# ----------------------------
# Network / Discovery
# ----------------------------

def get_default_iface_and_cidr() -> Optional[ipaddress.IPv4Network]:
    r1 = run_cmd(["ip", "-j", "route", "get", "1.1.1.1"], timeout=2.0)
    if r1.rc != 0 or not r1.out.strip():
        return None
    try:
        route = json.loads(r1.out)[0]
        dev = route.get("dev")
        if not dev:
            return None
    except Exception:
        return None

    r2 = run_cmd(["ip", "-j", "addr", "show", "dev", dev], timeout=2.0)
    if r2.rc != 0 or not r2.out.strip():
        return None
    try:
        info = json.loads(r2.out)[0]
        for a in info.get("addr_info", []):
            if a.get("family") == "inet":
                local = a.get("local")
                prefixlen = a.get("prefixlen")
                if local and prefixlen is not None:
                    return ipaddress.IPv4Network(f"{local}/{prefixlen}", strict=False)
    except Exception:
        return None
    return None


def ip_neigh_candidates() -> List[str]:
    r = run_cmd(["ip", "-j", "neigh", "show"], timeout=2.0)
    if r.rc != 0 or not r.out.strip():
        return []
    try:
        items = json.loads(r.out)
    except Exception:
        return []
    ips: List[str] = []
    for it in items:
        dst = it.get("dst")
        if isinstance(dst, str):
            ips.append(dst)

    seen = set()
    out: List[str] = []
    for ip in ips:
        if ip not in seen:
            seen.add(ip)
            out.append(ip)
    return out


# ----------------------------
# Healthcheck
# ----------------------------

def http_healthcheck(cfg: Config, ip: str) -> bool:
    timeout = max(0.1, cfg.connect_timeout_sec + cfg.read_timeout_sec)
    conn: Optional[http.client.HTTPConnection] = None
    try:
        conn = http.client.HTTPConnection(ip, cfg.aida_port, timeout=timeout)
        conn.request(
            "GET",
            cfg.aida_health_path,
            headers={
                "Host": f"{ip}:{cfg.aida_port}",
                "Connection": "close",
                "User-Agent": "kiosk-controller/2.1",
            },
        )
        resp = conn.getresponse()
        return resp.status == 200
    except Exception:
        return False
    finally:
        try:
            if conn:
                conn.close()
        except Exception:
            pass


def bounded_discovery(cfg: Config, network: ipaddress.IPv4Network, extra_candidates: List[str]) -> Optional[str]:
    budget_end = time.time() + cfg.discovery_budget_sec

    base: List[str] = []
    seen = set()
    for ip in extra_candidates:
        try:
            ipaddress.IPv4Address(ip)
            if ip not in seen:
                seen.add(ip)
                base.append(ip)
        except Exception:
            pass

    all_hosts = [str(h) for h in network.hosts()]
    random.shuffle(all_hosts)
    scan_list = base + [ip for ip in all_hosts if ip not in seen]

    workers = min(cfg.discovery_workers, (os.cpu_count() or 2) * 8)

    def check_one(ip: str) -> Optional[str]:
        if time.time() > budget_end:
            return None
        return ip if http_healthcheck(cfg, ip) else None

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futures: List[concurrent.futures.Future] = []

        for ip in scan_list:
            if time.time() > budget_end:
                break
            futures.append(ex.submit(check_one, ip))

        try:
            for fut in concurrent.futures.as_completed(futures, timeout=max(0.1, cfg.discovery_budget_sec)):
                if time.time() > budget_end:
                    break
                try:
                    hit = fut.result()
                    if hit:
                        for f in futures:
                            f.cancel()
                        return hit
                except Exception:
                    pass
        except Exception:
            pass

    return None


# ----------------------------
# X11 / Firefox Control
# ----------------------------

def find_firefox_window_id(cfg: Config, wait_sec: float = 0.0) -> Optional[str]:
    env = x_env(cfg)

    # 1) wmctrl wie bisher (wenn es bei dir mal geht)
    if shutil.which("wmctrl"):
        r = run_cmd(["wmctrl", "-lx"], timeout=2.0, env=env)
        if r.rc == 0 and r.out.strip():
            for line in r.out.splitlines():
                if "firefox" in line.lower():
                    parts = line.split()
                    if parts:
                        return parts[0]

    # 2) Fallback: xdotool (liefert bei dir 6291499)
    if shutil.which("xdotool"):
        for cls in ("firefox", "firefox-esr", "Navigator"):
            r = run_cmd(["xdotool", "search", "--onlyvisible", "--class", cls], timeout=2.0, env=env)
            if r.rc == 0 and r.out.strip():
                return r.out.split()[0]

    return None


def pgrep_profile(profile_dir: Path) -> List[int]:
    r = run_cmd(["pgrep", "-f", str(profile_dir)], timeout=2.0)
    if r.rc != 0 or not r.out.strip():
        return []
    pids: List[int] = []
    for s in r.out.split():
        try:
            pids.append(int(s))
        except Exception:
            pass
    return pids


def firefox_kill(cfg: Config) -> None:
    pids = pgrep_profile(cfg.profile_dir)
    if not pids:
        return
    LOG.info(f"Beende Firefox (Profil-PIDs): {pids}")
    run_cmd(["pkill", "-TERM", "-f", str(cfg.profile_dir)], timeout=2.0)
    t_end = time.time() + cfg.firefox_kill_timeout_sec
    while time.time() < t_end:
        if not pgrep_profile(cfg.profile_dir):
            return
        time.sleep(0.2)
    run_cmd(["pkill", "-KILL", "-f", str(cfg.profile_dir)], timeout=2.0)


class FirefoxController:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.firefox_path = which_any(["firefox-esr", "firefox"])

        self.last_start_ts = 0.0
        self.last_nav_ts = 0.0
        self.last_url: Optional[str] = None

        self.nav_fail_streak = 0
        self.window_missing_since: Optional[float] = None

    def is_running(self) -> bool:
        return bool(pgrep_profile(self.cfg.profile_dir))

    def has_window(self) -> bool:
        return find_firefox_window_id(self.cfg) is not None

    def start(self, url: str) -> bool:
        if not self.firefox_path:
            LOG.error("ERROR: firefox/firefox-esr nicht gefunden.")
            return False
        self.cfg.profile_dir.mkdir(parents=True, exist_ok=True)

        env = x_env(self.cfg)
        cmd = [self.firefox_path, "--kiosk", "--profile", str(self.cfg.profile_dir), url]
        try:
            subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.last_start_ts = time.time()
            self.last_url = url
            self.last_nav_ts = time.time()
            self.nav_fail_streak = 0
            self.window_missing_since = None
            LOG.info(f"Firefox gestartet: {url}")
            return True
        except Exception as e:
            LOG.error(f"ERROR: Firefox-Start fehlgeschlagen: {e}")
            return False

    def restart(self, url: str) -> None:
        LOG.info("Firefox Neustart (watchdog)")
        firefox_kill(self.cfg)
        time.sleep(0.5)
        self.start(url)

    def ensure_running(self, base_url: str) -> None:
        if not self.is_running():
            self.start(base_url)
            return

        if (time.time() - self.last_start_ts) > self.cfg.firefox_startup_grace_sec:
            if not self.has_window():
                if self.window_missing_since is None:
                    self.window_missing_since = time.time()
                elif (time.time() - self.window_missing_since) > self.cfg.window_missing_to_restart_sec:
                    LOG.info("Firefox läuft, aber kein Fenster -> Neustart")
                    self.restart(base_url)
                    return
            else:
                self.window_missing_since = None



# ----------------------------
# Kiosk Controller
# ----------------------------

class KioskController:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        ensure_splash_file(cfg)

        self.fx = FirefoxController(cfg)
        self.cache = TargetCache(cfg)
        self.state = State()

        self.router = Router(cfg)
        start_router_server(cfg, self.router)
        self.router_url = f"http://127.0.0.1:{cfg.router_port}/"

        self.net: Optional[ipaddress.IPv4Network] = get_default_iface_and_cidr()

        cached = self.cache.load_ips(max_n=5)
        self.state.target_ip = cached[0] if cached else None

        LOG.info(f"Netz erkannt: {self.net if self.net else 'unbekannt'}")
        LOG.info(f"Cache IPs: {cached if cached else 'keine'}")
        LOG.info(f"Splash: {cfg.splash_file}")
        LOG.info(f"Router: {self.router_url}")

    def panel_url(self) -> str:
        if self.state.mode == "UP" and self.state.target_ip:
            return f"http://{self.state.target_ip}:{self.cfg.aida_port}/"
        return ""  # DOWN -> Router zeigt /splash

    def tick(self) -> None:
        ok = False
        if self.state.target_ip:
            ok = http_healthcheck(self.cfg, self.state.target_ip)

        if ok:
            self.state.ok_streak += 1
            self.state.fail_streak = 0
        else:
            self.state.fail_streak += 1
            self.state.ok_streak = 0

        next_mode = self.state.mode
        if self.state.fail_streak >= self.cfg.fails_to_down:
            next_mode = "DOWN"
        elif self.state.ok_streak >= self.cfg.oks_to_up:
            next_mode = "UP"

        if next_mode != self.state.mode:
            self.on_mode_change(next_mode)

        if self.state.mode == "DOWN":
            self.maybe_discover()
        else:
            if self.state.target_ip:
                self.cache.save_ok_ip(self.state.target_ip, max_n=5)

        # 1) Router-State setzen
        self.router.update(self.state.mode, self.state.target_ip, self.panel_url())

        # 2) Firefox am Leben halten (immer Router-URL)
        self.fx.ensure_running(self.router_url)

    def run(self) -> None:
        LOG.info("Kiosk Controller startet.")
        self.router.update("DOWN", self.state.target_ip, "")
        self.fx.ensure_running(self.router_url)

        if self.state.target_ip:
            LOG.info(f"Starte mit Cache-IP: {self.state.target_ip}")

        while True:
            try:
                self.tick()
            except Exception as e:
                LOG.error(f"ERROR (tick): {e}")
            time.sleep(self.cfg.check_interval_sec)

# ----------------------------
# Main / Signal Handling
# ----------------------------

_ACTIVE_CFG: Optional[Config] = None


def _handle_term(signum: int, frame) -> None:
    LOG.info(f"Signal {signum} erhalten, beende…")
    try:
        if _ACTIVE_CFG:
            firefox_kill(_ACTIVE_CFG)
    except Exception:
        pass
    raise SystemExit(0)


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="kiosk-controller")
    p.add_argument(
        "--config",
        default=os.environ.get("KIOSK_CONFIG", None),
        help="Pfad zur JSON-Konfiguration (Default: env KIOSK_CONFIG oder /etc/kiosk-controller.json falls vorhanden)",
    )
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    cfg, used_path = resolve_config(args.config)

    global LOG, _ACTIVE_CFG
    LOG = setup_logging(cfg)
    _ACTIVE_CFG = cfg

    if used_path:
        LOG.info(f"Konfiguration geladen aus: {used_path}")
    else:
        LOG.info("Keine Config-Datei verwendet (Defaults/Env).")

    if not shutil.which("ip"):
        LOG.error("ERROR: ip (iproute2) fehlt.")
        return 2
    if not shutil.which("wmctrl"):
        LOG.warning("WARN: wmctrl fehlt (Fenster-Checks eingeschränkt). apt install wmctrl")
    if not shutil.which("xdotool"):
        LOG.warning("WARN: xdotool fehlt (Navigation ohne Restart nicht möglich). apt install xdotool")

    if not os.environ.get("DISPLAY"):
        LOG.warning(f"WARN: DISPLAY nicht gesetzt (erwartet {cfg.default_display}).")
    if not os.environ.get("XAUTHORITY"):
        LOG.warning(f"WARN: XAUTHORITY nicht gesetzt (erwartet {cfg.default_xauthority}).")

    signal.signal(signal.SIGTERM, _handle_term)
    signal.signal(signal.SIGINT, _handle_term)

    ensure_splash_file(cfg)
    KioskController(cfg).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
