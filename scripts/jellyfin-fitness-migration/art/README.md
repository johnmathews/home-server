# Manual thumbcard sources

Drop `<Show>/poster.jpg` (show) or `<Show>/Season NN/folder.jpg` (season) here and re-run
`make_posters.py` — see documentation/jellyfin_health_fitness_library.md §4. Portrait images are
used as-is for the 2:3 poster; landscape ones are letterboxed with the name band. The same source
also feeds the 16:9 `landscape.jpg` unless you add a separate `<Show>/landscape.jpg` or
`<Show>/Season NN/landscape.jpg`. (`.png`/`.webp` are fine too.)
