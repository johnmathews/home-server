Some TrueNAS datasets are encrypted and need a passphrase to be unlocked. It is
annoying to manually decrypt them whenever TrueNAS reboots.

After startup, TrueNAS runs a script that retrieve the passphrase from a key
server and then unlocks the dataset.

You can connect to the server using the command `ssh key` using user: `john`

## TrueNAS script to retrieve keys

Local Location: `truenas_vm/templates/get_keys.sh.j2`.
Update and deploy: `make nas tags=key`

Location on TrueNAS: `/mnt/swift/scripts/get_keys.sh`
Logs: `/mnt/swift/logs/get_keys.log`

## Key server to provide keys

The key server itself is defined and deployed using the Ansible `key_server`
role.

The IP address of the key server is `192.168.2.201`.

The key server is defined in a FastAPI script
`key_server/templates/key-server-main.py`.

## Updating keys

The keys are stored in the Ansible vault.

## Endpoints

- A single functional endpoint at `/unlock`.
- A `/health` endpoint that should return `ok`.
- A Prometheus metrics endpoint at `/metrics`

#### Local URLs

- Unlock:
  [`http://192.168.2.201:8001/unlock`](http://192.168.2.201:8001/unlock)
- Health Check:
  [`http://192.168.2.201:8001/health`](http://192.168.2.201:8001/health)
- Prometheus Metrics:
  [`http://192.168.2.201:8001/metrics`](http://192.168.2.201:8001/metrics)
