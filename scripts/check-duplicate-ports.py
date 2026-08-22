#!/usr/bin/env python3
"""Scan docker-compose Jinja2 templates for duplicate host port bindings."""

import argparse
import re
import sys
from pathlib import Path

import jinja2
import yaml

# Port mappings are "[HOST_IP:]HOST:CONTAINER[/PROTO]". We only care about the
# host side, and only when it is a literal — a Jinja expression that survived
# rendering cannot be compared against anything.
PORT_RE = re.compile(
    r"^(?:(?P<ip>[\d.]+|\[[0-9a-fA-F:]+\]):)?(?P<host>\d+):(?P<container>\d+)(?:/(?P<proto>\w+))?$"
)

# Undefined variables render as this sentinel rather than as an empty string.
# Empty is not safe: `image: portainer/agent:{{ ver }}` would become
# `image: portainer/agent:`, whose trailing colon YAML reads as a mapping key,
# and the whole file fails to parse. The sentinel keeps the document valid and
# makes an unresolved value visible instead of invisible.
UNDEF = "__JINJA_UNDEF__"

# A rendered ports entry still holding the sentinel, or surviving Jinja markers,
# came from a variable the offline render could not resolve. Counted and
# reported, never silently dropped.
UNRESOLVED_RE = re.compile(re.escape(UNDEF) + r"|\{\{|\{%")

# Loop bodies over an undefined collection render to nothing, so their ports
# cannot be enumerated at all — there is no entry left to flag. Detect the
# construct in the raw source instead and say so.
LOOP_RE = re.compile(r"\{%-?\s*for\b")


class _Blank(jinja2.Undefined):
    """Undefined that renders as a sentinel and iterates empty instead of raising.

    These templates are rendered WITHOUT the Ansible inventory, so most
    variables are undefined. That is deliberate: this check must run in CI with
    no vault password and no SSH access. The cost is that a port behind a
    variable is invisible, which is why unresolved entries are counted and
    reported rather than passed over.
    """

    def __iter__(self):
        return iter(())

    def __str__(self) -> str:
        return UNDEF

    def __len__(self) -> int:
        return 0

    def __bool__(self) -> bool:
        return False

    def __getattr__(self, name: str):
        if name.startswith("__"):
            raise AttributeError(name)
        return self

    __getitem__ = __getattr__


def render(text: str) -> str:
    """Render a Jinja2 template with every variable undefined-but-harmless."""
    env = jinja2.Environment(undefined=_Blank, keep_trailing_newline=True)
    try:
        return env.from_string(text).render()
    except jinja2.TemplateError:
        # A template we cannot render is reported by the caller, not silently
        # treated as having no ports.
        raise


def _iter_port_scalars(node, path=()):
    """Yield (service, yaml.ScalarNode) for every entry under services.*.ports."""
    if not isinstance(node, yaml.MappingNode):
        return
    for key, value in node.value:
        if not isinstance(key, yaml.ScalarNode):
            continue
        # docker-compose v2+ omits the top-level `version:`; services may be at
        # the root or nested under `services:`.
        if key.value == "services" and isinstance(value, yaml.MappingNode):
            yield from _iter_port_scalars(value, path + ("services",))
        elif isinstance(value, yaml.MappingNode):
            service = key.value
            for skey, svalue in value.value:
                if (
                    isinstance(skey, yaml.ScalarNode)
                    and skey.value == "ports"
                    and isinstance(svalue, yaml.SequenceNode)
                ):
                    for item in svalue.value:
                        if isinstance(item, yaml.ScalarNode):
                            yield service, item


def extract_host_ports(path: Path) -> list[tuple[str, int, str]]:
    """Return [(service, line_number, "host_port/proto"), ...] for one template.

    The template is rendered first, then parsed as YAML, so trailing comments,
    quoting style, `{% if %}` blocks and IP-bound syntax are all handled by the
    parser rather than by a regex.

    Values are read from the raw scalar node rather than via `yaml.safe_load`.
    That is load-bearing: PyYAML implements YAML 1.1, under which an unquoted
    `- 8080:30` resolves to the *integer* 484830 (8080*60+30) as a sexagesimal
    literal. Any unquoted mapping whose container port is 00-59 would otherwise
    be silently mangled.
    """
    return [
        (service, node.start_mark.line + 1, port)
        for service, node, port in _extract(path.read_text())
    ]


def extract_unresolved(path: Path) -> list[tuple[str, int, str]]:
    """Return port entries that still contain Jinja after rendering."""
    return [
        (service, node.start_mark.line + 1, node.value)
        for service, node, port in _extract(path.read_text(), want_unresolved=True)
    ]


def _extract(text: str, want_unresolved: bool = False):
    root = yaml.compose(render(text))
    if root is None:
        return
    for service, node in _iter_port_scalars(root):
        raw = str(node.value).strip().strip('"').strip("'")
        if UNRESOLVED_RE.search(raw):
            if want_unresolved:
                yield service, node, raw
            continue
        if want_unresolved:
            continue
        m = PORT_RE.match(raw)
        if not m:
            continue
        proto = (m.group("proto") or "tcp").lower()
        # An explicit host IP scopes the binding, so 127.0.0.1:80 and
        # 192.168.2.1:80 are not a collision. Keep the IP in the key.
        ip = m.group("ip") or ""
        key = f"{ip + ':' if ip else ''}{m.group('host')}/{proto}"
        yield service, node, key


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root to scan (default: the repo this script lives in)",
    )
    args = parser.parse_args(argv)

    repo_root = args.root.resolve()
    templates = sorted(repo_root.glob("roles/*/templates/docker-compose.yml.j2"))

    errors = 0
    unresolved_total = 0

    for tmpl in templates:
        rel = tmpl.relative_to(repo_root)
        try:
            ports = extract_host_ports(tmpl)
            unresolved = extract_unresolved(tmpl)
        except (jinja2.TemplateError, yaml.YAMLError) as exc:
            print(f"ERROR: {rel}: could not render or parse: {exc}")
            errors += 1
            continue

        for service, lineno, raw in unresolved:
            unresolved_total += 1
            print(
                f"NOTE:  {rel}:{lineno}: port for '{service}' is templated "
                f"({raw!r}) — not checked, it needs the inventory to resolve"
            )

        # A `{% for %}` over an undefined collection renders to nothing, so any
        # ports inside it leave no entry to flag. Say so rather than letting the
        # absence read as "no ports here".
        if LOOP_RE.search(tmpl.read_text()):
            unresolved_total += 1
            print(
                f"NOTE:  {rel}: contains a Jinja loop; ports published from "
                f"inside it are not enumerated offline"
            )

        seen: dict[str, tuple[str, int]] = {}
        for service, lineno, port_proto in ports:
            if port_proto in seen:
                prev_svc, prev_line = seen[port_proto]
                print(
                    f"ERROR: {rel}: host port {port_proto} used by both "
                    f"'{prev_svc}' (line {prev_line}) and '{service}' (line {lineno})"
                )
                errors += 1
            else:
                seen[port_proto] = (service, lineno)

    if errors:
        print(f"\n{errors} duplicate port(s) found")
        return 1

    suffix = f", {unresolved_total} templated port(s) skipped" if unresolved_total else ""
    print(f"OK: checked {len(templates)} docker-compose templates, no duplicate ports{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
