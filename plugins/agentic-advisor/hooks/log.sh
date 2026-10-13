# shellcheck shell=bash
# Troubleshooting log shared by the hooks (sourced, not run). On by default; LINEARB_DEBUG=0 turns it off.
# One line per outcome to ${XDG_CACHE_HOME:-~/.cache}/agentic-advisor/report.log, rotated at ~1 MB.
# Never logs the token, prompt or payload; emails in server responses are redacted.

_lb_ver=""
dbg() {
  case "$(printf '%s' "${LINEARB_DEBUG:-1}" | tr '[:upper:]' '[:lower:]')" in 0|false|off|no) return 0 ;; esac
  [ -n "${XDG_CACHE_HOME:-}${HOME:-}" ] || return 0
  local d="${XDG_CACHE_HOME:-${HOME:-}/.cache}/agentic-advisor" f
  (umask 077; mkdir -p "$d") 2>/dev/null
  # Private before every write: an owned real dir we can make 0700 (then no one else can swap
  # entries in it), and only a regular owned log, made 0600 before it's rotated or appended to.
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then return 0; fi
  chmod 700 "$d" 2>/dev/null || return 0
  f="$d/report.log"
  if [ -L "$f" ] || { [ -e "$f" ] && { [ ! -f "$f" ] || [ ! -O "$f" ]; }; }; then return 0; fi
  if [ -f "$f" ]; then chmod 600 "$f" 2>/dev/null || return 0; fi
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 1048576 ] 2>/dev/null; then
    # Never rotate into a directory or through a planted symlink: clear .old first, give up if it stays.
    rm -f "$f.old" 2>/dev/null
    if [ -e "$f.old" ] || [ -L "$f.old" ]; then return 0; fi
    mv -f "$f" "$f.old" 2>/dev/null || return 0
  fi
  if [ -z "$_lb_ver" ]; then
    _lb_ver="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" 2>/dev/null | head -1)"
    _lb_ver="v${_lb_ver:-?}"
  fi
  (umask 077; printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lb_ver" "$*" >> "$f") 2>/dev/null || true
}

# Mask email addresses in text that came from elsewhere (server responses, curl errors).
redact() { sed -E 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<email>/g'; }
