#!/usr/bin/env python3
"""Workshop laptop preflight for Windows and macOS.

Run it from the VS Code or Cursor terminal:
    Windows:  python preflight.py     (or: py preflight.py)
    macOS:    python3 preflight.py

Options: --yes (accept defaults, no prompts)   --skip-docker

Uses only the standard library, because the packages are part of what is tested.
Every check is isolated: a failure is recorded and the run continues, so the report
is complete. Python packages go in a temporary virtual environment that is deleted
at the end. An optional keys.env beside this file supplies keys and setting overrides.

Keep this file ASCII, with syntax an old Python can parse, so an old Python reaches
the friendly version message instead of a syntax error.
"""
from __future__ import print_function

import sys

if sys.version_info < (3, 7):
    print("This check needs Python 3.7 or newer, and the workshop needs 3.10 or newer.")
    print("Found Python %d.%d. Install Python 3.12 from python.org or through IT, then run it again." % sys.version_info[:2])
    print("If 'python' is an old version, try: python3 preflight.py   or   py preflight.py")
    sys.exit(2)

import base64
import getpass
import http.client
import json
import os
import platform
import re
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser

# ---------------------------------------------------------------- defaults
# Participants can accept or change these at the start. keys.env can override them.
DEFAULTS = {
    "OPENAI_BASE_URL": "https://api.openai.com/v1",
    "OPENAI_MODEL": "gpt-4o-mini gpt-4.1-mini",  # the workshop agent and judge models
    "LANGFUSE_HOST": "https://cloud.langfuse.com",
    "GIT_REPO_URL": "https://github.com/kartik-nighania/av-pfizer-training",
    "PIP_INDEX_URL": "https://pypi.org/simple",
    "PIP_PACKAGES": "langfuse langchain langgraph langchain-openai openai pyyaml deepeval pandas matplotlib nest_asyncio requests",
    "DOCKER_TEST_IMAGE": "hello-world",
    "DOCKER_BASE_IMAGE": "python:3.12-slim",
    "PROXY_URL": "auto",  # auto, none, or a URL such as http://proxy.example.com:8080
    "CA_BUNDLE": "",  # optional path to a corporate root CA file (PEM)
}
SETTING_LABELS = (
    ("OPENAI_BASE_URL", "OpenAI API URL"),
    ("OPENAI_MODEL", "OpenAI models (space separated)"),
    ("LANGFUSE_HOST", "Langfuse host"),
    ("GIT_REPO_URL", "Git test repo"),
    ("PIP_INDEX_URL", "Pip index"),
    ("PIP_PACKAGES", "Pip test packages"),
    ("DOCKER_TEST_IMAGE", "Docker test image"),
    ("DOCKER_BASE_IMAGE", "Docker base image"),
    ("PROXY_URL", "Proxy (auto, none or a URL)"),
    ("CA_BUNDLE", "Corporate CA file"),
)
JUPYTER_PACKAGES = ["jupyterlab", "notebook", "ipykernel", "nbconvert"]
PROBE_IMAGE = "workshop-preflight-probe"
PUBLIC_CA = re.compile(
    r"Let.s Encrypt|DigiCert|Sectigo|Google Trust|Amazon|Cloudflare|GlobalSign|GoDaddy|Entrust|Microsoft|"
    r"Baltimore|ZeroSSL|Starfield|SSL\.com|Certainly|COMODO|IdenTrust|ISRG|USERTrust|Fastly", re.I)
SECURITY_TOOLS = re.compile(
    r"zscaler|netskope|falcon|crowdstrike|sentinel|cylance|globalprotect|pangps|anyconnect|forticlient|"
    r"umbrella|carbonblack|tanium|jamf|msmpeng", re.I)
TLS_FIX = (
    "Corporate TLS inspection is the likely cause: the OS trusts the company root CA but Python's bundled "
    "certifi list does not. Ask IT for the root CA as a PEM file, re-run with CA_BUNDLE set, and set "
    "SSL_CERT_FILE and REQUESTS_CA_BUNDLE to it on workshop day."
)
LANGFUSE_FALLBACK = "Fallback: run code locally and view results in the instructor's Langfuse project."
GIT_FALLBACK = "Fallback: the code is shared as a zip and the CI/CD gate is an instructor demo."
DOCKER_FALLBACK = "Fallback: the build and run are an instructor demo."

DOCKERFILE = """ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE}
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN pip install --no-cache-dir --disable-pip-version-check --index-url "${PIP_INDEX_URL}" requests
COPY probe.py /probe.py
ENTRYPOINT ["python", "/probe.py"]
"""
DOCKER_PROBE = """import sys
import requests

failed = False
for url in sys.argv[1:]:
    try:
        response = requests.get(url, timeout=15)
        print("OK", url, response.status_code)
    except Exception as exc:
        failed = True
        print("FAIL", url, type(exc).__name__, str(exc)[:300])
sys.exit(1 if failed else 0)
"""

IS_WINDOWS = os.name == "nt"
IS_MAC = sys.platform == "darwin"
HERE = os.path.dirname(os.path.abspath(__file__))
COLORS = {"PASS": "\033[32m", "WARN": "\033[33m", "FAIL": "\033[31m", "SKIP": "\033[36m"}
USE_COLOR = False
ASSUME_YES = False
SKIP_DOCKER = False
WORK = os.environ.get("PF_WORK", "")
RESULTS = os.environ.get("PF_RESULTS", "")
LOG = os.environ.get("PF_LOG", "")
CFG = dict(DEFAULTS)
KEYS = {"OPENAI_API_KEY": "", "LANGFUSE_PUBLIC_KEY": "", "LANGFUSE_SECRET_KEY": ""}
PROXY = ""
INSPECTED = []
ISSUERS_READ = 0
MISSING_TOOLS = []
IS_ADMIN = True
DOCKER = ""
CURRENT_PROC = None
REPORT_PATH = ""
REPORT_WRITTEN = False
INTERRUPTED = False
STARTED = time.time()


# ---------------------------------------------------------------- output
def log(text):
    try:
        with open(LOG, "a", encoding="utf-8", errors="replace", newline="\n") as handle:
            handle.write(str(text).rstrip("\n") + "\n")
    except OSError:
        pass


def clean(text):
    return re.sub(r"[\t\r\n]+", " ", str(text)).strip()


def color(status):
    return COLORS[status] + status.ljust(4) + "\033[0m" if USE_COLOR and status in COLORS else status.ljust(4)


def record(check_id, status, title, detail="", hint=""):
    row = "\t".join(clean(v) for v in (check_id, status, title, detail, hint))
    with open(RESULTS, "a", encoding="utf-8", errors="replace", newline="\n") as handle:
        handle.write(row + "\n")
    log("\n[RESULT] %s %s: %s | %s" % (status, check_id, title, clean(detail)))
    print("  [%s] %s%s" % (color(status), clean(title), " - " + clean(detail) if detail else ""), flush=True)
    if hint and status in ("FAIL", "WARN"):
        print("         > " + clean(hint), flush=True)


def section(title):
    print("\n== %s ==" % title, flush=True)
    log("\n\n======== %s ========" % title)


def progress(text):
    print("  ...    " + text, flush=True)


def safe(check_id, title, func, *args):
    """Run one check so that a crash is reported and the remaining checks still run."""
    try:
        return func(*args)
    except Exception:
        log("Crash in %s:\n%s" % (check_id, traceback.format_exc()))
        record(check_id, "FAIL", title + ": check crashed", "", "The remaining checks still ran. The traceback is in the diagnostics.")
        return None


