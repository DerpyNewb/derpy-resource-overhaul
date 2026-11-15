"""Stdio MCP bridge to RPFM's rpfm_server that starts the server headless when nothing is
listening, so the RPFM tools exist without the RPFM window open.

    py tools/rpfm_mcp_bridge.py                 # stdio MCP server - what .mcp.json runs
    py tools/rpfm_mcp_bridge.py status          # UP/down, who started it, sessions
    py tools/rpfm_mcp_bridge.py start           # start rpfm_server headless (for tools/*.py)
    py tools/rpfm_mcp_bridge.py stop            # stop it - only one this bridge started, only if unused
    py tools/rpfm_mcp_bridge.py --selftest

Ported from MrJox/attila-modding-marketplace, plugins/attila-toolkit/scripts/rpfm_bridge.py
and rpfm_server.py (MIT License, Copyright (c) 2026 Mr.Jox aka victimized), cut down for this
workspace: a fixed exe path instead of the detection layer, and a stop that also refuses while
`/sessions` shows any other connection or an open pack. Upstream stopped the server when the
last bridge exited, which would kill the backend of an RPFM window opened in the meantime and
drop unsaved edits in the shared MCP session.

Behaviour:
- At startup, if nothing listens on 127.0.0.1:45127, start RPFM/rpfm_server.exe detached with
  no window and record its pid. RPFM_AUTOSTART=0 turns that off (the bridge then only connects).
- Forward every JSON-RPC message to /mcp. If the server went away (crashed or killed), start it
  again and replay `initialize`; the shared RPFM session is gone then, so `session_status` /
  `set_game` again. Closing the RPFM window does NOT stop the server it started or attached to
  (measured 2026-11-12), so a server can outlive the window; `stop` or the next exit cleans up.
- Measured 2026-11-12 on RPFM 5.3.3: cold start 1.4-2.2 s, 15 MB idle, 3.3 GB after `set_game`
  loads the vanilla data. The RPFM window attaches to a running server rather than starting a
  second one, and shows in /sessions as connection_count 1; MCP clients count 0.
- Tool results over RPFM_BRIDGE_MAX_CHARS (60,000) are cut to a quarter and saved whole under
  the state dir, because one 25 MB result drops Claude Code's MCP connection.
- On exit: close our MCP session (rpfm_server leaks memory on sessions never closed), and if
  this was the last bridge and the server is ours and unused, stop it (~2 GB once a game's
  dependencies are loaded).

State lives in %LOCALAPPDATA%/rpfm_mcp_bridge: pid file, one file per live bridge, the server log.
Standard library only. Logs go to stderr.
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HOST, PORT, PATH = "127.0.0.1", 45127, "/mcp"
EXE = os.environ.get("RPFM_SERVER") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "RPFM", "rpfm_server.exe")
STATE = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "rpfm_mcp_bridge")
PID_FILE = os.path.join(STATE, "rpfm_server.json")
CLIENTS = os.path.join(STATE, "clients")
LOG_FILE = os.path.join(STATE, "rpfm_server.log")
MAX_TEXT = int(os.environ.get("RPFM_BRIDGE_MAX_CHARS", "60000"))
AUTOSTART = os.environ.get("RPFM_AUTOSTART", "1").lower() not in ("0", "false", "no", "off")


def log(*a):
    print("[rpfm-bridge]", *a, file=sys.stderr, flush=True)


# ---- the server ---------------------------------------------------------------------------
def listening(timeout=0.5):
    try:
        with socket.create_connection((HOST, PORT), timeout=timeout):
            return True
    except OSError:
        return False


def pid_alive(pid):
    if pid <= 0:
        return False
    import ctypes
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)                    # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    code = ctypes.c_ulong()
    ok = k.GetExitCodeProcess(h, ctypes.byref(code))
    k.CloseHandle(h)
    return bool(ok) and code.value == 259                    # STILL_ACTIVE


def _pidfile():
    try:
        with open(PID_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def start(wait=40.0):
    """Make sure a server answers on the port. Returns (ok, message)."""
    if listening():
        return True, "already running on %s:%d" % (HOST, PORT)
    if not os.path.exists(EXE):
        return False, "rpfm_server not found at %s (set RPFM_SERVER)" % EXE
    os.makedirs(STATE, exist_ok=True)
    out = open(LOG_FILE, "ab")
    flags = 0x00000008 | 0x00000200 | 0x08000000             # DETACHED | NEW_GROUP | NO_WINDOW
    proc = subprocess.Popen([EXE], cwd=os.path.dirname(EXE), stdin=subprocess.DEVNULL,
                            stdout=out, stderr=out, creationflags=flags)
    with open(PID_FILE, "w", encoding="utf-8") as f:
        json.dump({"pid": proc.pid, "exe": EXE, "started": time.time()}, f)
    end = time.time() + wait
    while time.time() < end:
        if listening():
            return True, "started pid %d" % proc.pid
        if proc.poll() is not None:
            return False, "rpfm_server exited with code %s (see %s)" % (proc.returncode, LOG_FILE)
        time.sleep(0.25)
    return False, "rpfm_server did not open port %d within %ds (see %s)" % (PORT, wait, LOG_FILE)


def sessions():
    """The server's /sessions list, or None when it does not answer."""
    try:
        c = http.client.HTTPConnection(HOST, PORT, timeout=5)
        c.request("GET", "/sessions")
        body = c.getresponse().read()
        c.close()
        d = json.loads(body)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, list) else d.get("sessions", [d])


