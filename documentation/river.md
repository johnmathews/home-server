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
  forward_to = [loki.process.drop_old.receiver]
}
```

In this example we wire the docker source (from the loki package) into the drop
filter.

Big difference from other approaches - its not a monolithic pipeline but a DAG
of connected components.

## Dot notation

- its namespace-style type naming.
- its not nesting
- Alloy using namespaces to organise types into packages, not objects.
- `loki.source.docker` is like saying 'the docker log source in the `loki`
  package'
