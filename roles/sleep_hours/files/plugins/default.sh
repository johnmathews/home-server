# Fallback for any container without a specific plugin
check_busy() {
# Validate common.sh was sourced
if [[ "${COMMON_SH_LOADED:-0}" != "1" ]]; then
   echo "ERROR: common.sh must be sourced before this plugin" >&2
   exit 1
fi
   # Validate that common.sh was sourced before using functions
   if ! declare -F check_busy_generic >/dev/null 2>&1; then
      echo "ERROR: common.sh not loaded - check_busy_generic function not available"
      return 2
   fi
   check_busy_generic "$1"
}
