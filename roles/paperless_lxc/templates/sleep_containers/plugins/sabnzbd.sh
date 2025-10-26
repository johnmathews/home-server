# Optional API (if you later set SAB_URL + SAB_API_KEY):
#   export SAB_URL="http://127.0.0.1:8081"
#   export SAB_API_KEY="xxxxxxxxxxxxxxxxxxxx"
# Busy if queue not empty OR speed > 0
_sab_api_busy() {
  [[ -z "${SAB_URL:-}" || -z "${SAB_API_KEY:-}" ]] && return 2
  local js
  js="$(curl -sS "${SAB_URL}/api?mode=queue&output=json&apikey=${SAB_API_KEY}" || true)"
  [[ -z "$js" ]] && return 2
  # crude checks without jq:
  if echo "$js" | grep -Eq '"noofslots":[1-9]'; then return 0; fi
  if echo "$js" | grep -Eq '"kbpersec":"[1-9]'; then return 0; fi
  return 1
}

check_busy() {
  if _sab_api_busy; then
    return 0
  elif [[ $? -eq 2 ]]; then
    :
  fi
  check_busy_generic "$1"
}
