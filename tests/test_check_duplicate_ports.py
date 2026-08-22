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
extract_unresolved = mod.extract_unresolved


def _write_compose(tmp_path: Path, content: str) -> Path:
    f = tmp_path / "docker-compose.yml.j2"
    f.write_text(textwrap.dedent(content))
    return f


def _ports(f: Path) -> list[str]:
    return [p for _, _, p in extract_host_ports(f)]


def _fake_repo(tmp_path: Path, content: str, role: str = "myrole") -> Path:
    """Build a minimal repo tree so main() can be driven end to end."""
    d = tmp_path / "roles" / role / "templates"
    d.mkdir(parents=True)
    (d / "docker-compose.yml.j2").write_text(textwrap.dedent(content))
    return tmp_path


# ---------------------------------------------------------------------------
# Behaviour that already worked and must keep working
# ---------------------------------------------------------------------------


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
    assert _ports(f) == ["3000/tcp", "5432/tcp"]


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
    assert _ports(f) == ["3000/tcp", "3000/tcp"]


def test_tcp_udp_same_port_not_duplicate(tmp_path: Path) -> None:
    """The same number on tcp and udp is legitimate, not a collision."""
    f = _write_compose(tmp_path, """\
        services:
          syncthing:
            image: syncthing
            ports:
              - "22000:22000/tcp"
              - "22000:22000/udp"
    """)
    assert _ports(f) == ["22000/tcp", "22000/udp"]
    assert len(set(_ports(f))) == 2


