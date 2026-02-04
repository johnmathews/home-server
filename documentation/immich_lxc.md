## Environment variables

Immich and Pushover environment variables are written to `/etc/environment` on the LXC so they are available to all
shells and cron jobs. The values come from vault variables defined in `group_vars/all/vault.yml`:

- `IMMICH_API_KEY` - API key for Immich
- `IMMICH_LIBRARY_ID` - reference library ID
- `IMMICH_API_URL` - Immich API endpoint
- `IMMICH_SHARE_USER` - share user (hardcoded to `John`)
- `PUSHOVER_USER_KEY` - Pushover notification user key
- `PUSHOVER_APP_TOKEN` - Pushover app API token

These are the same variables set on the media VM.

To deploy just the env vars:

```sh
make immich TAGS=immich
```
