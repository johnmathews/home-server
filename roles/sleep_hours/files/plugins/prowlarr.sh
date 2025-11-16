# Optional API later:
#   PROWLARR_URL, PROWLARR_API_KEY; check /api/v1/indexer/status or tasks
# Validate common.sh was sourced
if [[ "${COMMON_SH_LOADED:-0}" != "1" ]]; then
   echo "ERROR: common.sh must be sourced before this plugin" >&2
   exit 1
fi
check_busy() { check_busy_generic "$1"; }
