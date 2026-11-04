#!/usr/bin/env python3
"""Python-level checks shared by the macOS and Windows preflight scripts.

The "base" stage uses only the standard library, because the interpreter under
test may have nothing installed. It creates a throwaway venv and re-runs this
file inside it for the "venv" stage. Nothing is installed outside the work
directory. Configuration arrives through PF_* environment variables.
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request
import uuid

WORK = os.environ["PF_WORK"]
RESULTS = os.environ["PF_RESULTS"]
LOG = os.environ["PF_LOG"]
INDEX_URL = os.environ.get("PF_PIP_INDEX_URL", "https://pypi.org/simple")
PACKAGES = os.environ.get("PF_PIP_PACKAGES", "openai langfuse").split()
BASE_URL = os.environ.get("PF_OPENAI_BASE_URL", "https://api.openai.com/v1")
MODELS = os.environ.get("PF_OPENAI_MODEL", "gpt-4o-mini").split()
API_KEY = os.environ.get("PF_OPENAI_API_KEY", "")
LANGFUSE_HOST = os.environ.get("PF_LANGFUSE_HOST", "https://cloud.langfuse.com")
JUPYTER_PACKAGES = ["jupyterlab", "notebook", "ipykernel", "nbconvert"]
VENV = os.path.join(WORK, "venv")
WINDOWS = os.name == "nt"
VENV_PY = os.path.join(VENV, "Scripts", "python.exe") if WINDOWS else os.path.join(VENV, "bin", "python")
TLS_FIX = (
    "Corporate TLS inspection is the likely cause: the OS trusts the company root CA but Python's "
    "bundled certifi list does not. Ask IT for the root CA as a PEM file, re-run with CA_BUNDLE set, "
    "and set SSL_CERT_FILE and REQUESTS_CA_BUNDLE to it on workshop day."
)


def log(text):
    with open(LOG, "a", encoding="utf-8", errors="replace", newline="\n") as handle:
        handle.write(text.rstrip("\n") + "\n")


def clean(text):
    return re.sub(r"[\t\r\n]+", " ", str(text)).strip()


def record(check_id, status, title, detail="", hint=""):
    with open(RESULTS, "a", encoding="utf-8", errors="replace", newline="\n") as handle:
        handle.write("\t".join(clean(v) for v in (check_id, status, title, detail, hint)) + "\n")
    log("\n[RESULT] %s %s: %s | %s" % (status, check_id, title, clean(detail)))
    print("  [%-4s] %s%s" % (status, title, " - " + clean(detail) if detail else ""), flush=True)
    if hint and status in ("FAIL", "WARN"):
        print("         > " + clean(hint), flush=True)


def safe(check_id, title, func, *args):
    """Run one check so that a crash is reported and the remaining checks still run."""
    try:
        return func(*args)
    except Exception:
        log(traceback.format_exc())
        record(check_id, "FAIL", title + ": check crashed", "", "The remaining checks still ran. The traceback is in the diagnostics.")
        return None


def progress(text):
    print("  ...    " + text, flush=True)


def run(cmd, timeout=120, env=None, cwd=None):
    """Run a command, log its output, and return (exit_code, output). 124 means timed out."""
    log("\n$ " + " ".join(cmd))
    started = time.time()
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            env=env, cwd=cwd, universal_newlines=True, encoding="utf-8", errors="replace",
        )
    except OSError as exc:
        log("could not start: %s" % exc)
        return 127, str(exc)
    try:
        output, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            output, _ = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            output = ""
        code = 124
    output = output or ""
    shown = output if len(output) < 12000 else output[:3000] + "\n...[trimmed]...\n" + output[-9000:]
    log(shown)
    log("[exit %s after %.1fs]" % (code, time.time() - started))
    return code, output


def pip_hint(output):
    rules = (
        (r"CERTIFICATE_VERIFY_FAILED|SSLError|certificate verify failed", TLS_FIX),
        (r"ProxyError|\b407\b|Tunnel connection failed", "The proxy refused the connection. Check the proxy URL; pip cannot do NTLM/Kerberos proxy logins, so IT may need to allowlist PyPI."),
        (r"getaddrinfo failed|Name or service not known|nodename nor servname|Temporary failure in name resolution", "DNS cannot resolve the package index. Connect to VPN or ask IT about pypi.org and files.pythonhosted.org."),
        (r"\b403\b|Forbidden", "The index or proxy returned 403, so a package-filtering policy is likely. Ask IT to allow the packages or give an approved mirror URL."),
        (r"timed out|ReadTimeout|ConnectTimeout", "Connections timed out. A firewall may be dropping traffic to pypi.org or files.pythonhosted.org."),
        (r"Connection refused|NewConnectionError|connection broken|Connection reset", "pip could not connect to the index. A firewall or wrong proxy setting is likely; check the Network results above."),
        (r"No matching distribution|Could not find a version", "The package is missing from this index, or has no build for this Python version and CPU."),
        (r"Permission denied|Access is denied", "File access was denied, possibly by endpoint security software scanning the temp folder."),
    )
    for pattern, hint in rules:
        if re.search(pattern, output, re.I):
            return hint
    return "See the pip output in the diagnostics section of the report."


def pip_install(packages, timeout, no_cache=False, fast_fail=False):
    cmd = [VENV_PY, "-m", "pip", "install", "--disable-pip-version-check", "--index-url", INDEX_URL]
    if no_cache:
        cmd.append("--no-cache-dir")
    if fast_fail:
        # The index already failed once, so do not spend minutes on retries.
        cmd += ["--retries", "1", "--timeout", "15"]
    return run(cmd + packages, timeout=timeout)


def check_pip():
    code, output = run([sys.executable, "-m", "pip", "--version"], timeout=60)
    if code == 0:
        record("python.pip", "PASS", "pip available", output.strip().split(" from ")[0])
    else:
        record("python.pip", "FAIL", "pip not available", "exit %s" % code,
               "Install pip for this Python, or reinstall Python from python.org. Required for all hands-on code.")
    run([sys.executable, "-m", "pip", "config", "list"], timeout=30)
    run([sys.executable, "-c", "import ssl;print(ssl.OPENSSL_VERSION);print(ssl.get_default_verify_paths())"], timeout=30)


def create_venv():
    progress("Creating a temporary virtual environment")
    code, _ = run([sys.executable, "-m", "venv", VENV], timeout=240)
    if code != 0 or not os.path.exists(VENV_PY):
        record("python.venv", "FAIL", "Cannot create a virtual environment", "exit %s" % code,
               "The venv module or ensurepip is missing, or endpoint security blocked it. Reinstall Python from python.org or ask IT.")
        return False
    record("python.venv", "PASS", "Virtual environment created")
    return True


def check_index():
    progress("Downloading a small package straight from the index (no cache)")
    code, output = pip_install(["six"], 180, no_cache=True)
    if code == 0:
        record("pip.index", "PASS", "Package download from the index works", INDEX_URL)
        return True
    record("pip.index", "FAIL", "Cannot download packages from the index", INDEX_URL, pip_hint(output))
    run([VENV_PY, "-m", "pip", "download", "-vvv", "--no-cache-dir", "--no-deps", "--retries", "0",
         "--index-url", INDEX_URL, "-d", os.path.join(WORK, "pipdl"), "six"], timeout=120)
    return False


def install_workshop_packages(index_ok):
    progress("Installing workshop packages (several minutes on a slow network)")
    code, output = pip_install(PACKAGES, 1200, fast_fail=not index_ok)
    if code == 0:
        record("pip.packages", "PASS", "Workshop packages installed", " ".join(PACKAGES))
        return
    if not index_ok:
        record("pip.packages", "FAIL", "Workshop packages failed to install", "the index is not reachable", pip_hint(output))
        return
    # Installing one at a time shows exactly which packages are the problem.
    progress("The combined install failed, so trying each package separately")
    failed = []
    for package in PACKAGES:
        single_code, _ = pip_install([package], 300)
        if single_code != 0:
            failed.append(package)
    record("pip.packages", "FAIL", "Workshop packages failed to install",
           "failed alone: " + (" ".join(failed) if failed else "none, so the packages conflict with each other"), pip_hint(output))


def install_jupyter(index_ok):
    progress("Installing Jupyter (1-5 minutes)")
    code, output = pip_install(JUPYTER_PACKAGES, 900, fast_fail=not index_ok)
    if code == 0:
        record("jupyter.install", "PASS", "Jupyter installed", " ".join(JUPYTER_PACKAGES))
    else:
        record("jupyter.install", "FAIL", "Jupyter failed to install", " ".join(JUPYTER_PACKAGES), pip_hint(output))


def stage_base():
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
    safe("pip.list", "Package list", run, [VENV_PY, "-m", "pip", "list", "--format=freeze", "--disable-pip-version-check"], 60)

    # Run inside the venv, with output going straight to the participant's console.
    try:
        code = subprocess.call([VENV_PY, os.path.abspath(__file__), "--stage", "venv"], timeout=2400)
    except subprocess.TimeoutExpired:
        record("python.venv_stage", "FAIL", "Checks inside the virtual environment timed out", "40 minutes", "The checks finished so far are in the report.")
        return
    if code != 0:
        record("python.venv_stage", "FAIL", "Checks inside the virtual environment crashed", "exit %s" % code,
               "Send the report: the diagnostics section contains the traceback.")


def try_get(url, verify):
    import httpx
    try:
        if verify is None:
            response = httpx.get(url, timeout=20)
        else:
            response = httpx.get(url, timeout=20, verify=verify)
        return True, "HTTP %s" % response.status_code
    except Exception as exc:  # the class and message are the diagnostic
        return False, "%s: %s" % (type(exc).__name__, str(exc)[:200])


def check_python_tls():
    """Compare the SDK's default trust list with the OS store, which pinpoints TLS inspection."""
    try:
        import httpx  # noqa: F401
    except ImportError as exc:
        record("tls.python", "WARN", "Python TLS check skipped", "httpx not installed: %s" % exc)
        return
    try:
        import ssl
        import truststore
        os_store = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except Exception as exc:
        log("truststore unavailable: %s" % exc)
        os_store = None

    openai_url = BASE_URL.rstrip("/") + "/models"
    targets = [(openai_url, True), (LANGFUSE_HOST.rstrip("/") + "/api/public/health", False)]
    failures, required_failed, inspected = [], False, False
    for url, required in targets:
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
    for spec in PACKAGES:
        name = re.split(r"[=<>!~\[ ]", spec)[0].lower()
        module = renamed.get(name, name.replace("-", "_"))
        code, _ = run([sys.executable, "-c", "import " + module], timeout=180)
        if code != 0:
            failed.append(module)
    if failed:
        record("pip.imports", "FAIL", "Some workshop packages cannot be imported", " ".join(failed),
               "They may have failed to install, or endpoint security may be blocking compiled modules. See the diagnostics.")
    else:
        record("pip.imports", "PASS", "Workshop packages import correctly")


