## ~Scripts~

This is disabled

A script runs each hour to see if any HDDs can be spun down. The script is in
`nas/scripts/spindown_hdds.sh` and is copied manually onto the nas vm.

The script is saved at `/home/truenas_admin/spindown_hdds.sh` and run via a cron
job in advanced settings UI.

## Metrics - `disk-status-exporter`

`disk-status-exporter` is a containerised FastAPI script that is managed in a
separate repo.

The state of each HDD is tracked via a custom app. The custom app code is in the
repo `disk_status_exporter`. Its a FastAPI instance that Prometheus can scrape.
