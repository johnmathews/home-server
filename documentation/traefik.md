## Traefik

View the dashboard at [https://traefik.itsa.pizza/dashboard](https://traefik.itsa.pizza/dashboard/)

API overview: [https://traefik.itsa.pizza/api/overview](https://traefik.itsa.pizza/api/overview)

## Immich, Jellyfin

Traefik controls ingress for `Immich` and `Jellyfin`.

Immich and Jellyfin are proxied behind Cloudflare but they are not controlled by Cloudflare Zero Access, their domains have a bypass policy.

Therefore Traefik applies some rate limiting to their authentication and api routes.

Only port 443 is exposed to the public internet, because they are proxied behind Cloudflare.