def busy(sess):
    """Why the server must stay up, or '' - any live connection or any open pack."""
    for s in sess or []:
        if s.get("connection_count", 0) > 0:
            return "session %s has %d connection(s)" % (s.get("session_id"), s["connection_count"])
        if s.get("pack_names"):
            return "session %s has open packs: %s" % (s.get("session_id"), ", ".join(s["pack_names"]))
    return ""


def stop():
    pid = _pidfile().get("pid", 0)
    if not pid or not pid_alive(pid):
        _clear_pidfile()
        return False, "no bridge-started server running (a server RPFM's window started is never touched)"
    why = busy(sessions())
    if why:
        return False, "left running: " + why
    subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
    _clear_pidfile()
    return True, "stopped pid %d" % pid


def _clear_pidfile():
    try:
        os.remove(PID_FILE)
    except OSError:
        pass


def register_client():
    """Count this process as a user of the server: bridges and tools/rpfm_client.py both do."""
    os.makedirs(CLIENTS, exist_ok=True)
    open(os.path.join(CLIENTS, str(os.getpid())), "w").close()


def release_client():
    """Uncount this process; the last one out stops a server this bridge started, if unused."""
    try:
        os.remove(os.path.join(CLIENTS, str(os.getpid())))
    except OSError:
        pass
    alive = 0
    for n in os.listdir(CLIENTS) if os.path.isdir(CLIENTS) else []:
        if n.isdigit() and pid_alive(int(n)):
            alive += 1
        else:
            try:
                os.remove(os.path.join(CLIENTS, n))
            except OSError:
                pass
    if alive == 0:
        ok, msg = stop()
        if ok or msg.startswith("left running"):
            log(msg)


# ---- the bridge ---------------------------------------------------------------------------
_out_lock = threading.Lock()
_state_lock = threading.Lock()
_state = {"sid": None, "version": None, "init": None}
_big = [0]


