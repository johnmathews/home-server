# Databases generally dislike being frozen mid-transaction,
# but without credentials we can't safely query.
# Validate common.sh was sourced
if [[ "${COMMON_SH_LOADED:-0}" != "1" ]]; then
   echo "ERROR: common.sh must be sourced before this plugin" >&2
   exit 1
fi
# Heuristic only.
check_busy() { check_busy_generic "$1"; }
