#!/usr/bin/env python3
"""Scan docker-compose Jinja2 templates for duplicate host port bindings."""

import re
import sys
from pathlib import Path

# Matches port mappings like: - "3002:3000", - 3002:3000, - "8080:80/udp"
PORT_RE = re.compile(r'^\s*-\s*"?(\d+):\d+(?:/(\w+))?"?\s*$')


def extract_host_ports(path: Path) -> list[tuple[str, int, str]]:
    """Return [(service_name, line_number, host_port_proto), ...] from a compose template."""
    results = []
    current_service: str | None = None
    in_ports = False

    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.strip()

        # Detect top-level service names (2-space indented, not a directive)
        if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
            candidate = stripped.rstrip(":")
            if candidate and not candidate.startswith("#") and not candidate.startswith("{"):
                current_service = candidate
                in_ports = False

        if stripped == "ports:":
            in_ports = True
            continue

        if in_ports:
            m = PORT_RE.match(stripped)
            if m:
                proto = m.group(2) or "tcp"
                results.append((current_service or "unknown", lineno, f"{m.group(1)}/{proto}"))
            elif stripped and not stripped.startswith("#"):
                in_ports = False

    return results


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    templates = sorted(repo_root.glob("roles/*/templates/docker-compose.yml.j2"))

    errors = 0
    for tmpl in templates:
        ports = extract_host_ports(tmpl)
        seen: dict[str, tuple[str, int]] = {}  # host_port/proto -> (service, lineno)
        rel = tmpl.relative_to(repo_root)

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

    print(f"OK: checked {len(templates)} docker-compose templates, no duplicate ports")
    return 0


if __name__ == "__main__":
    sys.exit(main())