def check_openai_model(openai, client, model):
    messages = [{"role": "user", "content": "Reply with the single word: ready"}]
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
            "AuthenticationError": "The key was rejected. Check it was pasted completely and has not been revoked.",
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
        record("openai.sdk." + model, "FAIL", "OpenAI SDK chat call failed", "%s (model %s)" % (name, model), hint)
        return
    record("openai.sdk." + model, "PASS", "OpenAI SDK chat call works", "model %s, SDK %s" % (model, openai.__version__))


def check_openai_sdk():
    if not API_KEY:
        record("openai.sdk", "WARN", "OpenAI SDK call not tested", "no API key provided",
               "Re-run with a key to prove the agent and LLM judges will work.")
        return
    try:
        import openai
    except ImportError as exc:
        record("openai.sdk", "FAIL", "OpenAI SDK cannot be imported", str(exc), "The openai package did not install; see the pip check.")
        return
    client = openai.OpenAI(api_key=API_KEY, base_url=BASE_URL, timeout=45, max_retries=0)
    for model in MODELS:
        safe("openai.sdk." + model, "OpenAI SDK call", check_openai_model, openai, client, model)


def jupyter_env():
    """Isolate Jupyter so it neither reads nor writes the participant's own config."""
    env = os.environ.copy()
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
    code, output = run([VENV_PY, "-m", "jupyter", "nbconvert", "--to", "notebook", "--execute", path,
                        "--output", "preflight_out.ipynb", "--ExecutePreprocessor.timeout=180"],
                       timeout=300, env=env, cwd=root)
    text = ""
    result = os.path.join(root, "preflight_out.ipynb")
    if os.path.exists(result):
        with open(result, encoding="utf-8") as handle:
            text = handle.read()
    if code == 0 and "PF_KERNEL_42" in text and "PF_IMPORTS_OK" in text:
        record("jupyter.notebook", "PASS", "Notebook kernel executes code", "ran a test notebook, including SDK imports")
        return
    if "PF_KERNEL_42" in text:
        record("jupyter.notebook", "FAIL", "Notebook kernel runs but SDK imports failed", "exit %s" % code,
               "Check the package install result; the traceback is in the diagnostics.")
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

    async def session():
        request = HTTPRequest("ws://127.0.0.1:%d/terminals/websocket/%s" % (port, name),
                              headers={"Authorization": "token " + token}, connect_timeout=15)
        socket_conn = await websocket_connect(request)
        seen, sent, deadline = "", False, time.time() + 40
        pending = None
        while time.time() < deadline:
            if pending is None:
                pending = asyncio.ensure_future(socket_conn.read_message())
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
                socket_conn.write_message(json.dumps(["stdin", command]))
                sent = True
            plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", seen)
            # cmd.exe keeps the quotes when it echoes, so there input and output both match.
            if "PF_TERM_OK" in plain or plain.count('PF_"TERM"_OK') >= 2:
                socket_conn.close()
                return True, plain[-300:]
        socket_conn.close()
        return False, re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", seen)[-500:]

    if WINDOWS:
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    return asyncio.run(session())


