#!/bin/bash
# Workshop preflight for macOS. Run with: bash preflight_mac.sh
# Options: --yes (accept defaults, no prompts)  --skip-docker
#
# Needs nothing beyond what ships with macOS, because Python itself is under test.
# Written for the bash 3.2 that macOS includes.

# Deliberately no "set -e" or "set -u": a failed check must never stop the checks after it.
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/workshop-preflight.XXXXXX")"
RESULTS="$WORK/results.tsv"
LOG="$WORK/details.log"
REPORT="$HOME/workshop-preflight-report-$TS.txt"
ASSUME_YES=0
SKIP_DOCKER=0
LAST_OUT=""
LAST_RC=0
INSPECTED=""
OPENAI_API_KEY_VALUE=""
LANGFUSE_PK=""
LANGFUSE_SK=""
REPORT_DONE=0
: > "$RESULTS"
: > "$LOG"

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --skip-docker) SKIP_DOCKER=1 ;;
    *) echo "Unknown option: $arg (valid: --yes, --skip-docker)"; exit 2 ;;
  esac
done
[ -t 0 ] || ASSUME_YES=1

for needed in defaults.conf preflight_checks.py docker_probe/Dockerfile; do
  if [ ! -f "$HERE/$needed" ]; then
    echo "Missing $needed. Extract the whole zip into a folder and run the script from there."
    exit 2
  fi
done

# ---------------------------------------------------------------- output helpers
if [ -t 1 ]; then
  C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_SKIP=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_PASS=""; C_WARN=""; C_FAIL=""; C_SKIP=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_OFF"
  printf '\n\n======== %s ========\n' "$1" >> "$LOG"
}

progress() { printf '  %s...    %s%s\n' "$C_DIM" "$1" "$C_OFF"; }

note() { printf '%s\n' "$1" >> "$LOG"; }

one_line() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# record ID STATUS TITLE [DETAIL] [HINT]
record() {
  local id="$1" status="$2" title="$3" detail="${4:-}" hint="${5:-}" color="$C_PASS"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$status" "$(one_line "$title")" "$(one_line "$detail")" "$(one_line "$hint")" >> "$RESULTS"
  printf '\n[RESULT] %s %s: %s | %s\n' "$status" "$id" "$title" "$detail" >> "$LOG"
  case "$status" in
    WARN) color="$C_WARN" ;;
    FAIL) color="$C_FAIL" ;;
    SKIP) color="$C_SKIP" ;;
  esac
  printf '  [%s%-4s%s] %s' "$color" "$status" "$C_OFF" "$title"
  [ -n "$detail" ] && printf ' - %s' "$detail"
  printf '\n'
  if [ -n "$hint" ] && { [ "$status" = "FAIL" ] || [ "$status" = "WARN" ]; }; then
    printf '         > %s\n' "$hint"
  fi
}

# run SECONDS CMD ARGS...: logs everything, sets LAST_OUT (a file) and LAST_RC. 124 = timed out.
run() {
  local secs="$1" start pid dog
  shift
  start=$(date +%s)
  LAST_OUT="$WORK/out.$RANDOM$RANDOM"
  printf '\n$ %s\n' "$*" >> "$LOG"
  "$@" > "$LAST_OUT" 2>&1 < /dev/null &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) > /dev/null 2>&1 &
  dog=$!
  wait "$pid"
  LAST_RC=$?
  pkill -P "$dog" sleep 2>/dev/null
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  case "$LAST_RC" in 137|143) LAST_RC=124 ;; esac
  tail -n 150 "$LAST_OUT" >> "$LOG"
  printf '[exit %s after %ss]\n' "$LAST_RC" "$(( $(date +%s) - start ))" >> "$LOG"
  return 0
}

ask_yes() { # ask_yes PROMPT DEFAULT(y|n)
  local answer=""
  if [ "$ASSUME_YES" = 1 ]; then [ "$2" = y ]; return; fi
  read -r -p "$1 " answer
  answer="$(printf '%s' "${answer:-$2}" | tr '[:upper:]' '[:lower:]')"
  case "$answer" in y|yes) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- report
scrub() {
  PF_S1="$OPENAI_API_KEY_VALUE" PF_S2="$LANGFUSE_PK" PF_S3="$LANGFUSE_SK" PF_USER="$(id -un)" PF_HOST="$(hostname -s 2>/dev/null)" awk '
    function swap(text, from, to,   at, out) {
      out = ""
      while ((at = index(text, from)) > 0) { out = out substr(text, 1, at - 1) to; text = substr(text, at + length(from)) }
      return out text
    }
    BEGIN {
      s[1] = ENVIRON["PF_S1"]; s[2] = ENVIRON["PF_S2"]; s[3] = ENVIRON["PF_S3"]
      u = ENVIRON["PF_USER"]; h = ENVIRON["PF_HOST"]
    }
    {
      for (i = 1; i <= 3; i++) if (length(s[i]) > 0) $0 = swap($0, s[i], "***REDACTED***")
      if (length(u) >= 3) $0 = swap($0, u, "<user>")
      if (length(h) >= 3) $0 = swap($0, h, "<host>")
      print
    }' | sed -E \
      -e 's/sk-[A-Za-z0-9_*-]{8,}/sk-***REDACTED***/g' \
      -e 's/pk-lf-[A-Za-z0-9-]+/pk-lf-***REDACTED***/g' \
      -e 's/gh[pousr]_[A-Za-z0-9]{20,}/gh*_***REDACTED***/g' \
      -e 's/github_pat_[A-Za-z0-9_]+/github_pat_***REDACTED***/g' \
      -e 's/(Bearer|Basic) [A-Za-z0-9._~+\/=-]{8,}/\1 ***REDACTED***/g' \
      -e 's/([?&]token=)[^&[:space:]]+/\1***REDACTED***/g' \
      -e 's/(ServerApp\.token=)[^[:space:]]+/\1***REDACTED***/g' \
      -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g'
}

