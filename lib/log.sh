#!/usr/bin/env bash
# lib/log.sh — logging primitives
#
# Two streams:
#   BUILD_LOG  human-readable narrative (INFO / WARN / ERROR)
#   TRACE_LOG  full command trace, written through a dedicated fd
#
# The trace goes to its own file descriptor rather than stdout/stderr. Routing
# xtrace through a shared descriptor deadlocks against command-level
# redirections elsewhere in the build; a private fd never shares state with
# any command's output.

: "${BUILD_LOG:=/dev/null}"
: "${TRACE_LOG:=/dev/null}"

readonly _C_INFO=$'\033[1;32m'
readonly _C_WARN=$'\033[1;33m'
readonly _C_ERR=$'\033[1;31m'
readonly _C_OFF=$'\033[0m'

_log_emit() {
    local level="$1" color="$2" msg="$3"
    local ts
    ts=$(date '+%H:%M:%S')
    printf '%s %s[%s]%s %s\n' "$ts" "$color" "$level" "$_C_OFF" "$msg"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$BUILD_LOG" 2>/dev/null || true
    { printf '### [%s] %s %s\n' "$level" "$ts" "$msg" >&9; } 2>/dev/null || true
}

log()  { _log_emit INFO  "$_C_INFO" "$1"; }
warn() { _log_emit WARN  "$_C_WARN" "$1"; }

# die writes the message and exits. Callers should pass a message that names
# the remedy, not just the symptom — the operator is usually mid-transfer
# window and cannot iterate.
die() {
    _log_emit ERROR "$_C_ERR" "$1"
    exit "${2:-1}"
}

# Plain text that still reaches the log. For tables and summaries where the
# INFO prefix would be noise.
say()  { printf '%s\n' "$1"; printf '%s\n' "$1" >>"$BUILD_LOG" 2>/dev/null || true; }
blank(){ printf '\n';       printf '\n'       >>"$BUILD_LOG" 2>/dev/null || true; }

# Open the trace fd and start xtrace. Call once, after BUILD_LOG/TRACE_LOG
# are set and their directories exist.
log_start_trace() {
    exec 9>>"$TRACE_LOG"
    export BASH_XTRACEFD=9
    export PS4='+ $(date "+%H:%M:%S") ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
}

log_stop_trace() {
    { set +x; } 2>/dev/null
    exec 9>&- 2>/dev/null || true
}