# ---------------------------------------------------------------- running commands
def kill_tree(proc):
    try:
        if IS_WINDOWS:
            subprocess.call(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        else:
            os.killpg(proc.pid, signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def run(cmd, timeout=120, env=None, cwd=None):
    """Run a command, log its output, and return (exit_code, output).

    124 means timed out and 127 means it could not start. It never raises for these.
    """
    global CURRENT_PROC
    cmd = [str(part) for part in cmd]
    log("\n$ " + " ".join(cmd))
    started = time.time()
    options = {}
    if not IS_WINDOWS:
        options["start_new_session"] = True  # so a timeout can kill the whole process group
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, cwd=cwd,
            universal_newlines=True, encoding="utf-8", errors="replace", **options)
    except (OSError, ValueError) as exc:
        log("could not start: %s" % exc)
        return 127, str(exc)
    CURRENT_PROC = proc
    try:
        output, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        try:
            output, _ = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            output = ""
        code = 124
    finally:
        CURRENT_PROC = None
    output = output or ""
    shown = output if len(output) < 12000 else output[:3000] + "\n...[trimmed]...\n" + output[-9000:]
    log(shown)
    log("[exit %s after %.1fs]" % (code, time.time() - started))
    return code, output


def last_line(text):
    lines = [line.strip() for line in str(text).splitlines() if line.strip()]
    return lines[-1] if lines else ""


def find_tool(names, paths=()):
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    for path in paths:
        if path and os.path.isfile(path):
            return path
    return ""


def env_path(name, *parts):
    base = os.environ.get(name, "")
    return os.path.join(base, *parts) if base else ""


# ---------------------------------------------------------------- report
def scrub(text):
    for secret in KEYS.values():
        if secret:
            text = text.replace(secret, "***REDACTED***")
    rules = (
        (r"sk-[A-Za-z0-9_*\-]{8,}", "sk-***REDACTED***"),
        (r"pk-lf-[A-Za-z0-9\-]+", "pk-lf-***REDACTED***"),
        (r"gh[pousr]_[A-Za-z0-9]{20,}", "gh*_***REDACTED***"),
        (r"github_pat_[A-Za-z0-9_]+", "github_pat_***REDACTED***"),
        (r"(Bearer|Basic) [A-Za-z0-9._~+/=\-]{8,}", r"\1 ***REDACTED***"),
        (r"([?&]token=)[^&\s]+", r"\1***REDACTED***"),
        (r"(ServerApp\.token=)\S+", r"\1***REDACTED***"),
        (r"([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@\s]+:[^/@\s]+@", r"\1***:***@"),
    )
    for pattern, replacement in rules:
        text = re.sub(pattern, replacement, text)
    names = []
    try:
        names.append((getpass.getuser(), "<user>"))
    except Exception:
        pass
    machine = socket.gethostname()
    names += [(machine, "<host>"), (machine.split(".")[0], "<host>")]
    for name, replacement in names:
        if name and len(name) >= 3:
            text = re.sub(re.escape(name), replacement, text, flags=re.I)
    return text


def read_rows():
    try:
        with open(RESULTS, encoding="utf-8", errors="replace") as handle:
            return [(line.rstrip("\n").split("\t") + [""] * 5)[:5] for line in handle if line.strip()]
    except OSError:
        return []


def count(status, rows=None):
    return sum(1 for row in (read_rows() if rows is None else rows) if row[1] == status)


def verdict(rows):
    if count("FAIL", rows):
        return "NOT READY - required items failed"
    if count("WARN", rows):
        return "READY WITH WARNINGS - see the items below"
    return "READY"


def write_report():
    global REPORT_PATH, REPORT_WRITTEN
    if REPORT_WRITTEN:
        return
    REPORT_WRITTEN = True
    rows = read_rows()
    lines = [
        "WORKSHOP PREFLIGHT REPORT",
        "Created:   " + time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "Platform:  %s on %s, Python %s" % (platform.platform(), platform.machine(), platform.python_version()),
        "Verdict:   " + verdict(rows),
        "Counts:    PASS %d | WARN %d | FAIL %d | SKIP %d" % (count("PASS", rows), count("WARN", rows), count("FAIL", rows), count("SKIP", rows)),
        "Run time:  %d min %d s" % divmod(int(time.time() - STARTED), 60),
    ]
    if INTERRUPTED:
        lines.append("NOTE:      The run did not finish, so this report is partial.")
    lines += ["", "---- SUMMARY ----"]
    for row in rows:
        lines.append("%-5s %-24s %s%s" % (row[1], row[0], row[2], " - " + row[3] if row[3] else ""))
    lines += ["", "---- PROBLEMS AND LIKELY CAUSES ----"]
    problems = [row for row in rows if row[1] in ("FAIL", "WARN")]
    for row in problems:
        lines.append("%s %s: %s" % (row[1], row[0], row[2]))
        if row[3]:
            lines.append("    Detail: " + row[3])
        if row[4]:
            lines.append("    Likely cause / fix: " + row[4])
        lines.append("")
    if not problems:
        lines += ["None.", ""]
    lines.append("---- SETTINGS USED ----")
    for key, label in SETTING_LABELS:
        lines.append("%-34s %s" % (label + ":", CFG.get(key, "") or "none"))
    lines.append("%-34s %s" % ("Proxy in use:", PROXY or "none"))
    lines.append("%-34s %s" % ("OpenAI key:", "provided" if KEYS["OPENAI_API_KEY"] else "not provided"))
    lines.append("%-34s %s" % ("Langfuse keys:", "provided" if KEYS["LANGFUSE_PUBLIC_KEY"] and KEYS["LANGFUSE_SECRET_KEY"] else "not provided"))
    lines += ["", "---- FULL DIAGNOSTICS ----"]
    try:
        with open(LOG, encoding="utf-8", errors="replace") as handle:
            lines.append(handle.read())
    except OSError as exc:
        lines.append("Could not read the diagnostics: %s" % exc)
    text = scrub("\n".join(lines))
    name = "workshop-preflight-report-%s.txt" % time.strftime("%Y%m%d-%H%M%S")
    # Beside this file, so it appears in the folder already open in the IDE.
    for folder in (HERE, os.path.expanduser("~"), tempfile.gettempdir()):
        REPORT_PATH = os.path.join(folder, name)
        try:
            with open(REPORT_PATH, "w", encoding="utf-8", errors="replace") as handle:
                handle.write(text)
            return
        except OSError:
            REPORT_PATH = ""


# ---------------------------------------------------------------- prompts and settings
def ask(prompt):
    """Read one line, or return None when there is nobody to answer."""
    try:
        return input(prompt)
    except (EOFError, OSError):
        return None


def ask_yes(prompt, default):
    if ASSUME_YES:
        return default == "y"
    answer = ask(prompt + " ")
    if answer is None:
        return default == "y"
    return (answer.strip().lower() or default) in ("y", "yes")


def read_key_file(path):
    values = {}
    with open(path, encoding="utf-8-sig", errors="replace") as handle:
        for line in handle:
            text = re.sub(r"^export\s+", "", line.strip())
            if text and not text.startswith("#") and "=" in text:
                key, value = text.split("=", 1)
                values[key.strip()] = value.strip().strip("\"'")
    return values


def load_key_file():
    path = os.path.join(HERE, "keys.env")
    if not os.path.isfile(path):
        return False
    values = read_key_file(path)
    for key in KEYS:
        if values.get(key):
            KEYS[key] = values[key]
    for key in CFG:
        if values.get(key):
            CFG[key] = values[key]
    if values.get("LANGFUSE_BASE_URL"):
        CFG["LANGFUSE_HOST"] = values["LANGFUSE_BASE_URL"]
    return True


def system_proxy():
    try:
        proxies = urllib.request.getproxies()
        found = proxies.get("https") or proxies.get("http") or ""
        if found and "://" not in found:
            found = "http://" + found
        return found
    except Exception as exc:
        log("Could not read system proxy settings: %s" % exc)
        return ""


def resolve_proxy():
    global PROXY
    setting = CFG["PROXY_URL"].strip()
    if setting == "none":
        PROXY = ""
    elif setting in ("", "auto"):
        PROXY = system_proxy()
    else:
        PROXY = setting


def show_settings():
    resolve_proxy()
    print("")
    for number, (key, label) in enumerate(SETTING_LABELS, 1):
        value = CFG[key] or "none"
        if key == "PROXY_URL":
            value += " (currently: %s)" % (PROXY or "direct connection")
        print("  %2d. %-32s %s" % (number, label.split(" (")[0], value))
    print("")


def read_secret(key, label):
    if KEYS[key]:
        return
    existing = os.environ.get(key, "")
    if existing and ask_yes("  %s is already set in this terminal. Use it? [Y/n]" % key, "y"):
        KEYS[key] = existing
        return
    if ASSUME_YES:
        return
    try:
        KEYS[key] = getpass.getpass("  %s (hidden, Enter to skip): " % label).strip()
    except (EOFError, OSError, getpass.GetPassWarning):
        pass


def configure():
    section("Settings")
    has_key_file = load_key_file()
    show_settings()
    if not ask_yes("Use these settings? [Y/n]", "y"):
        print("  Press Enter to keep a value, or type a new one. Enter - to clear it.")
        for key, label in SETTING_LABELS:
            answer = ask("  %s [%s]: " % (label, CFG[key] or "empty"))
            if answer == "-":
                CFG[key] = ""
            elif answer:
                CFG[key] = answer.strip()
        show_settings()
    print("API keys are used only for test calls. They are never saved and are removed from the report.")
    if has_key_file:
        print("  Using the values supplied in keys.env.")
    read_secret("OPENAI_API_KEY", "OpenAI API key")
    read_secret("LANGFUSE_PUBLIC_KEY", "Langfuse public key")
    read_secret("LANGFUSE_SECRET_KEY", "Langfuse secret key")
    for key in ("OPENAI_BASE_URL", "LANGFUSE_HOST", "PIP_INDEX_URL"):
        CFG[key] = CFG[key].rstrip("/")

    resolve_proxy()
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"):
        os.environ.pop(name, None)
    if PROXY:
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
            os.environ[name] = PROXY
    os.environ["NO_PROXY"] = os.environ["no_proxy"] = "localhost,127.0.0.1,::1"

    if CFG["CA_BUNDLE"]:
        if os.path.isfile(CFG["CA_BUNDLE"]):
            for name in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "PIP_CERT", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"):
                os.environ[name] = CFG["CA_BUNDLE"]
        else:
            record("config.ca", "WARN", "Corporate CA file not found", CFG["CA_BUNDLE"], "Check the path. Continuing without it.")
            CFG["CA_BUNDLE"] = ""


# ---------------------------------------------------------------- laptop and terminal
def total_ram_gb():
    if IS_MAC:
        code, output = run(["sysctl", "-n", "hw.memsize"], 15)
        return int(last_line(output)) / 1073741824.0 if code == 0 else 0
    if IS_WINDOWS:
        import ctypes

        class MemoryStatus(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong),
                        ("ullAvailPageFile", ctypes.c_ulonglong), ("ullTotalVirtual", ctypes.c_ulonglong),
                        ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        status = MemoryStatus()
        status.dwLength = ctypes.sizeof(MemoryStatus)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
        return status.ullTotalPhys / 1073741824.0
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1073741824.0


def check_ram():
    # An 8 GB laptop can report slightly under 8 once firmware has reserved its share.
    ram = round(total_ram_gb(), 1)
    if ram >= 15:
        record("sys.ram", "PASS", "RAM %s GB" % ram)
    elif ram >= 7.5:
        record("sys.ram", "WARN", "RAM %s GB" % ram, "meets the 8 GB minimum", "16 GB is recommended for Docker. Close other apps during the workshop.")
    else:
        record("sys.ram", "FAIL", "RAM %s GB" % ram, "below the 8 GB minimum", "Use a laptop with at least 8 GB of RAM.")


def check_disk():
    free = int(shutil.disk_usage(os.path.expanduser("~")).free / 1073741824)
    if free >= 15:
        record("sys.disk", "PASS", "Free disk %d GB" % free)
    elif free >= 5:
        record("sys.disk", "WARN", "Free disk %d GB" % free, "", "15 GB or more is recommended for Docker images and Python packages.")
    else:
        record("sys.disk", "FAIL", "Free disk %d GB" % free, "", "Free at least 5 GB. Python packages alone need about 1 GB.")


def check_admin():
    global IS_ADMIN
    if IS_WINDOWS:
        # S-1-5-32-544 is the local Administrators group, listed even when UAC has filtered it.
        _, output = run(["whoami", "/groups"], 20)
        IS_ADMIN = "S-1-5-32-544" in output
    else:
        _, output = run(["id", "-Gn"], 15)
        IS_ADMIN = bool(set(output.split()) & {"admin", "sudo", "root", "wheel"})
    if IS_ADMIN:
        record("sys.admin", "PASS", "Account has admin rights")
    else:
        record("sys.admin", "WARN", "Account does not have admin rights", "", "IT must pre-install anything reported missing below.")


def collect_system_details():
    if IS_MAC:
        run(["sw_vers"], 15)
        run(["profiles", "status", "-type", "enrollment"], 20)
        run(["scutil", "--nc", "list"], 15)
        _, output = run(["ps", "-axco", "command"], 20)
    elif IS_WINDOWS:
        run(["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Processor | Select-Object Name,VirtualizationFirmwareEnabled | Format-List"], 40)
        _, output = run(["tasklist", "/FO", "CSV", "/NH"], 30)
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\FileSystem") as key:
                log("LongPathsEnabled: %s" % winreg.QueryValueEx(key, "LongPathsEnabled")[0])
        except Exception as exc:
            log("Could not read LongPathsEnabled: %s" % exc)
    else:
        output = ""
    found = sorted({match.group(0).lower() for match in SECURITY_TOOLS.finditer(output)})
    log("Security and VPN tools seen running: " + (", ".join(found) or "none matched"))


def check_laptop():
    section("Laptop")
    record("sys.os", "PASS", platform.platform(), "%s, %s CPU threads" % (platform.machine(), os.cpu_count()))
    safe("sys.ram", "RAM", check_ram)
    safe("sys.disk", "Disk", check_disk)
    safe("sys.admin", "Admin rights", check_admin)
    safe("sys.details", "System details", collect_system_details)


def detect_ide_terminal():
    if os.environ.get("TERM_PROGRAM", "").lower() != "vscode":
        return ""
    clues = " ".join(os.environ.get(name, "") for name in ("VSCODE_GIT_ASKPASS_NODE", "VSCODE_GIT_ASKPASS_MAIN", "VSCODE_CWD", "CURSOR_TRACE_ID"))
    return "Cursor" if os.environ.get("CURSOR_TRACE_ID") or "cursor" in clues.lower() else "VS Code"


def check_windows_powershell():
    code, output = run(["powershell", "-NoProfile", "-Command", "echo PF_PS_OK; $ExecutionContext.SessionState.LanguageMode"], 40)
    if "PF_PS_OK" not in output:
        record("term.powershell", "WARN", "PowerShell did not run a command", "exit %s" % code, "PowerShell may be disabled by policy. Use Command Prompt on the day.")
        return
    mode = last_line(output)
    record("term.powershell", "PASS", "PowerShell runs commands", mode)
    if mode != "FullLanguage":
        record("term.language", "WARN", "PowerShell is in %s" % mode, "", "AppLocker or WDAC is active. Virtual environment activation may be blocked, and Python may be restricted too.")
    _, output = run(["powershell", "-NoProfile", "-Command", "Get-ExecutionPolicy -List | ForEach-Object { $_.Scope.ToString() + '=' + $_.ExecutionPolicy.ToString() }"], 40)
    policies = dict(line.strip().split("=", 1) for line in output.splitlines() if "=" in line)
    effective = "Restricted"
    for scope in ("MachinePolicy", "UserPolicy", "Process", "CurrentUser", "LocalMachine"):
        if policies.get(scope, "Undefined") != "Undefined":
            effective = policies[scope]
            break
    if effective in ("Restricted", "AllSigned"):
        record("term.policy", "WARN", "PowerShell execution policy is %s" % effective, "",
               r"venv\Scripts\Activate.ps1 will not run. Use Command Prompt with venv\Scripts\activate.bat, or run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
    else:
        record("term.policy", "PASS", "PowerShell execution policy is %s" % effective, "virtual environments can be activated")


def check_shell():
    if IS_WINDOWS:
        code, output = run([os.environ.get("ComSpec", "cmd.exe"), "/c", "echo PF_SHELL_OK"], 15)
    else:
        code, output = run(["/bin/sh", "-c", "echo PF_SHELL_OK"], 15)
    if "PF_SHELL_OK" in output:
        record("term.shell", "PASS", "Terminal can run commands", "shell: %s" % (os.environ.get("SHELL") or os.environ.get("ComSpec") or "unknown"))
    else:
        record("term.shell", "FAIL", "Terminal could not run a command", "exit %s" % code, "The shell may be disabled by policy. Ask IT.")


def check_terminal():
    section("Terminal")
    log("PATH=%s" % os.environ.get("PATH", ""))
    log("TERM_PROGRAM=%s TERM=%s" % (os.environ.get("TERM_PROGRAM", ""), os.environ.get("TERM", "")))
    ide = detect_ide_terminal()
    if ide:
        record("term.ide", "PASS", "Running in the %s terminal" % ide)
    else:
        record("term.ide", "WARN", "Not running in a VS Code or Cursor terminal", "",
               "Please re-run from the terminal inside VS Code or Cursor, because that is what the workshop uses.")
    safe("term.shell", "Shell", check_shell)
    if IS_WINDOWS:
        safe("term.powershell", "PowerShell", check_windows_powershell)


# ---------------------------------------------------------------- network
def curl_hint(code, text=""):
    if re.search(r"CRYPT_E_NO_REVOCATION_CHECK|CRYPT_E_REVOCATION_OFFLINE", text):
        return "Windows could not check certificate revocation, which is common behind an inspection proxy. Ask IT to allow the CRL endpoints."
    if re.search(r"SEC_E_UNTRUSTED_ROOT|CERT_TRUST|unable to get local issuer", text):
        code = 60
    if code == 7 and PROXY:
        return "Could not connect through the configured proxy. Check the proxy URL, or try proxy setting none."
    hints = {
        5: "The proxy host name cannot be resolved. Check the proxy URL.",
        6: "DNS cannot resolve this host. Connect to VPN, or ask IT whether it is blocked.",
        7: "The connection was refused or blocked. A firewall or missing proxy setting is likely.",
        28: "The connection timed out. A firewall is probably dropping traffic, or a proxy is needed.",
        35: "The TLS handshake failed. A firewall or inspection proxy may be interfering.",
        52: "The connection was dropped after it opened. A proxy or firewall is likely closing it.",
        56: "The connection was dropped after it opened. A proxy or firewall is likely closing it.",
        60: "The certificate is not trusted, which usually means corporate TLS inspection. Ask IT for the root CA file and set CA_BUNDLE.",
        77: "The certificate is not trusted, which usually means corporate TLS inspection. Ask IT for the root CA file and set CA_BUNDLE.",
        97: "The proxy handshake failed. Check the proxy URL.",
        124: "The request timed out. A firewall is probably dropping traffic, or a proxy is needed.",
    }
    return hints.get(code, "The request failed with code %s. See the diagnostics." % code)


def http_request(url, secret_config="", timeout=30):
    """Return (error_code, http_status, text). error_code uses curl's numbers, and 0 means a response arrived."""
    body_path = os.path.join(WORK, "body.txt")
    if os.path.exists(body_path):
        os.remove(body_path)
    curl = find_tool(["curl"])
    if curl:
        cmd = [curl, "-sS", "-o", body_path, "--connect-timeout", "10", "-m", str(timeout),
               "-w", "\nPF %{http_code} ip=%{remote_ip} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n"]
        config_path = ""
        if secret_config:
            # Keys go through a private file so they never appear in a process list.
            config_path = os.path.join(WORK, "curl.cfg")
            with open(config_path, "w", encoding="utf-8") as handle:
                handle.write(secret_config + "\n")
            cmd += ["-K", config_path]
        try:
            code, output = run(cmd + [url], timeout + 5)
        finally:
            if config_path and os.path.exists(config_path):
                os.remove(config_path)
        match = re.search(r"^PF (\d{3})", output, re.M)
        status = int(match.group(1)) if match else 0
    else:
        code, status, output = urllib_request(url, secret_config, timeout, body_path)
    body = ""
    if os.path.exists(body_path):
        with open(body_path, encoding="utf-8", errors="replace") as handle:
            body = handle.read()
    return code, status, output, body


def urllib_request(url, secret_config, timeout, body_path):
    """Fallback for a machine without curl: same result codes, less detail."""
    request = urllib.request.Request(url, headers={"User-Agent": "workshop-preflight"})
    for line in secret_config.splitlines():
        match = re.match(r'header = "([^:]+): (.*)"', line)
        if match:
            request.add_header(match.group(1), match.group(2))
        match = re.match(r'user = "(.*)"', line)
        if match:
            request.add_header("Authorization", "Basic " + base64.b64encode(match.group(1).encode()).decode())
    log("\nGET %s (urllib, curl was not found)" % url)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, data = response.status, response.read(2000000)
    except urllib.error.HTTPError as exc:
        status, data = exc.code, exc.read(2000000)
    except Exception as exc:
        reason = getattr(exc, "reason", exc)
        code = 1
        if isinstance(reason, ssl.SSLCertVerificationError):
            code = 60
        elif isinstance(reason, ssl.SSLError):
            code = 35
        elif isinstance(reason, socket.gaierror):
            code = 6
        elif isinstance(reason, (socket.timeout, TimeoutError)):
            code = 28
        elif isinstance(reason, (ConnectionRefusedError, OSError)):
            code = 7
        log("failed: %s: %s" % (type(reason).__name__, reason))
        return code, 0, str(reason)
    with open(body_path, "wb") as handle:
        handle.write(data)
    log("HTTP %s" % status)
    return 0, status, "HTTP %s" % status


def read_issuer(url):
    """Read who signed the site's certificate. Verification is off here, and nothing is sent to the site."""
    parts = urllib.parse.urlsplit(url)
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    connection = None
    try:
        if PROXY:
            proxy = urllib.parse.urlsplit(PROXY)
            connection = http.client.HTTPSConnection(proxy.hostname, proxy.port or 8080, timeout=10, context=context)
            headers = {}
            if proxy.username:
                login = "%s:%s" % (urllib.parse.unquote(proxy.username), urllib.parse.unquote(proxy.password or ""))
                headers["Proxy-Authorization"] = "Basic " + base64.b64encode(login.encode()).decode()
            connection.set_tunnel(parts.hostname, parts.port or 443, headers)
        else:
            connection = http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=10, context=context)
        connection.connect()
        der = connection.sock.getpeercert(True)
        pem_path = os.path.join(WORK, "peer.pem")
        with open(pem_path, "w") as handle:
            handle.write(ssl.DER_cert_to_PEM_cert(der))
        decoded = ssl._ssl._test_decode_cert(pem_path)
        names = {key: value for rdn in decoded.get("issuer", ()) for key, value in rdn}
        return ", ".join(names[key] for key in ("organizationName", "commonName") if key in names)
    except Exception as exc:
        log("Could not read the certificate issuer for %s: %s" % (parts.hostname, exc))
        return ""
    finally:
        if connection is not None:
            connection.close()


def windows_stack_status(url):
    """Windows' own network stack follows PAC files and proxy settings the way a browser does."""
    if not IS_WINDOWS:
        return ""
    script = ("try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri '%s').StatusCode } "
              "catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } }" % url)
    _, output = run(["powershell", "-NoProfile", "-Command", script], 40)
    found = re.search(r"\b(\d{3})\b", output)
    return found.group(1) if found else ""


def check_url(check_id, label, url, severity, allow_403=False):
    global ISSUERS_READ
    host = urllib.parse.urlsplit(url).hostname or url
    code, status, output, body = http_request(url)
    issuer = read_issuer(url) if url.startswith("https") else ""
    detail = host
    if issuer:
        ISSUERS_READ += 1
        detail += ", cert issuer: " + issuer
        if not PUBLIC_CA.search(issuer):
            INSPECTED.append("%s [%s]" % (host, issuer))
    if code in (18, 28, 56) and status:
        record(check_id, "WARN", "%s reachable but very slow" % label, "%s, HTTP %s, stopped after the time limit" % (detail, status),
               "The host answered, so it is not blocked, but data is arriving slowly. Installs may take much longer on this network.")
    elif code != 0:
        try:
            log("DNS for %s: %s" % (host, socket.gethostbyname(host)))
        except OSError as exc:
            log("DNS for %s failed: %s" % (host, exc))
        system = windows_stack_status(url)
        if system:
            record(check_id, severity, "%s: works through Windows settings, but not for command-line tools" % label,
                   "%s, curl exit %s, Windows HTTP %s" % (detail, code, system),
                   "Python, Git and Docker do not use PAC files. Re-run and enter the proxy URL under Proxy, or ask IT for it.")
        else:
            record(check_id, severity, "%s: not reachable" % label, "%s, error %s" % (detail, code), curl_hint(code, output))
    elif status == 407:
        record(check_id, severity, "%s: proxy login required" % label, "%s, HTTP 407" % detail, "The proxy wants a login that tools cannot provide. Ask IT to allowlist this host.")
    elif status == 403 and not allow_403:
        log(body[:800])
        record(check_id, severity, "%s: blocked (HTTP 403)" % label, detail, "This may be a URL filter. The response body is in the diagnostics. Ask IT to allowlist this host.")
    elif status >= 500:
        log(body[:800])
        record(check_id, severity, "%s: server or gateway error" % label, "%s, HTTP %s" % (detail, status), "This is a proxy or temporary service problem. Retry, then ask IT if it persists.")
    else:
        record(check_id, "PASS", "%s reachable" % label, "%s, HTTP %s" % (detail, status))


def log_network_setup():
    log("Proxy in use: %s" % (PROXY or "none"))
    if IS_MAC:
        run(["scutil", "--proxy"], 15)
        run(["scutil", "--dns"], 15)
    elif IS_WINDOWS:
        run(["netsh", "winhttp", "show", "proxy"], 15)
        run(["ipconfig", "/all"], 20)
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Internet Settings") as key:
                for name in ("ProxyEnable", "ProxyServer", "AutoConfigURL"):
                    try:
                        log("Internet Settings %s=%s" % (name, winreg.QueryValueEx(key, name)[0]))
                    except OSError:
                        log("Internet Settings %s is not set" % name)
        except Exception as exc:
            log("Could not read Internet Settings: %s" % exc)
    curl = find_tool(["curl"])
    if curl:
        run([curl, "--version"], 15)
    else:
        log("curl was not found, so network checks use Python's urllib.")


def check_network():
    section("Network")
    safe("net.setup", "Network details", log_network_setup)
    targets = [
        ("net.openai", "OpenAI API", CFG["OPENAI_BASE_URL"] + "/models", "FAIL", False),
        ("net.pypi", "Package index", CFG["PIP_INDEX_URL"] + "/six/", "FAIL", False),
    ]
    if CFG["PIP_INDEX_URL"].startswith("https://pypi.org/"):
        targets.append(("net.pythonhosted", "PyPI file downloads", "https://files.pythonhosted.org/", "FAIL", False))
    targets += [
        ("net.github", "GitHub", "https://github.com", "WARN", False),
        ("net.codeload", "GitHub downloads", "https://codeload.github.com", "WARN", False),
        ("net.dockerhub", "Docker Hub registry", "https://registry-1.docker.io/v2/", "WARN", False),
        ("net.dockerauth", "Docker Hub login service", "https://auth.docker.io/token", "WARN", False),
        ("net.dockercdn", "Docker Hub image CDN", "https://production.cloudflare.docker.com/", "WARN", True),
        ("net.vscode", "VS Code extensions", "https://marketplace.visualstudio.com", "WARN", False),
        ("net.openvsx", "Cursor extensions (Open VSX)", "https://open-vsx.org", "WARN", False),
        ("net.langfuse_us", "Langfuse US region", "https://us.cloud.langfuse.com", "WARN", False),
    ]
    for target in targets:
        safe(target[0], target[1], check_url, *target)
    if INSPECTED:
        record("net.tls_inspection", "WARN", "TLS inspection detected", "; ".join(INSPECTED),
               "HTTPS is being re-signed by a non-public CA. Python and Docker may not trust it even when browsers do; see the Python and Docker results.")
    elif ISSUERS_READ == 0:
        record("net.tls_inspection", "SKIP", "TLS inspection not checked", "no certificate issuers could be read")
    else:
        record("net.tls_inspection", "PASS", "No TLS inspection detected", "%d sampled certificates come from public CAs" % ISSUERS_READ)


# ---------------------------------------------------------------- OpenAI and Langfuse APIs
def check_openai_key():
    section("OpenAI API")
    key = KEYS["OPENAI_API_KEY"]
    if not key:
        record("openai.key", "WARN", "OpenAI key not tested", "no key provided", "Re-run with a key to prove API access. Required for the agent and LLM judges.")
        return
    code, status, output, body = http_request(CFG["OPENAI_BASE_URL"] + "/models", 'header = "Authorization: Bearer %s"' % key, 30)
    log(body[:300])
    if code != 0:
        record("openai.key", "FAIL", "OpenAI API call failed", "error %s" % code, curl_hint(code, output))
    elif status == 200:
        missing = [model for model in CFG["OPENAI_MODEL"].split() if '"%s"' % model not in body]
        if missing:
            record("openai.key", "WARN", "OpenAI key accepted, but a model is not listed", " ".join(missing), "Choose models this key's project can use.")
        else:
            record("openai.key", "PASS", "OpenAI key accepted", "available: " + CFG["OPENAI_MODEL"])
    elif status == 401:
        record("openai.key", "FAIL", "OpenAI rejected the key", "HTTP 401", "Check it is complete and has not been revoked.")
    elif status == 403:
        record("openai.key", "FAIL", "OpenAI access refused", "HTTP 403", "This may be a proxy URL filter or an unsupported region. The response body is in the diagnostics.")
    elif status == 429:
        record("openai.key", "FAIL", "OpenAI rate limit or no credit", "HTTP 429", "The network and key work. Check the account's billing and limits.")
    else:
        record("openai.key", "FAIL", "Unexpected OpenAI response", "HTTP %s" % status, "The response body is in the diagnostics.")


def check_langfuse_keys():
    public, secret = KEYS["LANGFUSE_PUBLIC_KEY"], KEYS["LANGFUSE_SECRET_KEY"]
    if not (public and secret):
        record("langfuse.auth", "SKIP", "Langfuse keys not tested", "keys not provided")
        return
    code, status, output, body = http_request(CFG["LANGFUSE_HOST"] + "/api/public/projects", 'user = "%s:%s"' % (public, secret))
    log(body[:300])
    if code != 0:
        record("langfuse.auth", "WARN", "Langfuse key check failed", "error %s" % code, curl_hint(code, output) + " " + LANGFUSE_FALLBACK)
    elif status == 200:
        record("langfuse.auth", "PASS", "Langfuse keys accepted", CFG["LANGFUSE_HOST"])
    elif status == 401:
        record("langfuse.auth", "WARN", "Langfuse rejected the keys", "HTTP 401",
               "Check the keys and the region: cloud.langfuse.com and us.cloud.langfuse.com are separate. " + LANGFUSE_FALLBACK)
    else:
        record("langfuse.auth", "WARN", "Unexpected Langfuse response", "HTTP %s" % status, LANGFUSE_FALLBACK)


def open_in_chrome(url):
    if IS_MAC:
        code, _ = run(["open", "-a", "Google Chrome", url], 20)
        return code == 0
    if IS_WINDOWS:
        chrome = find_tool(["chrome"], (env_path("ProgramFiles", "Google", "Chrome", "Application", "chrome.exe"),
                                        env_path("ProgramFiles(x86)", "Google", "Chrome", "Application", "chrome.exe"),
                                        env_path("LOCALAPPDATA", "Google", "Chrome", "Application", "chrome.exe")))
    else:
        chrome = find_tool(["google-chrome", "chrome", "chromium"])
    if not chrome:
        return False
    # Chrome keeps running after the page opens, so do not wait for it.
    subprocess.Popen([chrome, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    return True


def confirm_in_chrome():
    """A browser can take a different network path from command-line tools, so a person confirms this."""
    if ASSUME_YES:
        record("langfuse.chrome", "SKIP", "Chrome UI check not done", "it needs a person; run without --yes")
        return
    url = CFG["LANGFUSE_HOST"]
    browser = "Chrome"
    print("\n  Manual check: the Langfuse page must load in Google Chrome. No sign-in is needed.")
    print("  Link: " + url)
    if ask_yes("  Open it in Chrome now? [Y/n]", "y"):
        if not open_in_chrome(url):
            browser = "your default browser"
            record("langfuse.chrome_app", "WARN", "Google Chrome could not be opened", "", "Install Chrome, or tell your instructor which browser you will use.")
            webbrowser.open(url)
    else:
        print("  Open the link above in Chrome yourself.")
    for _ in range(5):
        answer = ask("  Did the page load in %s? A sign-in page counts. [y = yes, n = no, s = skip] " % browser)
        if answer is None:
            break
        answer = answer.strip().lower()
        if answer in ("y", "yes"):
            record("langfuse.chrome", "PASS", "Langfuse UI loads in %s" % browser, "confirmed by participant")
            return
        if answer in ("n", "no"):
            seen = ask("  What did you see? For example: blocked page, blank page, timeout. ") or "not described"
            record("langfuse.chrome", "WARN", "Langfuse UI did not load in %s" % browser, "participant saw: " + seen,
                   "The browser may use a different proxy or web filter. Ask IT to allow %s. %s" % (url, LANGFUSE_FALLBACK))
            return
        if answer in ("s", "skip"):
            break
        print("  Please type y, n or s.")
    record("langfuse.chrome", "SKIP", "Chrome UI check skipped")


def check_langfuse():
    section("Langfuse")
    safe("langfuse.ui", "Langfuse UI", check_url, "langfuse.ui", "Langfuse UI", CFG["LANGFUSE_HOST"], "WARN")
    safe("langfuse.api", "Langfuse API", check_url, "langfuse.api", "Langfuse API", CFG["LANGFUSE_HOST"] + "/api/public/health", "WARN")
    safe("langfuse.auth", "Langfuse keys", check_langfuse_keys)
    safe("langfuse.chrome", "Chrome UI", confirm_in_chrome)


# ---------------------------------------------------------------- python: base stage
def venv_python():
    return os.path.join(WORK, "venv", "Scripts", "python.exe") if IS_WINDOWS else os.path.join(WORK, "venv", "bin", "python")


def package_list():
    return (os.environ.get("PF_PIP_PACKAGES") or CFG["PIP_PACKAGES"]).split()


def pip_hint(output):
    rules = (
        (r"CERTIFICATE_VERIFY_FAILED|SSLError|certificate verify failed", TLS_FIX),
        (r"ProxyError|\b407\b|Tunnel connection failed", "The proxy refused the connection. Check the proxy URL; pip cannot do NTLM/Kerberos proxy logins, so IT may need to allowlist PyPI."),
        (r"getaddrinfo failed|Name or service not known|nodename nor servname|Temporary failure in name resolution", "DNS cannot resolve the package index. Connect to VPN or ask IT about pypi.org and files.pythonhosted.org."),
        (r"\b403\b|Forbidden", "The index or proxy returned 403, so a package-filtering policy is likely. Ask IT to allow the packages or give an approved mirror URL."),
        (r"Read timed out|ReadTimeoutError|IncompleteRead", "Downloads started but stalled, so the index is reachable. The connection may be slow or unstable, or a proxy may be scanning large files. Retry; if it repeats, ask IT."),
        (r"timed out|ConnectTimeout", "Connections timed out. A firewall may be dropping traffic to pypi.org or files.pythonhosted.org."),
        (r"Connection refused|NewConnectionError|connection broken|Connection reset", "pip could not connect to the index. A firewall or wrong proxy setting is likely; check the Network results above."),
        (r"No matching distribution|Could not find a version", "The package is missing from this index, or has no build for this Python version and CPU."),
        (r"Permission denied|Access is denied", "File access was denied, possibly by endpoint security software scanning the temp folder."),
        (r"No space left", "The disk is full. Free some space and re-run."),
    )
    for pattern, hint in rules:
        if re.search(pattern, output, re.I):
            return hint
    return "See the pip output in the diagnostics section of the report."


def pip_install(packages, timeout, no_cache=False, fast_fail=False):
    cmd = [venv_python(), "-m", "pip", "install", "--disable-pip-version-check", "--index-url", CFG["PIP_INDEX_URL"]]
    if no_cache:
        cmd.append("--no-cache-dir")
    # The index failing already means retries only waste time. Otherwise allow for slow office networks.
    cmd += ["--retries", "1", "--timeout", "15"] if fast_fail else ["--retries", "5", "--timeout", "60"]
    return run(cmd + packages, timeout)


def install_with_retry(packages, timeout, index_ok):
    """A stalled download is often temporary, and pip's cache means a retry resumes most of the work."""
    code, output = pip_install(packages, timeout, fast_fail=not index_ok)
    if code != 0 and index_ok and re.search(r"Read timed out|ReadTimeoutError|IncompleteRead|Connection reset|connection broken", output, re.I):
        progress("A download stalled, so retrying once")
        code, output = pip_install(packages, timeout)
    return code, output


def check_python_version():
    version = platform.python_version()
    if sys.version_info >= (3, 10):
        record("python.version", "PASS", "Python %s" % version, sys.executable)
    else:
        record("python.version", "FAIL", "Python %s is too old" % version, sys.executable,
               "Install Python 3.12 from python.org or through IT. Required for all hands-on code. The other checks continue with this version.")
    if IS_WINDOWS:
        run(["py", "-0p"], 20)
    for name in ("python", "python3", "python3.12"):
        log("%s on PATH: %s" % (name, shutil.which(name) or "not found"))


def check_pip():
    code, output = run([sys.executable, "-m", "pip", "--version"], 60)
    if code == 0:
        record("python.pip", "PASS", "pip available", output.strip().split(" from ")[0])
    else:
        record("python.pip", "FAIL", "pip not available", "exit %s" % code, "Reinstall Python from python.org so that it includes pip. Required for all hands-on code.")
    run([sys.executable, "-m", "pip", "config", "list"], 30)
    log("OpenSSL: %s" % ssl.OPENSSL_VERSION)
    log("Default verify paths: %s" % (ssl.get_default_verify_paths(),))


def create_venv():
    progress("Creating a temporary virtual environment")
    code, _ = run([sys.executable, "-m", "venv", os.path.join(WORK, "venv")], 240)
    if code != 0 or not os.path.exists(venv_python()):
        record("python.venv", "FAIL", "Cannot create a virtual environment", "exit %s" % code,
               "The venv module or ensurepip is missing, or endpoint security blocked it. Reinstall Python from python.org or ask IT.")
        return False
    record("python.venv", "PASS", "Virtual environment created")
    return True


def check_index():
    progress("Downloading a small package straight from the index (no cache)")
    code, output = pip_install(["six"], 180, no_cache=True)
    if code == 0:
        record("pip.index", "PASS", "Package download from the index works", CFG["PIP_INDEX_URL"])
        return True
    record("pip.index", "FAIL", "Cannot download packages from the index", CFG["PIP_INDEX_URL"], pip_hint(output))
    run([venv_python(), "-m", "pip", "download", "-vvv", "--no-cache-dir", "--no-deps", "--retries", "0",
         "--index-url", CFG["PIP_INDEX_URL"], "-d", os.path.join(WORK, "pipdl"), "six"], 120)
    return False


def install_workshop_packages(index_ok):
    packages = package_list()
    progress("Installing workshop packages (several minutes on a slow network)")
    code, output = install_with_retry(packages, 1200, index_ok)
    if code == 0:
        record("pip.packages", "PASS", "Workshop packages installed", " ".join(packages))
        return
    if not index_ok:
        record("pip.packages", "FAIL", "Workshop packages failed to install", "the index is not reachable", pip_hint(output))
        return
    # Installing one at a time shows exactly which packages are the problem.
    progress("The combined install failed, so trying each package separately")
    failed = [package for package in packages if install_with_retry([package], 400, True)[0] != 0]
    record("pip.packages", "FAIL", "Workshop packages failed to install",
           "failed alone: " + (" ".join(failed) if failed else "none, so the packages conflict with each other"), pip_hint(output))


def install_jupyter(index_ok):
    progress("Installing Jupyter (1-5 minutes)")
    code, output = install_with_retry(JUPYTER_PACKAGES, 900, index_ok)
    if code == 0:
        record("jupyter.install", "PASS", "Jupyter installed", " ".join(JUPYTER_PACKAGES))
    else:
        record("jupyter.install", "FAIL", "Jupyter failed to install", " ".join(JUPYTER_PACKAGES), pip_hint(output))


def run_venv_stage():
    env = os.environ.copy()
    env.update({
        "PF_WORK": WORK, "PF_RESULTS": RESULTS, "PF_LOG": LOG, "PF_PIP_PACKAGES": CFG["PIP_PACKAGES"],
        "PF_OPENAI_BASE_URL": CFG["OPENAI_BASE_URL"], "PF_OPENAI_MODEL": CFG["OPENAI_MODEL"],
        "PF_OPENAI_API_KEY": KEYS["OPENAI_API_KEY"], "PF_LANGFUSE_HOST": CFG["LANGFUSE_HOST"],
        "PYTHONIOENCODING": "utf-8", "PYTHONDONTWRITEBYTECODE": "1",
    })
    stderr_path = os.path.join(WORK, "venv_stage_stderr.txt")
    with open(stderr_path, "w", encoding="utf-8") as stderr:
        proc = subprocess.Popen([venv_python(), os.path.abspath(__file__), "--stage", "venv"], env=env, stderr=stderr, stdin=subprocess.DEVNULL)
        global CURRENT_PROC
        CURRENT_PROC = proc
        try:
            code = proc.wait(timeout=2400)
        except subprocess.TimeoutExpired:
            kill_tree(proc)
            record("python.venv_stage", "FAIL", "Checks inside the virtual environment timed out", "40 minutes", "The checks finished so far are in the report.")
            return
        finally:
            CURRENT_PROC = None
    with open(stderr_path, encoding="utf-8", errors="replace") as handle:
        log(handle.read()[-6000:])
    if code != 0:
        record("python.venv_stage", "FAIL", "Checks inside the virtual environment crashed", "exit %s" % code, "The traceback is in the diagnostics.")


def check_python():
    section("Python, pip and Jupyter")
    safe("python.version", "Python version", check_python_version)
    safe("python.pip", "pip", check_pip)
    if not safe("python.venv", "Virtual environment", create_venv):
        for check_id, title in (("pip.index", "Package downloads"), ("pip.packages", "Workshop packages"),
                                ("jupyter.install", "Jupyter"), ("openai.sdk", "OpenAI SDK")):
            record(check_id, "SKIP", title + " not tested", "these need a virtual environment")
        return
    index_ok = safe("pip.index", "Package index", check_index)
    safe("pip.packages", "Workshop packages", install_workshop_packages, index_ok)
    safe("jupyter.install", "Jupyter install", install_jupyter, index_ok)
    safe("pip.truststore", "truststore", pip_install, ["truststore"], 120, False, not index_ok)
    safe("pip.list", "Package list", run, [venv_python(), "-m", "pip", "list", "--format=freeze", "--disable-pip-version-check"], 60)
    safe("python.venv_stage", "Checks inside the virtual environment", run_venv_stage)


# ---------------------------------------------------------------- python: inside the venv
def try_get(url, verify):
    import httpx
    try:
        response = httpx.get(url, timeout=20) if verify is None else httpx.get(url, timeout=20, verify=verify)
        return True, "HTTP %s" % response.status_code
    except Exception as exc:  # the class and message are the diagnostic
        return False, "%s: %s" % (type(exc).__name__, str(exc)[:200])


def check_python_tls():
    """Compare the SDK's default trust list with the OS store, which pinpoints TLS inspection."""
    try:
        import httpx  # noqa: F401
    except ImportError as exc:
        record("tls.python", "SKIP", "Python TLS check not run", "httpx is not installed: %s" % exc)
        return
    try:
        import truststore
        os_store = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except Exception as exc:
        log("truststore unavailable: %s" % exc)
        os_store = None
    base = os.environ.get("PF_OPENAI_BASE_URL", DEFAULTS["OPENAI_BASE_URL"]).rstrip("/")
    langfuse = os.environ.get("PF_LANGFUSE_HOST", DEFAULTS["LANGFUSE_HOST"]).rstrip("/")
    failures, required_failed, inspected = [], False, False
    for url, required in ((base + "/models", True), (langfuse + "/api/public/health", False)):
        default_ok, default_info = try_get(url, None)
        store_ok, store_info = try_get(url, os_store) if os_store is not None else (None, "n/a")
        log("TLS %s | SDK default: %s | OS trust store: %s" % (url, default_info, store_info))
        if not default_ok:
            failures.append("%s (%s)" % (url, default_info))
            required_failed = required_failed or required
            inspected = inspected or bool(store_ok)
    if not failures:
        record("tls.python", "PASS", "Python SDK TLS trust works", "OpenAI and Langfuse verified using Python's default trust list")
        return
    hint = TLS_FIX if inspected else "Python cannot complete HTTPS even with the OS trust store. Check the proxy settings and firewall."
    record("tls.python", "FAIL" if required_failed else "WARN", "Python SDK cannot verify HTTPS", "; ".join(failures), hint)


def check_imports():
    """Installed is not the same as usable: endpoint security can block compiled modules."""
    renamed = {"pyyaml": "yaml"}
    failed = []
    for spec in package_list():
        name = re.split(r"[=<>!~\[ ]", spec)[0].lower()
        module = renamed.get(name, name.replace("-", "_"))
        if run([sys.executable, "-c", "import " + module], 180)[0] != 0:
            failed.append(module)
    if failed:
        record("pip.imports", "FAIL", "Some workshop packages cannot be imported", " ".join(failed),
               "They may have failed to install, or endpoint security may be blocking compiled modules. See the diagnostics.")
    else:
        record("pip.imports", "PASS", "Workshop packages import correctly")


def check_openai_model(openai, client, model):
    messages = [{"role": "user", "content": "Reply with the single word: ready"}]
    check_id = "openai.sdk." + model
    try:
        try:
            client.chat.completions.create(model=model, messages=messages, max_completion_tokens=16)
        except openai.BadRequestError as exc:
            if "max_completion_tokens" not in str(exc):
                raise
            client.chat.completions.create(model=model, messages=messages, max_tokens=16)
    except Exception as exc:
        name, text = type(exc).__name__, str(exc)[:400]
        log("OpenAI SDK error for %s: %s: %s" % (model, name, text))
        hints = {
            "AuthenticationError": "The key was rejected. Check it is complete and has not been revoked.",
            "PermissionDeniedError": "Access was refused. The key's project may not allow this model, or a proxy returned 403.",
            "NotFoundError": "The network and key work, but this model is not available. Choose another model when prompted.",
            "RateLimitError": "The network and key work, but the account hit a rate limit or has no credit. Check billing.",
            "APITimeoutError": "The request timed out, so a firewall or proxy may be holding the connection.",
            "APIConnectionError": "The SDK could not connect. Check the Python TLS and network results above.",
        }
        if "CERTIFICATE_VERIFY_FAILED" in text or "certificate verify failed" in repr(exc.__cause__):
            hint = TLS_FIX
        else:
            hint = hints.get(name, "See the diagnostics section of the report.")
        record(check_id, "FAIL", "OpenAI SDK chat call failed", "%s (model %s)" % (name, model), hint)
        return
    record(check_id, "PASS", "OpenAI SDK chat call works", "model %s, SDK %s" % (model, openai.__version__))


def check_openai_sdk():
    key = os.environ.get("PF_OPENAI_API_KEY", "")
    if not key:
        record("openai.sdk", "WARN", "OpenAI SDK call not tested", "no API key provided", "Re-run with a key to prove the agent and LLM judges will work.")
        return
    try:
        import openai
    except ImportError as exc:
        record("openai.sdk", "FAIL", "OpenAI SDK cannot be imported", str(exc), "The openai package did not install; see the pip check.")
        return
    client = openai.OpenAI(api_key=key, base_url=os.environ.get("PF_OPENAI_BASE_URL"), timeout=45, max_retries=0)
    for model in os.environ.get("PF_OPENAI_MODEL", DEFAULTS["OPENAI_MODEL"]).split():
        safe("openai.sdk." + model, "OpenAI SDK call", check_openai_model, openai, client, model)


def jupyter_env():
    """Isolate Jupyter so it neither reads nor writes the participant's own config."""
    env = os.environ.copy()
    env.pop("PF_OPENAI_API_KEY", None)
    root = os.path.join(WORK, "jupyter")
    for name, sub in (("JUPYTER_CONFIG_DIR", "config"), ("JUPYTER_RUNTIME_DIR", "runtime"), ("IPYTHONDIR", "ipython")):
        path = os.path.join(root, sub)
        os.makedirs(path, exist_ok=True)
        env[name] = path
    env["JUPYTER_PLATFORM_DIRS"] = "1"
    return env


def check_notebook(env, root):
    source = {
        "cells": [
            {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [],
             "source": "import sys\nprint('PF_KERNEL_' + str(6 * 7), sys.version_info[:2])"},
            {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [],
             "source": "import openai, langfuse\nprint('PF_IMPORTS_' + 'OK')"},
        ],
        "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
        "nbformat": 4, "nbformat_minor": 4,
    }
    path = os.path.join(root, "preflight.ipynb")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(source, handle)
    code, _ = run([sys.executable, "-m", "jupyter", "nbconvert", "--to", "notebook", "--execute", path,
                   "--output", "preflight_out.ipynb", "--ExecutePreprocessor.timeout=180"], 300, env, root)
    text = ""
    result = os.path.join(root, "preflight_out.ipynb")
    if os.path.exists(result):
        with open(result, encoding="utf-8") as handle:
            text = handle.read()
    if code == 0 and "PF_KERNEL_42" in text and "PF_IMPORTS_OK" in text:
        record("jupyter.notebook", "PASS", "Notebook kernel executes code", "ran a test notebook, including SDK imports")
    elif "PF_KERNEL_42" in text:
        record("jupyter.notebook", "FAIL", "Notebook kernel runs but SDK imports failed", "exit %s" % code, "Check the package install result; the traceback is in the diagnostics.")
    else:
        record("jupyter.notebook", "FAIL", "Notebook kernel could not run code", "exit %s" % code,
               "The kernel needs local TCP ports and running Python from the temp folder. Endpoint security may be blocking either.")


def local_http(url, token, method="GET"):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(url, method=method, data=b"" if method == "POST" else None)
    request.add_header("Authorization", "token " + token)
    try:
        with opener.open(request, timeout=15) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except Exception as exc:
        return 0, str(exc)


def terminal_roundtrip(port, token, name):
    """Send a command to a Jupyter terminal over its websocket and read the result."""
    import asyncio

    from tornado.httpclient import HTTPRequest
    from tornado.websocket import websocket_connect

    # The quotes stop the echoed input from matching: only a shell's output has PF_TERM_OK.
    command = 'echo PF_"TERM"_OK\r'

    def plain(text):
        return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)

    async def session():
        request = HTTPRequest("ws://127.0.0.1:%d/terminals/websocket/%s" % (port, name),
                              headers={"Authorization": "token " + token}, connect_timeout=15)
        connection = await websocket_connect(request)
        seen, sent, deadline, pending = "", False, time.time() + 40, None
        while time.time() < deadline:
            if pending is None:
                pending = asyncio.ensure_future(connection.read_message())
            done, _ = await asyncio.wait({pending}, timeout=2)
            if done:
                message, pending = pending.result(), None
                if message is None:
                    break
                try:
                    kind, payload = json.loads(message)[:2]
                except ValueError:
                    continue
                if kind == "stdout":
                    seen += payload
            if not sent and (seen or time.time() > deadline - 34):
                connection.write_message(json.dumps(["stdin", command]))
                sent = True
            text = plain(seen)
            # cmd.exe keeps the quotes when it echoes, so there input and output both match.
            if "PF_TERM_OK" in text or text.count('PF_"TERM"_OK') >= 2:
                connection.close()
                return True, text[-300:]
        connection.close()
        return False, plain(seen)[-500:]

    if IS_WINDOWS:
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    return asyncio.run(session())


def check_jupyter_terminal(base, port, token):
    status, body = local_http(base + "/api/terminals", token, "POST")
    if status != 200:
        record("jupyter.terminal", "WARN", "Jupyter terminal could not start", "HTTP %s" % status, "Participants can use the IDE terminal instead.")
        return
    name = ""
    try:
        name = json.loads(body)["name"]
        worked, transcript = terminal_roundtrip(port, token, name)
    except Exception as exc:
        worked, transcript = False, "%s: %s" % (type(exc).__name__, exc)
    log("Jupyter terminal transcript: %s" % transcript)
    if name:
        local_http(base + "/api/terminals/" + name, token, "DELETE")
    if worked:
        record("jupyter.terminal", "PASS", "Jupyter terminal runs commands", "sent a command and read its output")
    else:
        record("jupyter.terminal", "WARN", "Jupyter terminal did not respond", "", "Participants can use the IDE terminal instead. The transcript is in the diagnostics.")


def check_jupyterlab(env, root):
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 8888)) == 0:
            log("Port 8888 is already in use; Jupyter will pick another port on the day.")
    with socket.socket() as free:
        free.bind(("127.0.0.1", 0))
        port = free.getsockname()[1]
    token = uuid.uuid4().hex
    log_path = os.path.join(WORK, "jupyter_server.log")
    server_log = open(log_path, "w", encoding="utf-8", errors="replace")
    server = subprocess.Popen(
        [sys.executable, "-m", "jupyterlab", "--no-browser", "--ServerApp.ip=127.0.0.1", "--ServerApp.port=%d" % port,
         "--ServerApp.port_retries=0", "--ServerApp.token=" + token, "--ServerApp.root_dir=" + root, "--ServerApp.allow_root=True"],
        stdout=server_log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, cwd=root)
    base = "http://127.0.0.1:%d" % port
    try:
        status, deadline = 0, time.time() + 120
        while time.time() < deadline and server.poll() is None:
            status, _ = local_http(base + "/api/status", token)
            if status == 200:
                break
            time.sleep(2)
        if status != 200:
            record("jupyter.lab", "FAIL", "JupyterLab server did not start", "last status %s" % status,
                   "Endpoint security or a local firewall may block localhost servers. The server log is in the diagnostics.")
            record("jupyter.classic", "SKIP", "Jupyter Notebook UI not tested", "the server did not start")
            record("jupyter.terminal", "SKIP", "Jupyter terminal not tested", "the server did not start")
            return
        lab_status, lab_body = local_http(base + "/lab", token)
        if lab_status == 200 and "JupyterLab" in lab_body:
            record("jupyter.lab", "PASS", "JupyterLab server starts and serves its UI", "tested on a temporary local port")
        else:
            record("jupyter.lab", "FAIL", "JupyterLab UI did not load", "HTTP %s" % lab_status, "The server log is in the diagnostics.")
        tree_status, _ = local_http(base + "/tree", token)
        if tree_status == 200:
            record("jupyter.classic", "PASS", "Jupyter Notebook UI loads")
        else:
            record("jupyter.classic", "WARN", "Jupyter Notebook UI did not load", "HTTP %s" % tree_status, "JupyterLab can be used instead.")
        safe("jupyter.terminal", "Jupyter terminal", check_jupyter_terminal, base, port, token)
    finally:
        local_http(base + "/api/shutdown", token, "POST")
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            kill_tree(server)
        server_log.close()
        with open(log_path, encoding="utf-8", errors="replace") as handle:
            log("\n--- JupyterLab server log (last 6000 characters) ---\n" + handle.read()[-6000:])


