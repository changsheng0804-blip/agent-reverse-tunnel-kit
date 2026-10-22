#!/usr/bin/env python3
"""Minimal key-only SSH server for the reverse-tunnel kit (Variant B).

Use when the agent's machine has no openssh-server. Serves ONE dedicated
low-privilege user, public-key auth only, binds 127.0.0.1 only.

Config via environment:
  REVSSH_DIR   base dir holding host_ed25519 + authorized_keys (default ~/revssh)
  REVSSH_PORT  listen port on localhost (default 2223)
  REVSSH_USER  the only login user allowed (default revtest)

Requires: paramiko (pip install paramiko, a venv inside REVSSH_DIR works).
Run it as root (it drops privileges to REVSSH_USER for every session),
or as REVSSH_USER itself (demote becomes a no-op then).
"""
import base64, fcntl, os, pwd, socket, subprocess, sys, termios, threading, time
import paramiko

BASE = os.environ.get("REVSSH_DIR", os.path.expanduser("~/revssh"))
PORT = int(os.environ.get("REVSSH_PORT", "2223"))
LOGIN_USER = os.environ.get("REVSSH_USER", "revtest")

HOSTKEY = paramiko.Ed25519Key.from_private_key_file(os.path.join(BASE, "host_ed25519"))

def load_authorized():
    keys = []
    with open(os.path.join(BASE, "authorized_keys")) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "ssh-ed25519":
                keys.append(parts[1])
    return keys

AUTH_KEYS_B64 = load_authorized()
LOG = open(os.path.join(BASE, "server.log"), "a", buffering=1)

def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, file=LOG)

def _pw():
    return pwd.getpwnam(LOGIN_USER)

def _demote():
    pw = _pw()
    os.setgroups([])
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)

def _demote_ctty():
    """Drop privileges, become session leader and adopt fd0 as controlling tty.
    This is what removes the 'cannot set terminal process group' /
    'no job control in this shell' warnings."""
    pw = _pw()
    os.setsid()
    os.setgroups([])
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

def _env():
    pw = _pw()
    return {"HOME": pw.pw_dir, "USER": LOGIN_USER, "LOGNAME": LOGIN_USER,
            "SHELL": "/bin/bash", "PATH": "/usr/local/bin:/usr/bin:/bin", "TERM": "xterm"}

def run_as_user(cmd, chan):
    proc = subprocess.Popen(
        ["/bin/bash", "-c", cmd],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        preexec_fn=_demote, cwd=_pw().pw_dir, env=_env())
    def feed_stdin():
        try:
            while True:
                data = chan.recv(32768)
                if not data:
                    break
                proc.stdin.write(data); proc.stdin.flush()
        except Exception:
            pass
        try: proc.stdin.close()
        except Exception: pass
    def pump(src, is_err):
        try:
            while True:
                data = src.read1(32768) if hasattr(src, "read1") else src.read(32768)
                if not data:
                    break
                (chan.send_stderr if is_err else chan.send)(data)
        except Exception:
            pass
    threading.Thread(target=feed_stdin, daemon=True).start()
    t1 = threading.Thread(target=pump, args=(proc.stdout, False), daemon=True)
    t2 = threading.Thread(target=pump, args=(proc.stderr, True), daemon=True)
    t1.start(); t2.start()
    rc = proc.wait(); t1.join(2); t2.join(2)
    try:
        chan.send_exit_status(rc)
        chan.close()  # without this, OpenSSH clients hang waiting for channel EOF
    except Exception:
        pass

def shell_as_user(chan):
    import pty, select
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ["/bin/bash", "-l"],
        stdin=slave, stdout=slave, stderr=slave,
        preexec_fn=_demote_ctty, cwd=_pw().pw_dir, env=_env(), close_fds=True)
    os.close(slave)
    def from_client():
        try:
            while True:
                data = chan.recv(32768)
                if not data:
                    break
                os.write(master, data)
        except Exception:
            pass
    threading.Thread(target=from_client, daemon=True).start()
    try:
        while True:
            r, _, _ = select.select([master], [], [], 0.5)
            if master in r:
                try: data = os.read(master, 32768)
                except OSError: break
                if not data: break
                chan.send(data)
            if proc.poll() is not None:
                break
    except Exception:
        pass
    try:
        chan.send_exit_status(proc.wait() if proc.poll() is None else proc.returncode)
        chan.close()
    except Exception:
        pass

class Server(paramiko.ServerInterface):
    def get_allowed_auths(self, username):
        return "publickey"
    def check_auth_publickey(self, username, key):
        try:
            b64 = base64.b64encode(key.asbytes()).decode()
            ok = (username == LOGIN_USER and key.get_name() == "ssh-ed25519"
                  and b64 in AUTH_KEYS_B64)
            log("auth", username, "OK" if ok else "DENY")
            return paramiko.AUTH_SUCCESSFUL if ok else paramiko.AUTH_FAILED
        except Exception as e:
            log("auth error", e)
            return paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid):
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_exec_request(self, channel, command):
        cmd = command.decode("utf-8", "replace")
        log("exec:", cmd[:200])
        threading.Thread(target=run_as_user, args=(cmd, channel), daemon=True).start()
        return True
    def check_channel_shell_request(self, channel):
        threading.Thread(target=shell_as_user, args=(channel,), daemon=True).start()
        return True
    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        return True

def handle(conn, addr):
    try:
        t = paramiko.Transport(conn)
        t.add_server_key(HOSTKEY)
        t.start_server(server=Server())
        chan = t.accept(20)
        if chan is None:
            return
        while t.is_active():
            time.sleep(0.5)
    except Exception as e:
        log("conn error", addr, e)
    finally:
        try: conn.close()
        except Exception: pass

def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT))
    s.listen(20)
    log(f"listening on 127.0.0.1:{PORT} user={LOGIN_USER} dir={BASE}")
    while True:
        conn, addr = s.accept()
        log("connect from", addr)
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()

if __name__ == "__main__":
    main()