def check_jupyterlab(env, root):
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 8888)) == 0:
            log("Port 8888 is already in use; Jupyter will pick another port on the day.")
    with socket.socket() as free:
        free.bind(("127.0.0.1", 0))
        port = free.getsockname()[1]
    token = uuid.uuid4().hex
    server_log = open(os.path.join(WORK, "jupyter_server.log"), "w", encoding="utf-8", errors="replace")
    server = subprocess.Popen(
        [VENV_PY, "-m", "jupyterlab", "--no-browser", "--ServerApp.ip=127.0.0.1",
         "--ServerApp.port=%d" % port, "--ServerApp.port_retries=0",
         "--ServerApp.token=" + token, "--ServerApp.root_dir=" + root, "--ServerApp.allow_root=True"],
        stdout=server_log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, cwd=root,
    )
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

        status, body = local_http(base + "/api/terminals", token, method="POST")
        if status != 200:
            record("jupyter.terminal", "WARN", "Jupyter terminal could not start", "HTTP %s" % status,
                   "Participants can use the OS terminal instead.")
            return
        name = ""
        try:
            name = json.loads(body)["name"]
            worked, transcript = terminal_roundtrip(port, token, name)
        except Exception as exc:
            worked, transcript = False, "%s: %s" % (type(exc).__name__, exc)
        log("Jupyter terminal transcript: %s" % transcript)
        if name:
            local_http(base + "/api/terminals/" + name, token, method="DELETE")
        if worked:
            record("jupyter.terminal", "PASS", "Jupyter terminal runs commands", "sent a command and read its output")
        else:
            record("jupyter.terminal", "WARN", "Jupyter terminal did not respond", "",
                   "Participants can use the OS terminal instead. The transcript is in the diagnostics.")
    finally:
        local_http(base + "/api/shutdown", token, method="POST")
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill()
        server_log.close()
        with open(os.path.join(WORK, "jupyter_server.log"), encoding="utf-8", errors="replace") as handle:
            log("\n--- JupyterLab server log (last 6000 characters) ---\n" + handle.read()[-6000:])


def stage_venv():
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
    safe("jupyter.kernelspec", "Kernel list", run, [VENV_PY, "-m", "jupyter", "kernelspec", "list"], 60, env)
    safe("jupyter.notebook", "Notebook kernel", check_notebook, env, root)
    progress("Starting JupyterLab and testing its terminal")
    safe("jupyter.lab", "JupyterLab", check_jupyterlab, env, root)


if __name__ == "__main__":
    if "--stage" in sys.argv and sys.argv[sys.argv.index("--stage") + 1] == "venv":
        stage_venv()
    else:
        stage_base()