count_status() { awk -F'\t' -v s="$1" '$2 == s { n++ } END { print n + 0 }' "$RESULTS"; }

verdict() {
  if [ "$(count_status FAIL)" -gt 0 ]; then echo "NOT READY - required items failed"
  elif [ "$(count_status WARN)" -gt 0 ]; then echo "READY WITH WARNINGS - see the items below"
  else echo "READY"
  fi
}

write_report() {
  [ "$REPORT_DONE" = 1 ] && return
  REPORT_DONE=1
  {
    echo "WORKSHOP PREFLIGHT REPORT"
    echo "Created:   $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Platform:  macOS $(sw_vers -productVersion 2>/dev/null) on $(uname -m)"
    echo "Verdict:   $(verdict)"
    echo "Counts:    PASS $(count_status PASS) | WARN $(count_status WARN) | FAIL $(count_status FAIL) | SKIP $(count_status SKIP)"
    [ "${INTERRUPTED:-0}" = 1 ] && echo "NOTE:      The run was interrupted, so this report is partial."
    echo
    echo "---- SUMMARY ----"
    awk -F'\t' '{ printf "%-5s %-20s %s", $2, $1, $3; if ($4 != "") printf " - %s", $4; printf "\n" }' "$RESULTS"
    echo
    echo "---- PROBLEMS AND LIKELY CAUSES ----"
    awk -F'\t' '($2 == "FAIL" || $2 == "WARN") { printf "%s %s: %s\n", $2, $1, $3; if ($4 != "") printf "    Detail: %s\n", $4; if ($5 != "") printf "    Likely cause / fix: %s\n", $5; printf "\n"; found = 1 } END { if (!found) print "None.\n" }' "$RESULTS"
    echo "---- SETTINGS USED ----"
    echo "OpenAI URL:     ${OPENAI_BASE_URL:-}"
    echo "OpenAI models:  ${OPENAI_MODEL:-}"
    echo "OpenAI key:     $([ -n "$OPENAI_API_KEY_VALUE" ] && echo provided || echo 'not provided')"
    echo "Langfuse host:  ${LANGFUSE_HOST:-}"
    echo "Langfuse keys:  $([ -n "$LANGFUSE_PK" ] && [ -n "$LANGFUSE_SK" ] && echo provided || echo 'not provided')"
    echo "Git test repo:  ${GIT_REPO_URL:-}"
    echo "Pip index:      ${PIP_INDEX_URL:-}"
    echo "Pip packages:   ${PIP_PACKAGES:-}"
    echo "Docker images:  ${DOCKER_TEST_IMAGE:-} ${DOCKER_BASE_IMAGE:-}"
    echo "Proxy:          ${PROXY_EFFECTIVE:-none}"
    echo "CA bundle:      ${CA_BUNDLE:-none}"
    echo
    echo "---- FULL DIAGNOSTICS ----"
    cat "$LOG"
  } | scrub > "$REPORT"
  if [ ! -s "$REPORT" ]; then
    REPORT="${TMPDIR:-/tmp}/workshop-preflight-report-$TS.txt"
    { cat "$RESULTS"; cat "$LOG"; } | scrub > "$REPORT"
  fi
}

finish() {
  local code=$?
  trap - EXIT INT TERM
  [ -n "${HELPER_PID:-}" ] && kill "$HELPER_PID" 2>/dev/null
  [ -n "${DOCKER_BIN:-}" ] && "$DOCKER_BIN" rmi -f workshop-preflight-probe > /dev/null 2>&1
  write_report
  rm -rf "$WORK"
  exit "$code"
}
trap finish EXIT
trap 'INTERRUPTED=1; echo; echo "Interrupted. Writing a partial report."; exit 130' INT TERM

# ---------------------------------------------------------------- settings
load_defaults() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      OPENAI_BASE_URL|OPENAI_MODEL|LANGFUSE_HOST|GIT_REPO_URL|PIP_INDEX_URL|PIP_PACKAGES|DOCKER_TEST_IMAGE|DOCKER_BASE_IMAGE|PROXY_URL|CA_BUNDLE)
        printf -v "$key" '%s' "$value" ;;
    esac
  done < "$HERE/defaults.conf"
}

# Optional keys.env beside the script supplies keys, so participants are not asked for them.
load_keys() {
  local line key value
  [ -f "$HERE/keys.env" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#export }"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
    case "$key" in
      OPENAI_API_KEY) OPENAI_API_KEY_VALUE="$value" ;;
      LANGFUSE_PUBLIC_KEY) LANGFUSE_PK="$value" ;;
      LANGFUSE_SECRET_KEY) LANGFUSE_SK="$value" ;;
      LANGFUSE_BASE_URL|LANGFUSE_HOST) [ -n "$value" ] && LANGFUSE_HOST="$value" ;;
    esac
  done < "$HERE/keys.env"
}

SYS_PROXY=""
SYS_PAC=""
detect_system_proxy() {
  local info enabled host port
  info="$(scutil --proxy 2>/dev/null)"
  enabled="$(printf '%s\n' "$info" | awk '$1 == "HTTPSEnable" { print $3 }')"
  if [ "$enabled" = 1 ]; then
    host="$(printf '%s\n' "$info" | awk '$1 == "HTTPSProxy" { print $3 }')"
    port="$(printf '%s\n' "$info" | awk '$1 == "HTTPSPort" { print $3 }')"
    [ -n "$host" ] && SYS_PROXY="http://$host:${port:-8080}"
  fi
  if [ "$(printf '%s\n' "$info" | awk '$1 == "ProxyAutoConfigEnable" { print $3 }')" = 1 ]; then
    SYS_PAC="$(printf '%s\n' "$info" | awk '$1 == "ProxyAutoConfigURLString" { print $3 }')"
  fi
}

resolve_proxy() {
  local env_proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  case "$PROXY_URL" in
    auto|"") PROXY_EFFECTIVE="${env_proxy:-$SYS_PROXY}" ;;
    none) PROXY_EFFECTIVE="" ;;
    *) PROXY_EFFECTIVE="$PROXY_URL" ;;
  esac
}