def stage_venv():
    sys.stdout.reconfigure(errors="replace")
    safe("tls.python", "Python TLS", check_python_tls)
    safe("pip.imports", "Package imports", check_imports)
    safe("openai.sdk", "OpenAI SDK", check_openai_sdk)
    try:
        import jupyterlab  # noqa: F401
    except ImportError:
        for check_id, title in (("jupyter.notebook", "Notebook kernel"), ("jupyter.lab", "JupyterLab UI"),
                                ("jupyter.classic", "Jupyter Notebook UI"), ("jupyter.terminal", "Jupyter terminal")):
            record(check_id, "SKIP", title + " not tested", "Jupyter did not install")
        return
    env = jupyter_env()
    root = os.path.join(WORK, "jupyter", "workspace")
    os.makedirs(root, exist_ok=True)
    progress("Running a test notebook")
    safe("jupyter.kernelspec", "Kernel list", run, [sys.executable, "-m", "jupyter", "kernelspec", "list"], 60, env)
    safe("jupyter.notebook", "Notebook kernel", check_notebook, env, root)
    progress("Starting JupyterLab and testing its terminal")
    safe("jupyter.lab", "JupyterLab", check_jupyterlab, env, root)


# ---------------------------------------------------------------- git
def check_git():
    section("Git and GitHub")
    git = find_tool(["git"], (env_path("ProgramFiles", "Git", "cmd", "git.exe"),))
    # Without Command Line Tools this macOS stub opens an installer dialog instead of running.
    if IS_MAC and git == "/usr/bin/git" and run(["xcode-select", "-p"], 15)[0] != 0:
        git = ""
    if not git:
        MISSING_TOOLS.append("Git")
        record("git.install", "WARN", "Git not installed", "", "Install Git, or ask IT to. " + GIT_FALLBACK)
        record("git.clone", "SKIP", "Git clone not tested", "Git is not installed")
        return
    _, output = run([git, "--version"], 20)
    record("git.install", "PASS", last_line(output), git)
    run([git, "config", "--global", "--get-regexp", r"^(http|https|core\.sshcommand|url)\."], 20)
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
    url = CFG["GIT_REPO_URL"]
    code, output = run([git, "ls-remote", url, "HEAD"], 60, env)
    if code == 0:
        record("git.remote", "PASS", "Git can reach the repo", url)
    else:
        record("git.remote", "WARN", "Cannot reach the Git repo", last_line(output), "Check for a certificate, proxy or access error in the diagnostics. " + GIT_FALLBACK)
    target = os.path.join(WORK, "clone_test")
    code, output = run([git, "clone", "--depth", "1", url, target], 240, env)
    if code == 0 and os.path.exists(os.path.join(target, ".git")):
        record("git.clone", "PASS", "Workshop repo cloned", url)
    else:
        record("git.clone", "WARN", "Git clone failed", last_line(output), GIT_FALLBACK)