def test_unquoted_ports(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          app:
            image: myapp
            ports:
              - 8080:80
    """)
    assert extract_host_ports(f) == [("app", 5, "8080/tcp")]


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
    assert [svc for svc, _, _ in extract_host_ports(f)] == ["frontend", "backend"]


def test_empty_file(tmp_path: Path) -> None:
    assert extract_host_ports(_write_compose(tmp_path, "")) == []


def test_no_ports_section(tmp_path: Path) -> None:
    f = _write_compose(tmp_path, """\
        services:
          app:
            image: myapp
            environment:
              - FOO=bar
    """)
    assert extract_host_ports(f) == []


# ---------------------------------------------------------------------------
# The bugs this rewrite exists to fix. The old checker was measurably wrong on
# both: it reported ZERO ports for each of these inputs, and therefore "OK".
# ---------------------------------------------------------------------------


def test_trailing_comment_does_not_hide_the_port(tmp_path: Path) -> None:
    """A trailing comment used to defeat the regex entirely.

    This is the repo's dominant style (roles/media_vm publishes 6 such lines),
    so the old checker was blind to most of its busiest host.
    """
    f = _write_compose(tmp_path, """\
        services:
          slskd:
            image: slskd
            ports:
              - 5030:5030 # slskd WebUI
    """)
    assert _ports(f) == ["5030/tcp"]


def test_comment_does_not_terminate_the_ports_block(tmp_path: Path) -> None:
    """The second, worse half of the old bug.

    A non-matching line inside `ports:` set in_ports=False, so every port AFTER
    a commented one was dropped too — not just the commented one.
    """
    f = _write_compose(tmp_path, """\
        services:
          media:
            image: media
            ports:
              - 5030:5030 # slskd WebUI
              - 50300:50300 # Soulseek P2P
              - 8080:8080 # qBittorrent
    """)
    assert _ports(f) == ["5030/tcp", "50300/tcp", "8080/tcp"]


# ---------------------------------------------------------------------------
# Hazards introduced by THIS rewrite, and the guards against them.
#
# The old checker got these right for free, because it never parsed YAML and
# never rendered Jinja — it only ever regexed raw text. Moving to a real parser
# fixes the bugs above but opens these three, so each has a guard. Filed here
# rather than above because claiming "this was broken before" would be false.
# ---------------------------------------------------------------------------


def test_sexagesimal_port_is_not_mangled(tmp_path: Path) -> None:
    """PyYAML implements YAML 1.1, where `8080:30` is a base-60 integer.

    `yaml.safe_load` turns it into 484830 (8080*60+30). Reading the raw scalar
    node instead keeps it a string. Any unquoted port whose container side is
    00-59 would otherwise be silently corrupted.
    """
    f = _write_compose(tmp_path, """\
        services:
          a:
            ports:
              - 8080:30
          b:
            ports:
              - 5000:59
    """)
    assert _ports(f) == ["8080/tcp", "5000/tcp"]


def test_ip_bound_ports_are_scoped_not_collided(tmp_path: Path) -> None:
    """Two services on :80 bound to different IPs do not collide."""
    f = _write_compose(tmp_path, """\
        services:
          a:
            ports:
              - "127.0.0.1:80:80"
          b:
            ports:
              - "192.168.2.5:80:80"
    """)
    ports = _ports(f)
    assert len(set(ports)) == 2, ports


def test_jinja_conditional_block_is_omitted_when_undefined(tmp_path: Path) -> None:
    """A KNOWN LIMITATION, pinned here so it is a decision and not a surprise.

    An undefined condition is falsy, so `{% if %}` bodies are dropped and any
    ports inside them go unchecked. Falsy is the deliberate choice: making
    undefined truthy would check more, but an `{% if %}/{% else %}` publishing
    the same port on both branches would then report a collision that cannot
    happen, and a gate that cries wolf gets switched off.

    Currently theoretical for this repo — no template publishes a port inside a
    bare `{% if %}`. The only ports under a Jinja construct are in
    roles/agent_lxc inside a `{% for %}`, which IS reported (see LOOP_RE).
    """
    f = _write_compose(tmp_path, """\
        services:
          app:
            ports:
              - "3000:3000"
        {% if enable_debug %}
          debugger:
            ports:
              - "9229:9229"
        {% endif %}
    """)
    # enable_debug is undefined -> falsy -> the block is omitted entirely.
    assert _ports(f) == ["3000/tcp"]


def test_templated_port_is_reported_not_silently_dropped(tmp_path: Path) -> None:
    """A port behind a variable cannot be checked offline — but it must be SEEN.

    Silence here is what made the old checker's "OK" misleading.
    """
    f = _write_compose(tmp_path, """\
        services:
          frontend:
            ports:
              - "{{ family_finances_port }}:80"
    """)
    assert _ports(f) == []
    unresolved = extract_unresolved(f)
    assert len(unresolved) == 1
    assert unresolved[0][0] == "frontend"


def test_undefined_image_tag_does_not_break_parsing(tmp_path: Path) -> None:
    """`image: portainer/agent:{{ ver }}` renders to a trailing colon.

    If undefined rendered as empty, that trailing colon makes YAML read a
    mapping key and the whole document fails to parse — losing every port in
    the file. The sentinel keeps it a valid scalar.
    """
    f = _write_compose(tmp_path, """\
        services:
          agent:
            image: portainer/agent:{{ portainer_agent_version }}
            ports:
              - "9001:9001"
    """)
    assert _ports(f) == ["9001/tcp"]


# ---------------------------------------------------------------------------
# The gate must be able to go RED. These drive main() end to end.
# ---------------------------------------------------------------------------


def test_main_exits_1_on_duplicate_with_trailing_comments(tmp_path: Path) -> None:
    """THE regression test: this exact input exits 0 on the old checker.

    Two services claiming host port 3000, both lines carrying a trailing
    comment. The old regex matched neither, saw no ports, and reported OK.
    """
    root = _fake_repo(tmp_path, """\
        services:
          app:
            ports:
              - 3000:3000 # web ui
          other:
            ports:
              - 3000:8080 # DUPLICATE of app
    """)
    assert mod.main(["--root", str(root)]) == 1


def test_main_exits_0_on_a_clean_tree(tmp_path: Path) -> None:
    root = _fake_repo(tmp_path, """\
        services:
          app:
            ports:
              - 3000:3000 # web ui
          other:
            ports:
              - 3001:8080 # fine
    """)
    assert mod.main(["--root", str(root)]) == 0


def test_main_exits_1_on_an_unparseable_template(tmp_path: Path) -> None:
    """A template we cannot read must fail loudly, not count as having no ports."""
    root = _fake_repo(tmp_path, """\
        services:
          app:
            ports:
             - "3000:3000"
              - nope: [unbalanced
    """)
    assert mod.main(["--root", str(root)]) == 1
