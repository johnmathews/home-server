# Databases generally dislike being frozen mid-transaction,
# but without credentials we can't safely query.
# Heuristic only.
check_busy() { check_busy_generic "$1"; }