show_settings() {
  resolve_proxy
  cat <<EOF

  1. OpenAI API URL      $OPENAI_BASE_URL
  2. OpenAI models       $OPENAI_MODEL
  3. Langfuse host       $LANGFUSE_HOST
  4. Git test repo       $GIT_REPO_URL
  5. Pip index           $PIP_INDEX_URL
  6. Pip test packages   $PIP_PACKAGES
  7. Docker test image   $DOCKER_TEST_IMAGE
  8. Docker base image   $DOCKER_BASE_IMAGE
  9. Proxy               $PROXY_URL (currently: ${PROXY_EFFECTIVE:-direct connection})
 10. Corporate CA file   ${CA_BUNDLE:-none}

EOF
}

edit_setting() { # edit_setting VAR LABEL
  local current="${!1}" answer
  read -r -p "  $2 [${current:-empty}]: " answer
  if [ "$answer" = "-" ]; then printf -v "$1" '%s' ""
  elif [ -n "$answer" ]; then printf -v "$1" '%s' "$answer"
  fi
}

read_secret() { # read_secret VAR ENV_NAME LABEL
  local value="" existing="${!2:-}"
  [ -n "${!1}" ] && return
  if [ -n "$existing" ]; then
    if ask_yes "  $2 is already set in this terminal. Use it? [Y/n]" y; then printf -v "$1" '%s' "$existing"; return; fi
  fi
  [ "$ASSUME_YES" = 1 ] && return
  read -r -s -p "  $3 (hidden, Enter to skip): " value
  echo
  printf -v "$1" '%s' "$(printf '%s' "$value" | tr -d '[:space:]')"
}

configure() {
  load_defaults
  load_keys
  detect_system_proxy
  section "Settings"
  show_settings
  [ -n "$SYS_PAC" ] && echo "  Note: this Mac uses an automatic proxy script (PAC). If checks fail, enter your proxy URL in item 9."
  if ! ask_yes "Use these settings? [Y/n]" y; then
    echo "  Press Enter to keep a value, or type a new one. Enter - to clear it. Proxy accepts auto, none, or a URL."
    edit_setting OPENAI_BASE_URL "OpenAI API URL"
    edit_setting OPENAI_MODEL "OpenAI models (space separated)"
    edit_setting LANGFUSE_HOST "Langfuse host"
    edit_setting GIT_REPO_URL "Git test repo"
    edit_setting PIP_INDEX_URL "Pip index"
    edit_setting PIP_PACKAGES "Pip test packages"
    edit_setting DOCKER_TEST_IMAGE "Docker test image"
    edit_setting DOCKER_BASE_IMAGE "Docker base image"
    edit_setting PROXY_URL "Proxy"
    edit_setting CA_BUNDLE "Corporate CA file"
    show_settings
  fi

  echo "API keys are used only for test calls. They are never saved and are removed from the report."
  [ -f "$HERE/keys.env" ] && echo "  Using the keys supplied in keys.env."
  read_secret OPENAI_API_KEY_VALUE OPENAI_API_KEY "OpenAI API key"
  read_secret LANGFUSE_PK LANGFUSE_PUBLIC_KEY "Langfuse public key"
  read_secret LANGFUSE_SK LANGFUSE_SECRET_KEY "Langfuse secret key"

  OPENAI_BASE_URL="${OPENAI_BASE_URL%/}"
  LANGFUSE_HOST="${LANGFUSE_HOST%/}"
  PIP_INDEX_URL="${PIP_INDEX_URL%/}"

  resolve_proxy
  if [ -n "$PROXY_EFFECTIVE" ]; then
    export HTTP_PROXY="$PROXY_EFFECTIVE" HTTPS_PROXY="$PROXY_EFFECTIVE" http_proxy="$PROXY_EFFECTIVE" https_proxy="$PROXY_EFFECTIVE"
  else
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
  fi
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"

  if [ -n "$CA_BUNDLE" ]; then
    if [ -f "$CA_BUNDLE" ]; then
      export SSL_CERT_FILE="$CA_BUNDLE" REQUESTS_CA_BUNDLE="$CA_BUNDLE" PIP_CERT="$CA_BUNDLE" CURL_CA_BUNDLE="$CA_BUNDLE" GIT_SSL_CAINFO="$CA_BUNDLE"
    else
      record config.ca WARN "Corporate CA file not found" "$CA_BUNDLE" "Check the path. Continuing without it."
      CA_BUNDLE=""
    fi
  fi
}

# ---------------------------------------------------------------- system
check_system() {
  section "Laptop"
  local ram_bytes ram_gb free_kb free_gb
  run 15 sw_vers
  run 15 uname -a
  run 15 sysctl -n machdep.cpu.brand_string
  record sys.os PASS "macOS $(sw_vers -productVersion 2>/dev/null)" "$(uname -m), $(sysctl -n hw.ncpu 2>/dev/null) CPU cores"

  ram_bytes="$(sysctl -n hw.memsize 2>/dev/null)"
  ram_gb=$(( ${ram_bytes:-0} / 1073741824 ))
  if [ "$ram_gb" -ge 16 ]; then record sys.ram PASS "RAM ${ram_gb} GB"
  elif [ "$ram_gb" -ge 8 ]; then record sys.ram WARN "RAM ${ram_gb} GB" "meets the 8 GB minimum" "16 GB is recommended for Docker. Close other apps during the workshop."
  else record sys.ram FAIL "RAM ${ram_gb} GB" "below the 8 GB minimum" "Use a laptop with at least 8 GB of RAM."
  fi

  free_kb="$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  free_gb=$(( ${free_kb:-0} / 1048576 ))
  if [ "$free_gb" -ge 15 ]; then record sys.disk PASS "Free disk ${free_gb} GB"
  elif [ "$free_gb" -ge 5 ]; then record sys.disk WARN "Free disk ${free_gb} GB" "" "15 GB or more is recommended for Docker images and Python packages."
  else record sys.disk FAIL "Free disk ${free_gb} GB" "" "Free at least 5 GB. Python packages alone need about 1 GB."
  fi

  if id -Gn | tr ' ' '\n' | grep -qx admin; then IS_ADMIN=1; record sys.admin PASS "Account has admin rights"
  else IS_ADMIN=0; record sys.admin WARN "Account does not have admin rights" "" "IT must pre-install anything reported missing below."
  fi

  run 20 profiles status -type enrollment
  run 20 pgrep -il 'zscaler|netskope|falcon|crowdstrike|sentinel|cylance|globalprotect|anyconnect|forticlient|umbrella|carbonblack|tanium|jamf'
  run 15 scutil --nc list
}

