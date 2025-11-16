# Treat like a generic app (falls back to CPU/IO heuristic)
check_busy() { check_busy_generic "$1"; }
# Validate common.sh was sourced
if [[ "${COMMON_SH_LOADED:-0}" != "1" ]]; then
   echo "ERROR: common.sh must be sourced before this plugin" >&2
   exit 1
fi