# ---------------------------------------------------------------- IDE
def check_one_ide(label, check_id, tool):
    code, _ = run([tool, "--version"], 30)
    if code != 0:
        record(check_id, "WARN", "%s is installed but its command failed" % label, "exit %s" % code, "Open it once to finish setup.")
        return
    _, output = run([tool, "--list-extensions"], 45)
    installed = {line.strip().lower() for line in output.splitlines()}
    missing = [name for name in ("ms-python.python", "ms-toolsai.jupyter") if name not in installed]
    if missing:
        record(check_id, "WARN", "%s is missing extensions" % label, " ".join(missing), "Install them from the Extensions panel. Fallback: JupyterLab.")
    else:
        record(check_id, "PASS", "%s with Python and Jupyter extensions" % label)


def check_ide():
    section("IDE")
    home = os.path.expanduser("~")
    code = find_tool(["code"], (
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        os.path.join(home, "Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
        env_path("LOCALAPPDATA", "Programs", "Microsoft VS Code", "bin", "code.cmd"),
        env_path("ProgramFiles", "Microsoft VS Code", "bin", "code.cmd")))
    cursor = find_tool(["cursor"], (
        "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
        os.path.join(home, "Applications/Cursor.app/Contents/Resources/app/bin/cursor"),
        env_path("LOCALAPPDATA", "Programs", "cursor", "resources", "app", "bin", "cursor.cmd"),
        env_path("ProgramFiles", "Cursor", "resources", "app", "bin", "cursor.cmd")))
    if code:
        safe("ide.vscode", "VS Code", check_one_ide, "VS Code", "ide.vscode", code)
    if cursor:
        safe("ide.cursor", "Cursor", check_one_ide, "Cursor", "ide.cursor", cursor)
    if not code and not cursor:
        MISSING_TOOLS.append("IDE")
        record("ide.install", "WARN", "Neither VS Code nor Cursor found", "", "Install one, or ask IT to. Fallback: JupyterLab through pip.")


# ---------------------------------------------------------------- docker
def docker_hint(text):
    trust = "Add the root CA to the Mac's keychain" if IS_MAC else "Add the root CA to Windows' trusted roots"
    rules = (
        (r"x509|certificate signed by unknown|tls: failed to verify", "Docker does not trust the corporate TLS inspection certificate. %s and restart Docker, or ask IT." % trust),
        (r"toomanyrequests|rate limit", "Docker Hub's rate limit was reached, which is common on a shared office IP. Run docker login, or use a mirror."),
        (r"proxyconnect|\b407\b|proxy", "Docker's proxy setup failed. Set the proxy under Docker Desktop > Settings > Resources > Proxies."),
        (r"i/o timeout|context deadline|TLS handshake timeout|no such host|connection refused|connection reset", "Docker cannot reach Docker Hub. Allow registry-1.docker.io, auth.docker.io and production.cloudflare.docker.com, or set Docker's proxy."),
        (r"denied|unauthorized|not allowed|pull access", "Docker Hub refused access, possibly from a registry policy. Ask IT, or use an approved image."),
        (r"no space left", "Docker is out of disk space. Run docker system prune or increase its disk limit."),
    )
    for pattern, hint in rules:
        if re.search(pattern, text, re.I):
            return hint
    return "See the Docker output in the diagnostics."


def check_docker_steps():
    test_image, base_image = CFG["DOCKER_TEST_IMAGE"], CFG["DOCKER_BASE_IMAGE"]
    had_test_image = run([DOCKER, "image", "inspect", test_image], 20)[0] == 0
    progress("Pulling " + test_image)
    code, output = run([DOCKER, "pull", test_image], 240)
    if code == 0:
        record("docker.pull", "PASS", "Image pull from Docker Hub works", test_image)
        code, output = run([DOCKER, "run", "--rm", test_image], 90)
        if code == 0:
            record("docker.run", "PASS", "Containers can run", test_image)
        else:
            record("docker.run", "WARN", "Container failed to run", "exit %s" % code, docker_hint(output) + " " + DOCKER_FALLBACK)
        if not had_test_image:
            run([DOCKER, "rmi", test_image], 30)
    else:
        record("docker.pull", "WARN", "Cannot pull images from Docker Hub", "%s, exit %s" % (test_image, code), docker_hint(output) + " " + DOCKER_FALLBACK)
        record("docker.run", "SKIP", "Container run not tested", "the test image could not be pulled")

    progress("Pulling %s (may take a few minutes). It stays on the laptop to save time on the day." % base_image)
    code, output = run([DOCKER, "pull", base_image], 480)
    if code == 0:
        record("docker.base", "PASS", "Base image pulled", base_image)
    else:
        record("docker.base", "WARN", "Cannot pull the base image", "%s, exit %s" % (base_image, code), docker_hint(output) + " " + DOCKER_FALLBACK)

    progress("Building a test image, including pip install inside the build")
    context = os.path.join(WORK, "docker_probe")
    os.makedirs(context, exist_ok=True)
    with open(os.path.join(context, "Dockerfile"), "w", newline="\n") as handle:
        handle.write(DOCKERFILE)
    with open(os.path.join(context, "probe.py"), "w", newline="\n") as handle:
        handle.write(DOCKER_PROBE)
    env = dict(os.environ, PIP_INDEX_URL=CFG["PIP_INDEX_URL"])
    proxy_build, proxy_run = [], []
    if PROXY:
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"):
            proxy_build += ["--build-arg", name]
            proxy_run += ["-e", name]
    code, output = run([DOCKER, "build", "--no-cache", "--progress=plain", "--build-arg", "BASE_IMAGE=" + base_image,
                        "--build-arg", "PIP_INDEX_URL"] + proxy_build + ["-t", PROBE_IMAGE, context], 420, env)
    if code != 0:
        record("docker.build", "WARN", "Docker build failed", "exit %s" % code,
               docker_hint(output) + " If only pip failed, containers do not trust the corporate CA or lack the proxy. " + DOCKER_FALLBACK)
        record("docker.network", "SKIP", "Container network not tested", "it needs the test image, which did not build")
        return
    record("docker.build", "PASS", "Docker build with pip install works")
    code, output = run([DOCKER, "run", "--rm"] + proxy_run + [PROBE_IMAGE, CFG["OPENAI_BASE_URL"] + "/models", CFG["LANGFUSE_HOST"] + "/api/public/health"], 120)
    if code == 0:
        record("docker.network", "PASS", "Containers can reach OpenAI and Langfuse")
    else:
        failures = [line for line in output.splitlines() if line.startswith("FAIL")]
        record("docker.network", "WARN", "Container cannot reach OpenAI or Langfuse", failures[0][:200] if failures else "exit %s" % code,
               "Containers may lack the corporate CA or proxy, or a firewall may block them. " + DOCKER_FALLBACK)


def check_docker():
    global DOCKER
    section("Docker")
    if SKIP_DOCKER:
        record("docker.install", "SKIP", "Docker checks skipped", "--skip-docker was used")
        return
    home = os.path.expanduser("~")
    DOCKER = find_tool(["docker"], (
        "/Applications/Docker.app/Contents/Resources/bin/docker", os.path.join(home, ".docker/bin/docker"), os.path.join(home, ".rd/bin/docker"),
        env_path("ProgramFiles", "Docker", "Docker", "resources", "bin", "docker.exe"), os.path.join(home, ".rd", "bin", "docker.exe")))
    if not DOCKER:
        MISSING_TOOLS.append("Docker")
        for name in ("podman", "nerdctl", "colima"):
            log("%s: %s" % (name, shutil.which(name) or "not found"))
        record("docker.install", "WARN", "Docker not installed", "", "Install Docker Desktop or the approved equivalent, or ask IT to. " + DOCKER_FALLBACK)
        record("docker.pull", "SKIP", "Docker image and container checks not run", "Docker is not installed")
        return
    _, output = run([DOCKER, "--version"], 20)
    record("docker.install", "PASS", last_line(output), DOCKER)
    run([DOCKER, "context", "ls"], 20)
    if IS_WINDOWS:
        # Docker Desktop on Windows depends on WSL2 and firmware virtualization.
        wsl_env = dict(os.environ, WSL_UTF8="1")
        run(["wsl", "--status"], 20, wsl_env)
        run(["wsl", "-l", "-v"], 20, wsl_env)
        run(["powershell", "-NoProfile", "-Command", "Get-Service com.docker.service,vmcompute,LxssManager -ErrorAction SilentlyContinue | Format-Table -AutoSize"], 40)
    code, _ = run([DOCKER, "version"], 30)
    if code != 0 and not ASSUME_YES:
        if ask_yes("  Docker is installed but not running. Start Docker Desktop, wait until it is ready, then retry? [Y/n]", "y"):
            code, _ = run([DOCKER, "version"], 30)
    if code != 0:
        record("docker.daemon", "WARN", "Docker engine is not running", "exit %s" % code,
               "Start Docker Desktop and re-run. On Windows, check WSL2 and BIOS virtualization in the diagnostics. " + DOCKER_FALLBACK)
        record("docker.pull", "SKIP", "Docker image and container checks not run", "the Docker engine is not running")
        return
    record("docker.daemon", "PASS", "Docker engine is running")
    run([DOCKER, "info"], 30)
    safe("docker.steps", "Docker image and container", check_docker_steps)


def check_install_rights():
    if not IS_ADMIN and MISSING_TOOLS:
        section("Install rights")
        record("sys.installs", "WARN", "IT must install: " + ", ".join(MISSING_TOOLS), "this account has no admin rights",
               "Installs are the most common day-of blocker, so request these before the workshop.")


# ---------------------------------------------------------------- main
def remove_tree(path):
    def retry_writable(func, target, _):
        try:
            os.chmod(target, 0o700)  # Git marks objects read-only, which blocks deletion on Windows
            func(target)
        except OSError:
            pass
    shutil.rmtree(path, onerror=retry_writable)


def cleanup():
    if DOCKER:
        run([DOCKER, "rmi", "-f", PROBE_IMAGE], 30)
    write_report()
    if WORK and os.path.isdir(WORK):
        remove_tree(WORK)


def reveal_report():
    if ASSUME_YES or not REPORT_PATH:
        return
    try:
        if IS_MAC:
            subprocess.call(["open", "-R", REPORT_PATH], timeout=15)
        elif IS_WINDOWS:
            subprocess.Popen(["explorer", "/select,", REPORT_PATH])
    except Exception:
        pass


def main():
    global ASSUME_YES, SKIP_DOCKER, WORK, RESULTS, LOG, USE_COLOR, INTERRUPTED
    args = sys.argv[1:]
    if "--stage" in args:
        stage_venv()
        return 0
    unknown = [arg for arg in args if arg not in ("--yes", "-y", "--skip-docker")]
    if unknown:
        print("Unknown option: %s (valid: --yes, --skip-docker)" % " ".join(unknown))
        return 2
    ASSUME_YES = "--yes" in args or "-y" in args or not sys.stdin.isatty()
    SKIP_DOCKER = "--skip-docker" in args
    sys.stdout.reconfigure(errors="replace")
    USE_COLOR = sys.stdout.isatty()
    if IS_WINDOWS:
        os.system("")  # turns on ANSI colors in the Windows console
    WORK = tempfile.mkdtemp(prefix="workshop-preflight.")
    RESULTS = os.path.join(WORK, "results.tsv")
    LOG = os.path.join(WORK, "details.log")
    open(RESULTS, "w").close()
    open(LOG, "w").close()
    os.environ["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"

    print("Workshop laptop preflight")
    print("Checks that this laptop is ready for the workshop. Please let it run to the end; a failed check will not stop it.")
    print("It installs nothing system-wide: Python packages go in a temporary folder that is")
    print("deleted at the end. Docker may keep one downloaded base image, to save time on the day.")
    print("It ends by writing a report file to send to your instructor. API keys are never included.")
    try:
        for check_id, title, check in (
            ("settings", "Settings", configure),
            ("laptop", "Laptop", check_laptop),
            ("terminal", "Terminal", check_terminal),
            ("network", "Network", check_network),
            ("openai", "OpenAI", check_openai_key),
            ("langfuse", "Langfuse", check_langfuse),
            ("python", "Python", check_python),
            ("git", "Git", check_git),
            ("ide", "IDE", check_ide),
            ("docker", "Docker", check_docker),
            ("rights", "Install rights", check_install_rights),
        ):
            safe(check_id, title, check)
    except KeyboardInterrupt:
        INTERRUPTED = True
        print("\nInterrupted. Writing a partial report.")
        if CURRENT_PROC is not None:
            kill_tree(CURRENT_PROC)
    rows = read_rows()
    cleanup()
    print("\n== Result ==")
    print("  Verdict: " + verdict(rows))
    print("  PASS %d | WARN %d | FAIL %d | SKIP %d" % (count("PASS", rows), count("WARN", rows), count("FAIL", rows), count("SKIP", rows)))
    print("  Run time: %d min %d s\n" % divmod(int(time.time() - STARTED), 60))
    if REPORT_PATH:
        print("  Report saved to:\n  %s\n\n  Please send this file to your instructor." % REPORT_PATH)
    else:
        print("  The report could not be saved. Please send a screenshot of this window to your instructor.")
    reveal_report()
    return 1 if count("FAIL", rows) else 0


if __name__ == "__main__":
    sys.exit(main())
