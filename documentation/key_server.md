# Key Server

Datasets on TrueNAS are encrypted and need a passphrase to be unlocked. After
startup, a script runs to retrieve the passphrases from a key server.

There is an ansible role `key_server` that sets this up.

The IP address of the key server is `192.168.2.201`. 

The key server is a fastAPI script that has a single endpoint. It is stored at `key_server/templates/key-server-main.py`.

Bearer token and dataset keys are stored in the Ansible vault.

Health Check: `http://192.168.2.201:8001/health`
Prometheus Metrics: `http://192.168.2.201:8001/metrics`