check_terminal() {
  section "Terminal"
  local probe="$WORK/terminal_probe.sh"
  printf '#!/bin/sh\necho PF_SHELL_OK\n' > "$probe"
  run 15 /bin/sh "$probe"
  if grep -q PF_SHELL_OK "$LAST_OUT"; then
    record term.shell PASS "Terminal runs commands and scripts" "login shell ${SHELL:-unknown}, terminal ${TERM_PROGRAM:-unknown}"
  else
    record term.shell FAIL "Terminal could not run a test script" "exit $LAST_RC" "Endpoint security may block scripts in the temp folder. Ask IT."
  fi
  run 15 /bin/zsh -c 'echo PF_ZSH_OK'
  grep -q PF_ZSH_OK "$LAST_OUT" || record term.zsh WARN "zsh did not run" "exit $LAST_RC"
  run 15 /usr/bin/stat -f '%Sp %Su' "$WORK"
  note "PATH=$PATH"
  note "SHELL=${SHELL:-} TERM=${TERM:-} TERM_PROGRAM=${TERM_PROGRAM:-}"
}

# ---------------------------------------------------------------- network
PUBLIC_CA='Let.s Encrypt|DigiCert|Sectigo|Google Trust|Amazon|Cloudflare|GlobalSign|GoDaddy|Entrust|Microsoft|Baltimore|ZeroSSL|Starfield|SSL\.com|Certainly|COMODO|IdenTrust|ISRG|USERTrust|Fastly'

curl_hint() { # curl_hint EXIT_CODE
  case "$1" in
    5) echo "The proxy host name cannot be resolved. Check the proxy URL." ;;
    6) echo "DNS cannot resolve this host. Connect to VPN, or ask IT whether it is blocked." ;;
    7) if [ -n "${PROXY_EFFECTIVE:-}" ]; then echo "Could not connect through the configured proxy. Check the proxy URL, or try proxy setting none."
       else echo "The connection was refused or blocked. A firewall or missing proxy setting is likely."; fi ;;
    28) echo "The connection timed out. A firewall is probably dropping traffic, or a proxy is needed." ;;
    35) echo "The TLS handshake failed. A firewall or inspection proxy may be interfering." ;;
    52|56) echo "The connection was dropped after it opened. A proxy or firewall is likely closing it." ;;
    60|77) echo "The certificate is not trusted, which usually means corporate TLS inspection. Ask IT for the root CA file and set CA_BUNDLE." ;;
    97) echo "The proxy handshake failed. Check the proxy URL." ;;
    *) echo "curl failed with exit code $1. See the diagnostics." ;;
  esac
}

# check_url ID LABEL URL SEVERITY [allow403]
check_url() {
  local id="$1" label="$2" url="$3" severity="$4" allow403="${5:-0}" body="$WORK/body" info code rc issuer detail host
  host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  run 25 curl -sS -o "$body" --connect-timeout 10 -m 20 -w '%{http_code} ip=%{remote_ip} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s' "$url"
  rc=$LAST_RC
  info="$(tail -n 1 "$LAST_OUT")"
  code="${info%% *}"
  run 20 curl -vk -sS -o /dev/null --connect-timeout 8 -m 15 "$url"
  issuer="$(sed -n 's/^\*[[:space:]]*issuer: //p' "$LAST_OUT" | head -n 1)"
  detail="$host"
  [ -n "$issuer" ] && detail="$detail, cert issuer: $issuer"
  if [ -n "$issuer" ] && ! printf '%s' "$issuer" | grep -Eq "$PUBLIC_CA"; then
    INSPECTED="$INSPECTED $host [$issuer];"
  fi

  if [ "$rc" != 0 ]; then
    run 15 /usr/bin/dscacheutil -q host -a name "$host"
    record "$id" "$severity" "$label: not reachable" "$detail, curl exit $rc" "$(curl_hint "$rc")"
  elif [ "$code" = 407 ]; then
    record "$id" "$severity" "$label: proxy login required" "$detail, HTTP 407" "The proxy wants a login that tools cannot provide. Ask IT to allowlist this host."
  elif [ "$code" = 403 ] && [ "$allow403" = 0 ]; then
    head -c 800 "$body" >> "$LOG"; echo >> "$LOG"
    record "$id" "$severity" "$label: blocked (HTTP 403)" "$detail" "This may be a URL filter. The response body is in the diagnostics. Ask IT to allowlist this host."
  elif [ "$code" -ge 500 ] 2>/dev/null; then
    head -c 800 "$body" >> "$LOG"; echo >> "$LOG"
    record "$id" "$severity" "$label: server or gateway error" "$detail, HTTP $code" "This is a proxy or temporary service problem. Retry, then ask IT if it persists."
  else
    record "$id" PASS "$label reachable" "$detail, HTTP $code"
  fi
}

