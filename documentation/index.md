# Home Server

Check out [charts.itsa.pizza](https://charts.itsa.pizza) for metrics and logs.

Media containers are paused during night hours to allow HDDs to spin down.

Jobs are scheduled to run during the day as much as possible.

Ansible is used to configure the home server and can be deployed using
`make <host> tags=<tags>`

[Project repo](https://github.com/johnmathews/home-server)

Static IPs are assigned on the router. The last part of the IP address should
match the last part of the MAC address. See `~/.ssh/known_hosts` and
`~/.ssh/config`.

## Domain

External access uses `itsa.pizza` via Cloudflare (DNS, Tunnel, Zero Access).
A migration to `itsa-pizza.com` is planned — see `documentation/domain-migration.md`.
