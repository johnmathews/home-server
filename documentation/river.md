**Status:** current — verified 2026-08-22 · covers: roles/*/templates/config.alloy, roles/*/files/config.alloy
The stage names and the two pipeline sections were checked against the deployed Alloy
configs in this repo on that date.

We use Grafana Alloy to send logs to Loki. Loki makes the logs available in
Grafana.

Alloy is configured using the River configuration language.

The `config.alloy` file must contain at least 1 connected graph of components in
order to run. The graph must contain at least one source and one output. There
can be optional components in the middle to process the data.

Alloy is a dataflow engine. River is similar but different to terraform
configuration syntax. It is not Terraform HCL.

River is hierarchical, declarative, and strongly typed. Designed specifically
for Alloy, apparently. Designed for pipelines.

Each module is a different type of component. The components correspond to `Go`
packages.

## River Naming Structure

```
<controller>.<exporter>.<component_type> "<instance_name>" { ... }
```

Or:

```
<package>.<subsystem>.<component_type> "<instance_name>" { ... }

```

`discovery.docker` - Watches docker for running containers
`loki.source.docker` - Reads logs from docker containers

Each defines inputs, outputs and arguments.

## Component Instances

Each block instantiates a type of component and gives it a name:

```
discovery.docker "self" {
  host = "unix:///var/run/docker.sock"
}
```

Type: `discovery.docker` Instance name: `self` Full component path:
`discovery.docker.self`

You use the path to make references to the component.

## Connections

Alloy is a dataflow engine.

Every component has inputs and outputs.

You connect components by passing their output receivers to other components:

```
loki.source.docker "containers" {
  forward_to = [loki.process.drop_logs.receiver]
}
```

In this example we wire the docker source (from the loki package) into the drop
filter. `loki.process "drop_logs"` is a real component in this repo's configs —
it carries a `stage.drop` that discards entries older than 1h, so Loki never
rejects them as "entry too old" — and it forwards on to `loki.process "normalize"`.
See `roles/prometheus_lxc/templates/config.alloy` for the full chain.

Big difference from other approaches - its not a monolithic pipeline but a DAG
of connected components.

## Dot notation

- its namespace-style type naming.
- its not nesting
- Alloy using namespaces to organise types into packages, not objects.
- `loki.source.docker` is like saying 'the docker log source in the `loki`
  package'

## Where the config actually lives

**Never edit `config.alloy` on a host** — every copy is deployed by Ansible and is
overwritten on the next `make <host>`. There are 15 source copies in this repo:

```bash
find roles/ -name 'config.alloy*'      # 15 files, as of 2026-08-22
```

They sit under either `templates/` or `files/`, and which one matters:

- `roles/<role>/templates/config.alloy` — Jinja-rendered, so it can use vars.
  Most roles.
- `roles/<role>/files/config.alloy` — copied verbatim, no templating.
  `nas`, `jellyfin_lxc`, `pve`, `traefik_lxc`.

To change log shipping for a host, edit its file under `roles/`, then `make <host>`.

## Pinning the Alloy version

Every role resolves the Alloy image tag from `sidecar_alloy_version` in
`group_vars/all/main.yml`, through its own default:

```yaml
<role>_alloy_version: "{{ sidecar_alloy_version }}"
```

No role pins a literal and nothing tracks `:latest`. Six roles did carry literals
until 2026-08-22, which is how the fleet came to run two Alloy generations at once;
see [upgrade-procedures.md](upgrade-procedures.md) for the bump procedure, which is
not just an edit — compose handlers use `pull: never`.

The variable's **name** is mid-migration (W21-W24 of the var-naming refactor). Roles
already prefixed use `<role>_alloy_version` — agent_lxc, document_library_lxc,
family_finances_lxc, immich_lxc, jellyfin_lxc, music_lxc, open_webui_lxc,
prometheus_lxc, traefik_lxc, tubearchivist_lxc. The three not yet converted still use
bare `alloy_version`: infra_vm, media_vm, pve. `sidecar_alloy_version` itself is
unaffected either way and keeps its name.

`make refresh-sidecars` pulls and recreates the sidecars in bulk — it applies the
pin each host already has, it does not upgrade anything. Full detail in
[upgrade-procedures.md](upgrade-procedures.md).
