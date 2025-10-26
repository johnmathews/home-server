# Treat like a generic app (falls back to CPU/IO heuristic)
check_busy() { check_busy_generic "$1"; }
