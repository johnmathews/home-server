"""Tests for scripts/check-duplicate-ports.py."""

import textwrap
from pathlib import Path

import pytest

# Import the module under test
import importlib.util

spec = importlib.util.spec_from_file_location(
    "check_duplicate_ports",
    Path(__file__).resolve().parent.parent / "scripts" / "check-duplicate-ports.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
extract_host_ports = mod.extract_host_ports


def _write_compose(tmp_path: Path, content: str) -> Path:
    f = tmp_path / "docker-compose.yml.j2"
    f.write_text(textwrap.dedent(content))
    return f


def test_no_duplicates(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          app:
            image: myapp
            ports:
              - "3000:3000"
          db:
            image: postgres
            ports:
              - "5432:5432"
    """)
    ports = extract_host_ports(f)
    host_ports = [p for _, _, p in ports]
    assert host_ports == ["3000/tcp", "5432/tcp"]


def test_duplicate_detected(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          app:
            image: myapp
            ports:
              - "3000:3000"
          other:
            image: other
            ports:
              - "3000:8080"
    """)
    ports = extract_host_ports(f)
    host_ports = [p for _, _, p in ports]
    assert host_ports == ["3000/tcp", "3000/tcp"]


def test_tcp_udp_same_port_not_duplicate(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          syncthing:
            image: syncthing
            ports:
              - "22000:22000/tcp"
              - "22000:22000/udp"
    """)
    ports = extract_host_ports(f)
    host_ports = [p for _, _, p in ports]
    assert host_ports == ["22000/tcp", "22000/udp"]
    # These are different — no duplicate
    assert len(set(host_ports)) == 2


def test_unquoted_ports(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          app:
            image: myapp
            ports:
              - 8080:80
    """)
    ports = extract_host_ports(f)
    assert ports == [("app", 5, "8080/tcp")]


def test_service_names_tracked(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          frontend:
            image: nginx
            ports:
              - "80:80"
          backend:
            image: flask
            ports:
              - "5000:5000"
    """)
    ports = extract_host_ports(f)
    services = [svc for svc, _, _ in ports]
    assert services == ["frontend", "backend"]


def test_empty_file(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, "")
    assert extract_host_ports(f) == []


def test_no_ports_section(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          app:
            image: myapp
            environment:
              - FOO=bar
    """)
    assert extract_host_ports(f) == []
