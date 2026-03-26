# Adding a New Service

Step-by-step guide for adding a new service to the home server infrastructure.

## Prerequisites

- A Proxmox LXC or VM already created for the service (or an existing host to deploy to)
- Static IP assigned on the MikroTik router
- SSH access configured in `~/.ssh/config`

## Step 1: Create the Ansible Role

Create the role skeleton:

```
roles/<service_name>/
  defaults/main.yml     # Default variables
  tasks/main.yml        # Main task file
  handlers/main.yml     # Restart/reload handlers
  templates/
    docker-compose.yml.j2   # Docker compose template (if applicable)
    .env.j2                 # Environment file (if needed)
```

### defaults/main.yml

Use centralized variables from `group_vars/all/main.yml` where possible:

```yaml
# Role-specific variables only — don't redefine puid, guid, TZ, etc.
<service>_version: "1.0.0"         # Pin the Docker image version
<service>_port: 8080
<service>_docker_compose_dir: "{{ docker_compose_base_dir }}/<service>"
```

### tasks/main.yml

Standard task structure:

```yaml
- name: Create Docker compose directory
  ansible.builtin.file:
    path: "{{ <service>_docker_compose_dir }}"
    state: directory
    mode: "0755"

- name: Deploy Docker compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ <service>_docker_compose_dir }}/docker-compose.yml"
    mode: "0644"
  notify: Restart <service> docker compose stack

- name: Start Docker compose stack
  community.docker.docker_compose_v2:
    project_src: "{{ <service>_docker_compose_dir }}"
    state: present
```

### handlers/main.yml

```yaml
- name: Restart <service> docker compose stack
  community.docker.docker_compose_v2:
    project_src: "{{ <service>_docker_compose_dir }}"
    state: restarted
```

### docker-compose.yml.j2

Include monitoring sidecar containers (standard across all services):

```yaml
services:
  <service>:
    image: <image>:{{ <service>_version }}
    container_name: <service>
    restart: unless-stopped
    ports:
      - "{{ <service>_port }}:8080"
    environment:
      TZ: "{{ default_tz }}"
      PUID: "{{ default_puid }}"
      PGID: "{{ default_guid }}"

  # --- Monitoring sidecars ---
  node-exporter:
    image: quay.io/prometheus/node-exporter:{{ node_exporter_version }}
    container_name: node-exporter
    restart: unless-stopped
    pid: host
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:{{ cadvisor_version }}
    container_name: cadvisor
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

  alloy:
    image: grafana/alloy:{{ alloy_version }}
    container_name: alloy
    restart: unless-stopped
    ports:
      - "12345:12345"
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
    command:
      - run
      - /etc/alloy/config.alloy
```

## Step 2: Add to Inventory

Edit `inventory.ini`:

```ini
[<service>]
<service>_lxc ansible_host=192.168.2.XXX ansible_user=root
```

Add to relevant groups:

```ini
[shell_environment_clients:children]
<service>

[nfs_clients:children]      # If the service needs NFS mounts
<service>

[share_drive_clients:children]  # If NFS mount health monitoring is needed
<service>

[alloy_clients:children]    # If the service runs Alloy for log shipping
<service>
```

## Step 3: Create the Playbook

Create `playbooks/<service>.yml`:

```yaml
- name: Configure <service> LXC
  hosts: <service>
  become: true
  roles:
    - role: <service>_lxc
```

## Step 4: Add to site.yml

Add the import to `playbooks/site.yml` (alphabetical order):

```yaml
- import_playbook: <service>.yml
```

## Step 5: Add Makefile Target

Add to `makefile`:

```makefile
<service>:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/<service>.yml $(VAULT) $(ANSIBLE_OPTS)
```

Add to the `.PHONY` declaration at line 46.

## Step 6: Add Vault Variables (if needed)

If the service needs secrets (API keys, passwords, database credentials):

```sh
# Edit the vault file
ansible-vault edit group_vars/all/vault.yml

# Add variables with vault_ prefix:
# vault_<service>_db_password: "..."
# vault_<service>_api_key: "..."
```

Reference them in `roles/<service>/defaults/main.yml`:

```yaml
<service>_db_password: "{{ vault_<service>_db_password }}"
```

## Step 7: Add NFS Mounts (if needed)

If the service needs access to TrueNAS shares, add it to the `nfs_clients` group
in `inventory.ini` and configure mounts in `host_vars/<service>_lxc.yml`:

```yaml
nfs_mounts:
  - name: media
    src: "192.168.2.104:/mnt/tank/media"
    path: /mnt/media
    fstype: nfs
    opts: "rw,soft,intr,timeo=30,retrans=3"
```

## Step 8: Wire Up External Access

### Option A: Cloudflare Tunnel (most services)

Add an entry to `cloudflared_ingress` in `roles/cloudflared_lxc/defaults/main.yml`:

```yaml
- prefix: <service>
  service: "http://192.168.2.XXX:<port>"
```

Then run `make cloudflared` to deploy. This creates the DNS record and tunnel route
automatically. The service will be accessible at `<service>.itsa-pizza.com` and
protected by Cloudflare Zero Access.

### Option B: Via Traefik (media services needing WebSocket support)

Add router and service entries to the Traefik dynamic configuration templates in
`roles/traefik_lxc/templates/`. This is used for services like Jellyfin, Immich,
and Navidrome that need WebSocket support or custom middleware.

## Step 9: Add Prometheus Monitoring

Add scrape targets to `roles/prometheus_lxc/templates/prometheus/prometheus.yml.j2`:

```yaml
  - job_name: '<service>-node'
    static_configs:
      - targets: ['192.168.2.XXX:9100']

  - job_name: '<service>-cadvisor'
    static_configs:
      - targets: ['192.168.2.XXX:8080']
```

## Step 10: Deploy and Verify

```sh
# Deploy the new service
make <service>

# Verify it's running
ssh <service> docker ps

# Check monitoring
# - Prometheus targets: prometheus.itsa-pizza.com/targets
# - Grafana dashboards: grafana.itsa-pizza.com
# - Logs: Grafana > Explore > Loki
```

## Step 11: Create Documentation

Create `documentation/<service>.md` covering:

- Purpose and what it does
- IP, ports, access method
- Docker containers and their relationships
- NFS/SMB mounts if applicable
- Configuration files managed by Ansible
- Vault variables used
- Known issues and troubleshooting
- How to update/upgrade

Add the doc to the Documentation Index in `CLAUDE.md`.

## Checklist

```
[ ] Role created (defaults, tasks, handlers, templates)
[ ] Docker image version pinned (not :latest)
[ ] Added to inventory.ini (host + groups)
[ ] Playbook created
[ ] Added to site.yml
[ ] Makefile target added + .PHONY updated
[ ] Vault variables added (if needed)
[ ] NFS mounts configured (if needed)
[ ] Cloudflare tunnel route or Traefik config added
[ ] Prometheus scrape targets added
[ ] Monitoring sidecars included (node-exporter, cadvisor, alloy)
[ ] Documentation written
[ ] Tested with make <service>
[ ] Verified in Prometheus targets and Grafana
```