check_network() {
  section "Network"
  note "Effective proxy: ${PROXY_EFFECTIVE:-none}"
  run 15 scutil --proxy
  run 15 scutil --dns
  run 15 curl --version
  check_url net.openai "OpenAI API" "$OPENAI_BASE_URL/models" FAIL
  check_url net.pypi "Package index" "$PIP_INDEX_URL/pip/" FAIL
  case "$PIP_INDEX_URL" in
    https://pypi.org/*) check_url net.pythonhosted "PyPI file downloads" "https://files.pythonhosted.org/" FAIL ;;
  esac
  check_url net.github "GitHub" "https://github.com" WARN
  check_url net.codeload "GitHub downloads" "https://codeload.github.com" WARN
  check_url net.dockerhub "Docker Hub registry" "https://registry-1.docker.io/v2/" WARN
  check_url net.dockerauth "Docker Hub login service" "https://auth.docker.io/token" WARN
  check_url net.dockercdn "Docker Hub image CDN" "https://production.cloudflare.docker.com/" WARN 1
  check_url net.vscode "VS Code extensions" "https://marketplace.visualstudio.com" WARN
  check_url net.openvsx "Cursor extensions (Open VSX)" "https://open-vsx.org" WARN
  check_url net.langfuse_us "Langfuse US region" "https://us.cloud.langfuse.com" WARN

  if [ -n "$INSPECTED" ]; then
    record net.tls_inspection WARN "TLS inspection detected" "$INSPECTED" "HTTPS is being re-signed by a non-public CA. Python and Docker may not trust it even when browsers do; see the Python and Docker results."
  else
    record net.tls_inspection PASS "No TLS inspection detected" "all sampled certificates come from public CAs"
  fi
}

# Keys go through a private curl config file so they never appear in a process list.
curl_with_secret() { # curl_with_secret CONFIG_LINE URL
  local cfg="$WORK/curl.cfg"
  printf '%s\n' "$1" > "$cfg"
  run 40 curl -sS -K "$cfg" -o "$WORK/api_body" --connect-timeout 10 -m 30 -w '%{http_code}' "$2"
  rm -f "$cfg"
  API_CODE="$(tail -n 1 "$LAST_OUT")"
  API_RC=$LAST_RC
  head -c 600 "$WORK/api_body" >> "$LOG" 2>/dev/null
  echo >> "$LOG"
}

check_openai_api() {
  section "OpenAI API"
  if [ -z "$OPENAI_API_KEY_VALUE" ]; then
    record openai.key WARN "OpenAI key not tested" "no key entered" "Re-run with a key to prove API access. Required for the agent and LLM judges."
    return
  fi
  curl_with_secret "header = \"Authorization: Bearer $OPENAI_API_KEY_VALUE\"" "$OPENAI_BASE_URL/models"
  if [ "$API_RC" != 0 ]; then
    record openai.key FAIL "OpenAI API call failed" "curl exit $API_RC" "$(curl_hint "$API_RC")"
    return
  fi
  case "$API_CODE" in
    200)
      local model missing=""
      for model in $OPENAI_MODEL; do
        grep -q "\"$model\"" "$WORK/api_body" || missing="$missing $model"
      done
      if [ -z "$missing" ]; then
        record openai.key PASS "OpenAI key accepted" "available: $OPENAI_MODEL"
      else
        record openai.key WARN "OpenAI key accepted, but a model is not listed" "$missing" "Choose models this key's project can use."
      fi ;;
    401) record openai.key FAIL "OpenAI rejected the key" "HTTP 401" "Check it was pasted completely and has not been revoked." ;;
    403) record openai.key FAIL "OpenAI access refused" "HTTP 403" "This may be a proxy URL filter or an unsupported region. The response body is in the diagnostics." ;;
    429) record openai.key FAIL "OpenAI rate limit or no credit" "HTTP 429" "The network and key work. Check the account's billing and limits." ;;
    *) record openai.key FAIL "Unexpected OpenAI response" "HTTP $API_CODE" "The response body is in the diagnostics." ;;
  esac
}

check_langfuse() {
  section "Langfuse"
  fallback="Fallback: run code locally and view results in the instructor's Langfuse project."
  check_url langfuse.ui "Langfuse UI" "$LANGFUSE_HOST" WARN
  check_url langfuse.api "Langfuse API" "$LANGFUSE_HOST/api/public/health" WARN

  if [ -n "$LANGFUSE_PK" ] && [ -n "$LANGFUSE_SK" ]; then
    curl_with_secret "user = \"$LANGFUSE_PK:$LANGFUSE_SK\"" "$LANGFUSE_HOST/api/public/projects"
    if [ "$API_RC" != 0 ]; then
      record langfuse.auth WARN "Langfuse key check failed" "curl exit $API_RC" "$(curl_hint "$API_RC") $fallback"
    elif [ "$API_CODE" = 200 ]; then
      record langfuse.auth PASS "Langfuse keys accepted"
    elif [ "$API_CODE" = 401 ]; then
      record langfuse.auth WARN "Langfuse rejected the keys" "HTTP 401" "Check the keys and the region: cloud.langfuse.com and us.cloud.langfuse.com are separate. $fallback"
    else
      record langfuse.auth WARN "Unexpected Langfuse response" "HTTP $API_CODE" "$fallback"
    fi
  else
    record langfuse.auth SKIP "Langfuse keys not tested" "keys not entered"
  fi

  confirm_in_chrome
}

# A browser can take a different network path from command-line tools, so a person confirms this.
confirm_in_chrome() {
  local answer="" seen="" browser="Chrome" tries=0
  if [ "$ASSUME_YES" = 1 ]; then
    record langfuse.chrome SKIP "Chrome UI check not done" "it needs a person; run without --yes"
    return
  fi
  printf '\n  Manual check: the Langfuse page must load in Google Chrome. No sign-in is needed.\n'
  if ask_yes "  Open $LANGFUSE_HOST in Chrome now? [Y/n]" y; then
    if ! open -a "Google Chrome" "$LANGFUSE_HOST" 2>> "$LOG"; then
      browser="your default browser"
      record langfuse.chrome_app WARN "Google Chrome could not be opened" "" "Install Chrome, or tell your instructor which browser you will use."
      open "$LANGFUSE_HOST" 2>> "$LOG"
    fi
  else
    echo "  Open this link in Chrome yourself: $LANGFUSE_HOST"
  fi
  while [ "$tries" -lt 5 ]; do
    tries=$(( tries + 1 ))
    read -r -p "  Did the page load in $browser? A sign-in page counts. [y = yes, n = no, s = skip] " answer || break
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
      y|yes)
        record langfuse.chrome PASS "Langfuse UI loads in $browser" "confirmed by participant"
        return ;;
      n|no)
        read -r -p "  What did you see? For example: blocked page, blank page, timeout. " seen
        record langfuse.chrome WARN "Langfuse UI did not load in $browser" "participant saw: ${seen:-not described}" "The browser may use a different proxy or web filter. Ask IT to allow $LANGFUSE_HOST. $fallback"
        return ;;
      s|skip)
        record langfuse.chrome SKIP "Chrome UI check skipped by participant"
        return ;;
      *) echo "  Please type y, n or s." ;;
    esac
  done
  record langfuse.chrome SKIP "Chrome UI check not answered"
}