def shrink(msg):
    res = msg.get("result")
    if not isinstance(res, dict) or not isinstance(res.get("content"), list):
        return msg
    for c in res["content"]:
        t = c.get("text") if isinstance(c, dict) else None
        if isinstance(t, str) and len(t) > MAX_TEXT:
            d = os.path.join(STATE, "large_results")
            os.makedirs(d, exist_ok=True)
            _big[0] += 1
            path = os.path.join(d, "result_%d_%d.json" % (os.getpid(), _big[0]))
            with open(path, "w", encoding="utf-8") as f:
                f.write(t)
            c["text"] = (t[:MAX_TEXT // 4] + "\n... [cut by tools/rpfm_mcp_bridge.py: %d of %d characters "
                         "shown; the whole result is in %s]" % (MAX_TEXT // 4, len(t), path))
    return msg


def emit(msg):
    data = json.dumps(shrink(msg), separators=(",", ":")).encode("utf-8") + b"\n"
    with _out_lock:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


def _headers():
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if _state["sid"]:
        h["Mcp-Session-Id"] = _state["sid"]
    if _state["version"]:
        h["MCP-Protocol-Version"] = _state["version"]
    return h


def read_events(ctype, readline, read):
    """JSON-RPC messages out of an SSE or a plain JSON response body."""
    if "text/event-stream" not in ctype:
        body = read()
        if body.strip():
            yield json.loads(body)
        return
    data = []
    while True:
        line = readline()
        if not line:
            break
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line.startswith("data:"):
            data.append(line[5:].lstrip(" "))
        elif line == "" and data:
            text, data = "\n".join(data).strip(), []
            if text:
                yield json.loads(text)
    if data and "\n".join(data).strip():
        yield json.loads("\n".join(data))


def _events(r):
    return read_events(r.getheader("Content-Type", ""), r.readline, r.read)


def _post(msg):
    c = http.client.HTTPConnection(HOST, PORT, timeout=None)
    c.request("POST", PATH, json.dumps(msg).encode("utf-8"), _headers())
    return c, c.getresponse()


def _reinitialize():
    if not _state["init"]:
        raise RuntimeError("no initialize request to replay")
    with _state_lock:
        _state["sid"] = None
        c, r = _post(_state["init"])
        _state["sid"] = r.getheader("Mcp-Session-Id")
        list(_events(r))
        c.close()
        c, r = _post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        r.read()
        c.close()


def forward(msg):
    is_request = "method" in msg and "id" in msg
    is_init = msg.get("method") == "initialize"
    if is_init:
        _state["init"], _state["sid"] = msg, None
    try:
        try:
            c, r = _post(msg)
        except OSError:                                       # server gone: start it, new session
            ok, why = start()
            if not ok:
                raise RuntimeError(why)
            log("server restarted (%s); the shared RPFM session is new - set_game again" % why)
            if not is_init:
                _reinitialize()
            c, r = _post(msg)
        if r.status in (400, 404) and not is_init and _state["init"]:
            r.read()
            c.close()
            log("MCP session lost (HTTP %d), re-initialising" % r.status)
            _reinitialize()
            c, r = _post(msg)
        if r.status >= 400:
            body = r.read().decode("utf-8", "replace")
            c.close()
            raise RuntimeError("HTTP %d from rpfm_server: %s" % (r.status, body[:300]))
        if is_init:
            _state["sid"] = r.getheader("Mcp-Session-Id")
        for m in _events(r):
            if is_init and isinstance(m.get("result"), dict):
                _state["version"] = m["result"].get("protocolVersion")
            emit(m)
        c.close()
    except Exception as e:                                    # report to the client, keep running
        log("error:", e)
        if is_request:
            emit({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": str(e)}})


def _close_upstream():
    if not _state["sid"]:
        return
    try:
        c = http.client.HTTPConnection(HOST, PORT, timeout=5)
        c.request("DELETE", PATH, headers=_headers())
        c.getresponse().read()
        c.close()
    except OSError:
        pass


def bridge():
    if AUTOSTART:
        log(start()[1])
    register_client()
    pool = ThreadPoolExecutor(max_workers=16)
    try:
        for raw in sys.stdin.buffer:
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                log("bad JSON from client:", raw[:200])
                continue
            if msg.get("method") == "initialize":
                forward(msg)                                  # must finish before anything else
            else:
                pool.submit(forward, msg)
    finally:
        pool.shutdown(wait=False, cancel_futures=True)        # a job can run 10 min; do not hang exit
        _close_upstream()
        if AUTOSTART:
            release_client()


# ---- selftest -----------------------------------------------------------------------------
def selftest():
    import io
    sse = io.BytesIO(b'event: message\ndata: {"jsonrpc":"2.0",\ndata: "id":1}\n\ndata: {"id":2}\n')
    got = list(read_events("text/event-stream", sse.readline, sse.read))
    assert got == [{"jsonrpc": "2.0", "id": 1}, {"id": 2}], got
    plain = io.BytesIO(b'{"id":3}')
    assert list(read_events("application/json", plain.readline, plain.read)) == [{"id": 3}]
    assert list(read_events("application/json", io.BytesIO(b"").readline, io.BytesIO(b"").read)) == []

    assert busy([{"session_id": 1, "connection_count": 0, "pack_names": []}]) == ""
    assert busy([]) == "" and busy(None) == ""
    assert "connection" in busy([{"session_id": 1, "connection_count": 0}, {"session_id": 2, "connection_count": 1}])
    assert "a.pack" in busy([{"session_id": 1, "connection_count": 0, "pack_names": ["a.pack"]}])

    big = {"result": {"content": [{"type": "text", "text": "x" * (MAX_TEXT + 1)}]}}
    t = shrink(big)["result"]["content"][0]["text"]
    assert len(t) < MAX_TEXT and "whole result is in" in t, len(t)
    path = t.rsplit("is in ", 1)[1].rstrip("]")
    assert os.path.getsize(path) == MAX_TEXT + 1
    os.remove(path)
    small = {"result": {"content": [{"type": "text", "text": "ok"}]}}
    assert shrink(small)["result"]["content"][0]["text"] == "ok"
    print("selftest: ok")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "":
        bridge()
        return 0
    if cmd == "--selftest":
        selftest()
        return 0
    if cmd == "status":
        up = listening()
        info = _pidfile()
        mine = up and info.get("pid") and pid_alive(info["pid"])
        print("rpfm_server on %s:%d: %s%s" % (HOST, PORT, "UP" if up else "down",
              " (started by this bridge, pid %s)" % info["pid"] if mine else ""))
        if up:
            print(json.dumps(sessions(), indent=1))
        return 0 if up else 1
    if cmd == "start":
        ok, msg = start()
        print(msg)
        return 0 if ok else 1
    if cmd == "stop":
        print(stop()[1])
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