# ---------------------------------------------------------------- python
clt_installed() { xcode-select -p > /dev/null 2>&1; }

find_python() {
  local candidates="" c path version best="" best_score=-1 best_rank=-99999999 major minor patch score rank
  for c in python3.14 python3.13 python3.12 python3.11 python3.10 python3 python; do
    path="$(command -v "$c" 2>/dev/null)" && candidates="$candidates
$path"
  done
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /Library/Frameworks/Python.framework/Versions/*/bin/python3 "$HOME"/.pyenv/shims/python3 "$HOME"/miniconda3/bin/python3 "$HOME"/anaconda3/bin/python3 /opt/anaconda3/bin/python3 /opt/miniconda3/bin/python3; do
    [ -x "$c" ] && candidates="$candidates
$c"
  done
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    # Without Command Line Tools this stub opens an installer dialog instead of running.
    if [ "$c" = /usr/bin/python3 ] && ! clt_installed; then
      note "Skipping /usr/bin/python3: Command Line Tools are not installed."
      continue
    fi
    run 20 "$c" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'
    version="$(tail -n 1 "$LAST_OUT")"
    case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) continue ;; esac
    major="${version%%.*}"; minor="${version#*.}"; minor="${minor%%.*}"; patch="${version##*.}"
    score=$(( major * 10000 + minor * 100 + patch ))
    # The workshop targets 3.12, and brand-new versions can lack wheels for pinned packages.
    case "$major.$minor" in
      3.12) rank=5 ;; 3.13) rank=4 ;; 3.11) rank=3 ;; 3.10) rank=2 ;; 3.*) if [ "$minor" -gt 13 ]; then rank=1; else rank=0; fi ;; *) rank=-1 ;;
    esac
    rank=$(( rank * 1000000 + score ))
    if [ "$rank" -gt "$best_rank" ]; then best_rank=$rank; best_score=$score; best="$c"; PY_VERSION="$version"; fi
  done <<EOF
$(printf '%s\n' "$candidates" | awk '!seen[$0]++')
EOF
  PY_BIN="$best"
  PY_SCORE=$best_score
}

check_python() {
  section "Python, pip and Jupyter"
  PY_BIN=""; PY_VERSION=""; PY_SCORE=-1
  find_python
  if [ -z "$PY_BIN" ]; then
    MISSING_TOOLS="$MISSING_TOOLS Python"
    record python.version FAIL "Python not found" "" "Install Python 3.10+ from python.org or through IT. Required for all hands-on code."
    record python.helper SKIP "pip, package, OpenAI SDK and Jupyter checks not run" "they need Python"
    return
  fi
  if [ "$PY_SCORE" -ge 31000 ]; then
    record python.version PASS "Python $PY_VERSION" "$PY_BIN"
  else
    record python.version FAIL "Python $PY_VERSION is too old" "$PY_BIN" "Install Python 3.10+ from python.org or through IT. Required for all hands-on code."
  fi
  if [ "$PY_SCORE" -lt 30700 ]; then
    record python.helper SKIP "Python-level checks skipped" "this Python is too old to run them"
    return
  fi
  PF_WORK="$WORK" PF_RESULTS="$RESULTS" PF_LOG="$LOG" PF_PIP_INDEX_URL="$PIP_INDEX_URL" PF_PIP_PACKAGES="$PIP_PACKAGES" \
    PF_OPENAI_BASE_URL="$OPENAI_BASE_URL" PF_OPENAI_MODEL="$OPENAI_MODEL" PF_OPENAI_API_KEY="$OPENAI_API_KEY_VALUE" \
    PF_LANGFUSE_HOST="$LANGFUSE_HOST" PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONUNBUFFERED=1 \
    "$PY_BIN" "$HERE/preflight_checks.py" 2>> "$LOG" < /dev/null &
  HELPER_PID=$!
  local dog rc
  ( sleep 4200; kill -TERM "$HELPER_PID" 2>/dev/null ) > /dev/null 2>&1 &
  dog=$!
  wait "$HELPER_PID"
  rc=$?
  HELPER_PID=""
  pkill -P "$dog" sleep 2>/dev/null
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  [ "$rc" = 0 ] || record python.helper FAIL "Python checks stopped unexpectedly" "exit $rc" "The remaining checks still run. The traceback is in the diagnostics."
}

# ---------------------------------------------------------------- git
check_git() {
  section "Git and GitHub"
  local fallback="Fallback: the code is shared as a zip and the CI/CD gate is an instructor demo." git_bin
  git_bin="$(command -v git 2>/dev/null)"
  if [ "$git_bin" = /usr/bin/git ] && ! clt_installed; then git_bin=""; fi
  if [ -z "$git_bin" ]; then
    MISSING_TOOLS="$MISSING_TOOLS Git"
    record git.install WARN "Git not installed" "" "Install Git, or ask IT to. $fallback"
    return
  fi
  run 20 "$git_bin" --version
  record git.install PASS "$(tail -n 1 "$LAST_OUT")" "$git_bin"
  run 20 "$git_bin" config --global --get-regexp '^(http|https|core\.sshcommand|url)\.'
  export GIT_TERMINAL_PROMPT=0
  run 60 "$git_bin" ls-remote "$GIT_REPO_URL" HEAD
  if [ "$LAST_RC" = 0 ]; then
    record git.remote PASS "Git can reach the repo" "$GIT_REPO_URL"
  else
    record git.remote WARN "Cannot reach the Git repo" "$(tail -n 1 "$LAST_OUT")" "Check for a certificate, proxy or access error in the diagnostics. $fallback"
  fi
  run 240 "$git_bin" clone --depth 1 "$GIT_REPO_URL" "$WORK/clone_test"
  if [ "$LAST_RC" = 0 ] && [ -e "$WORK/clone_test/.git" ]; then
    record git.clone PASS "Workshop repo cloned" "$GIT_REPO_URL"
  else
    record git.clone WARN "Git clone failed" "$(tail -n 1 "$LAST_OUT")" "$fallback"
  fi
}

# ---------------------------------------------------------------- IDE
check_one_ide() { # check_one_ide LABEL ID CLI_PATH
  local list missing="" ext
  run 30 "$3" --version
  if [ "$LAST_RC" != 0 ]; then
    record "ide.$2" WARN "$1 is installed but its command failed" "exit $LAST_RC" "Open it once to finish setup."
    return
  fi
  run 45 "$3" --list-extensions
  list="$(cat "$LAST_OUT")"
  for ext in ms-python.python ms-toolsai.jupyter; do
    printf '%s\n' "$list" | grep -qix "$ext" || missing="$missing $ext"
  done
  if [ -z "$missing" ]; then
    record "ide.$2" PASS "$1 with Python and Jupyter extensions"
  else
    record "ide.$2" WARN "$1 is missing extensions" "$missing" "Install them from the Extensions panel. Fallback: JupyterLab."
  fi
}

check_ide() {
  section "IDE"
  local code_bin cursor_bin
  code_bin="$(command -v code 2>/dev/null)"
  [ -z "$code_bin" ] && [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ] && code_bin="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  [ -z "$code_bin" ] && [ -x "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ] && code_bin="$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  cursor_bin="$(command -v cursor 2>/dev/null)"
  [ -z "$cursor_bin" ] && [ -x "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ] && cursor_bin="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
  [ -z "$cursor_bin" ] && [ -x "$HOME/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ] && cursor_bin="$HOME/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
  [ -n "$code_bin" ] && check_one_ide "VS Code" vscode "$code_bin"
  [ -n "$cursor_bin" ] && check_one_ide "Cursor" cursor "$cursor_bin"
  if [ -z "$code_bin" ] && [ -z "$cursor_bin" ]; then
    MISSING_TOOLS="$MISSING_TOOLS IDE"
    record ide.install WARN "Neither VS Code nor Cursor found" "" "Install one, or ask IT to. Fallback: JupyterLab through pip."
  fi
}

# ---------------------------------------------------------------- docker
docker_hint() { # docker_hint OUTPUT_FILE
  if grep -Eqi 'x509|certificate signed by unknown|tls: failed to verify' "$1"; then
    echo "Docker does not trust the corporate TLS inspection certificate. Add the root CA to the Mac's keychain and restart Docker, or ask IT."
  elif grep -Eqi 'toomanyrequests|rate limit' "$1"; then
    echo "Docker Hub's rate limit was reached, which is common on a shared office IP. Run docker login, or use a mirror."
  elif grep -Eqi 'proxyconnect|407|proxy' "$1"; then
    echo "Docker's proxy setup failed. Set the proxy under Docker Desktop > Settings > Resources > Proxies."
  elif grep -Eqi 'i/o timeout|context deadline|TLS handshake timeout|no such host|connection refused|connection reset' "$1"; then
    echo "Docker cannot reach Docker Hub. Allow registry-1.docker.io, auth.docker.io and production.cloudflare.docker.com, or set Docker's proxy."
  elif grep -Eqi 'denied|unauthorized|not allowed|pull access' "$1"; then
    echo "Docker Hub refused access, possibly from a registry policy. Ask IT, or use an approved image."
  elif grep -Eqi 'no space left' "$1"; then
    echo "Docker is out of disk space. Run docker system prune or increase its disk limit."
  else
    echo "See the Docker output in the diagnostics."
  fi
}

check_docker() {
  section "Docker"
  local fallback="Fallback: the build and run are an instructor demo." had_hello=0 c
  if [ "$SKIP_DOCKER" = 1 ]; then record docker.install SKIP "Docker checks skipped" "--skip-docker was used"; return; fi
  DOCKER_BIN="$(command -v docker 2>/dev/null)"
  for c in /Applications/Docker.app/Contents/Resources/bin/docker "$HOME/.docker/bin/docker" "$HOME/.rd/bin/docker"; do
    [ -z "$DOCKER_BIN" ] && [ -x "$c" ] && DOCKER_BIN="$c"
  done
  if [ -z "$DOCKER_BIN" ]; then
    MISSING_TOOLS="$MISSING_TOOLS Docker"
    run 10 /bin/sh -c 'command -v podman colima nerdctl lima || true'
    record docker.install WARN "Docker not installed" "" "Install Docker Desktop or the approved equivalent, or ask IT to. $fallback"
    record docker.pull SKIP "Docker image and container checks not run" "Docker is not installed"
    return
  fi
  run 20 "$DOCKER_BIN" --version
  record docker.install PASS "$(tail -n 1 "$LAST_OUT")" "$DOCKER_BIN"
  run 20 "$DOCKER_BIN" context ls

  run 30 "$DOCKER_BIN" version
  if [ "$LAST_RC" != 0 ] && [ "$ASSUME_YES" = 0 ]; then
    if ask_yes "  Docker is installed but not running. Start Docker Desktop, wait for it to be ready, then retry? [Y/n]" y; then
      run 30 "$DOCKER_BIN" version
    fi
  fi
  if [ "$LAST_RC" != 0 ]; then
    record docker.daemon WARN "Docker engine is not running" "exit $LAST_RC" "Start Docker Desktop and re-run. $fallback"
    record docker.pull SKIP "Docker image and container checks not run" "the Docker engine is not running"
    return
  fi
  record docker.daemon PASS "Docker engine is running"
  run 30 "$DOCKER_BIN" info

  "$DOCKER_BIN" image inspect "$DOCKER_TEST_IMAGE" > /dev/null 2>&1 && had_hello=1
  progress "Pulling $DOCKER_TEST_IMAGE"
  run 240 "$DOCKER_BIN" pull "$DOCKER_TEST_IMAGE"
  if [ "$LAST_RC" = 0 ]; then
    record docker.pull PASS "Image pull from Docker Hub works" "$DOCKER_TEST_IMAGE"
    run 90 "$DOCKER_BIN" run --rm "$DOCKER_TEST_IMAGE"
    if [ "$LAST_RC" = 0 ]; then record docker.run PASS "Containers can run" "$DOCKER_TEST_IMAGE"
    else record docker.run WARN "Container failed to run" "exit $LAST_RC" "$(docker_hint "$LAST_OUT") $fallback"
    fi
    [ "$had_hello" = 0 ] && "$DOCKER_BIN" rmi "$DOCKER_TEST_IMAGE" > /dev/null 2>&1
  else
    record docker.pull WARN "Cannot pull images from Docker Hub" "$DOCKER_TEST_IMAGE, exit $LAST_RC" "$(docker_hint "$LAST_OUT") $fallback"
    record docker.run SKIP "Container run not tested" "the test image could not be pulled"
  fi

  progress "Pulling $DOCKER_BASE_IMAGE (may take a few minutes). It stays on the laptop to save time on the day."
  run 480 "$DOCKER_BIN" pull "$DOCKER_BASE_IMAGE"
  if [ "$LAST_RC" = 0 ]; then
    record docker.base PASS "Base image pulled" "$DOCKER_BASE_IMAGE"
  else
    record docker.base WARN "Cannot pull the base image" "$DOCKER_BASE_IMAGE, exit $LAST_RC" "$(docker_hint "$LAST_OUT") $fallback"
  fi

  progress "Building a test image, including pip install inside the build"
  local build_args="--build-arg BASE_IMAGE=$DOCKER_BASE_IMAGE"
  export PIP_INDEX_URL
  build_args="$build_args --build-arg PIP_INDEX_URL"
  [ -n "$PROXY_EFFECTIVE" ] && build_args="$build_args --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY"
  # shellcheck disable=SC2086  # build_args is a list of separate flags
  run 420 "$DOCKER_BIN" build --no-cache --progress=plain $build_args -t workshop-preflight-probe "$HERE/docker_probe"
  if [ "$LAST_RC" != 0 ]; then
    record docker.build WARN "Docker build failed" "exit $LAST_RC" "$(docker_hint "$LAST_OUT") If only pip failed, containers do not trust the corporate CA or lack the proxy. $fallback"
    record docker.network SKIP "Container network not tested" "it needs the test image, which did not build"
    return
  fi
  record docker.build PASS "Docker build with pip install works"

  local run_env=""
  [ -n "$PROXY_EFFECTIVE" ] && run_env="-e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY"
  # shellcheck disable=SC2086  # run_env is a list of separate flags
  run 120 "$DOCKER_BIN" run --rm $run_env workshop-preflight-probe "$OPENAI_BASE_URL/models" "$LANGFUSE_HOST/api/public/health"
  if [ "$LAST_RC" = 0 ]; then
    record docker.network PASS "Containers can reach OpenAI and Langfuse"
  else
    record docker.network WARN "Container cannot reach OpenAI or Langfuse" "$(grep -m 1 FAIL "$LAST_OUT" | cut -c 1-200)" "Containers may lack the corporate CA or proxy, or a firewall may block them. $fallback"
  fi
}

check_admin_vs_missing() {
  if [ "${IS_ADMIN:-1}" = 0 ] && [ -n "$MISSING_TOOLS" ]; then
    section "Install rights"
    record sys.installs WARN "IT must install:$MISSING_TOOLS" "this account has no admin rights" "Installs are the most common day-of blocker, so request these before the workshop."
  fi
}

# ---------------------------------------------------------------- main
MISSING_TOOLS=""
DOCKER_BIN=""
HELPER_PID=""
OPENAI_BASE_URL=""; OPENAI_MODEL=""; LANGFUSE_HOST=""; GIT_REPO_URL=""; PIP_INDEX_URL=""; PIP_PACKAGES=""
DOCKER_TEST_IMAGE=""; DOCKER_BASE_IMAGE=""; PROXY_URL="auto"; CA_BUNDLE=""; PROXY_EFFECTIVE=""

cat <<EOF
${C_BOLD}Workshop laptop preflight${C_OFF}
Checks that this Mac is ready for the workshop. Takes about 5-15 minutes.
It installs nothing system-wide: Python packages go in a temporary folder that is
deleted at the end. Docker may keep one downloaded base image, to save time on the day.
It ends by writing a report file to send to your instructor. API keys are never included.
EOF

configure
check_system
check_terminal
check_network
check_openai_api
check_langfuse
check_python
check_git
check_ide
check_docker
check_admin_vs_missing

write_report
section "Result"
printf '  %sVerdict: %s%s\n' "$C_BOLD" "$(verdict)" "$C_OFF"
printf '  PASS %s | WARN %s | FAIL %s | SKIP %s\n\n' "$(count_status PASS)" "$(count_status WARN)" "$(count_status FAIL)" "$(count_status SKIP)"
printf '  Report saved to:\n  %s\n\n  Please send this file to your instructor.\n' "$REPORT"
[ "$ASSUME_YES" = 0 ] && open -R "$REPORT" 2>/dev/null
[ "$(count_status FAIL)" -gt 0 ] && exit 1
exit 0
