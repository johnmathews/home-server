"""Tests for scripts/check-sleep-hours-gate.py.

The point of this gate is that it goes RED where its predecessor went green. Most
of what follows is therefore a red-path test: each one constructs the exact
misconfiguration that the old `grep -rq 'sleep_hours_enabled:\\s*true'` reported as
"feature disabled, skipping" and asserts the gate now exits 1.
"""

import importlib.util
import textwrap
from pathlib import Path

import pytest
import yaml

spec = importlib.util.spec_from_file_location(
    "check_sleep_hours_gate",
    Path(__file__).resolve().parent.parent / "scripts" / "check-sleep-hours-gate.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


PLAYBOOK = """\
- name: Media VM
  hosts: media-vm
  roles:
    - role: sleep_hours
"""


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """A minimal repo: one playbook applying sleep_hours to one host."""
    (tmp_path / "playbooks").mkdir()
    (tmp_path / "host_vars").mkdir()
    (tmp_path / "playbooks" / "media_vm.yml").write_text(PLAYBOOK)
    monkeypatch.setattr(mod, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(mod, "PLAYBOOK_DIR", tmp_path / "playbooks")
    monkeypatch.setattr(mod, "HOST_VARS_DIR", tmp_path / "host_vars")
    return tmp_path


def _host_vars(repo: Path, body: str, host: str = "media-vm") -> None:
    (repo / "host_vars" / f"{host}.yml").write_text(textwrap.dedent(body))


def _run(monkeypatch, argv=("check-sleep-hours-gate.py",)) -> int:
    monkeypatch.setattr(mod.sys, "argv", list(argv))
    return mod.main()


# ---------------------------------------------------------------------------
# The two outcomes that are allowed to be green


def test_all_false_is_a_verified_skip(repo, monkeypatch, capsys):
    _host_vars(repo, "sleep_hours_enabled: false\n")
    assert _run(monkeypatch) == 0
    assert "Skipping the sleep_hours suite" in capsys.readouterr().out


def test_any_true_runs_the_suite(repo, monkeypatch, capsys):
    _host_vars(repo, "sleep_hours_enabled: true\n")
    assert _run(monkeypatch) == 0
    assert "Running the sleep_hours suite" in capsys.readouterr().out


def test_enabled_is_written_to_github_output(repo, monkeypatch, tmp_path):
    _host_vars(repo, "sleep_hours_enabled: true\n")
    out = tmp_path / "gh-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    assert _run(monkeypatch) == 0
    assert out.read_text() == "enabled=true\n"


def test_disabled_is_written_to_github_output(repo, monkeypatch, tmp_path):
    _host_vars(repo, "sleep_hours_enabled: false\n")
    out = tmp_path / "gh-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    assert _run(monkeypatch) == 0
    assert out.read_text() == "enabled=false\n"


# ---------------------------------------------------------------------------
# Everything the old grep folded into "skip" and must now be an ERROR


def test_renamed_variable_is_an_error(repo, monkeypatch, capsys):
    """The regression that produced seven months of meaningless green checks."""
    _host_vars(repo, "sleep_hours_active: false\n")
    assert _run(monkeypatch) == 1
    assert "does not define sleep_hours_enabled" in capsys.readouterr().err


def test_missing_host_vars_file_is_an_error(repo, monkeypatch, capsys):
    (repo / "host_vars" / "unrelated.yml").write_text("a: 1\n")
    assert _run(monkeypatch) == 1
    assert "host_vars/media-vm.yml does not exist" in capsys.readouterr().err


def test_empty_host_vars_dir_is_an_error(repo, monkeypatch, capsys):
    assert _run(monkeypatch) == 1
    assert "contains no .yml files" in capsys.readouterr().err


def test_absent_host_vars_dir_is_an_error(repo, monkeypatch, capsys):
    monkeypatch.setattr(mod, "HOST_VARS_DIR", repo / "nope")
    assert _run(monkeypatch) == 1
    assert "does not exist" in capsys.readouterr().err


def test_unparseable_host_vars_is_an_error(repo, monkeypatch, capsys):
    _host_vars(repo, "sleep_hours_enabled: false\n  bad: [indent\n")
    assert _run(monkeypatch) == 1
    assert "could not be parsed" in capsys.readouterr().err


@pytest.mark.parametrize("literal", ['"false"', "'true'", "no", "yes", "0", "1", "null"])
def test_non_boolean_declaration_is_an_error(repo, monkeypatch, capsys, literal):
    """`yes`/`no`/`"false"` all read as truthy-or-not in ways YAML 1.1 vs 1.2 disagree on.

    PyYAML resolves bare yes/no to booleans, so those two are accepted; the point
    of the test is that the quoted and numeric spellings, which a human reads as
    boolean and the gate would silently mis-handle, are refused.
    """
    _host_vars(repo, f"sleep_hours_enabled: {literal}\n")
    rc = _run(monkeypatch)
    if isinstance(yaml.safe_load(f"v: {literal}")["v"], bool):
        assert rc == 0
    else:
        assert rc == 1
        assert "must be a YAML boolean" in capsys.readouterr().err


def test_role_removed_from_every_playbook_is_an_error(repo, monkeypatch, capsys):
    """A gate that can no longer find its subject must say so, not skip."""
    (repo / "playbooks" / "media_vm.yml").write_text(
        "- name: Media VM\n  hosts: media-vm\n  roles:\n    - role: something_else\n"
    )
    _host_vars(repo, "sleep_hours_enabled: false\n")
    assert _run(monkeypatch) == 1
    assert "no playbook" in capsys.readouterr().err


def test_playbook_with_no_hosts_is_an_error(repo, monkeypatch, capsys):
    (repo / "playbooks" / "media_vm.yml").write_text(
        "- name: Media VM\n  roles:\n    - role: sleep_hours\n"
    )
    _host_vars(repo, "sleep_hours_enabled: false\n")
    assert _run(monkeypatch) == 1
    assert "`hosts:` is missing" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# Coverage of the derivation itself


def test_bare_string_roles_spelling_is_recognised(repo, monkeypatch):
    """`- sleep_hours` and `- role: sleep_hours` are both valid Ansible."""
    (repo / "playbooks" / "media_vm.yml").write_text(
        "- name: Media VM\n  hosts: media-vm\n  roles:\n    - sleep_hours\n"
    )
    _host_vars(repo, "sleep_hours_enabled: true\n")
    assert _run(monkeypatch) == 0


def test_every_targeted_host_must_declare_it(repo, monkeypatch, capsys):
    """One host declaring true does not excuse another from declaring anything."""
    (repo / "playbooks" / "second.yml").write_text(
        "- name: Second\n  hosts: other-host\n  roles:\n    - role: sleep_hours\n"
    )
    _host_vars(repo, "sleep_hours_enabled: true\n")
    _host_vars(repo, "unrelated: 1\n", host="other-host")
    assert _run(monkeypatch) == 1
    assert "host_vars/other-host.yml does not define" in capsys.readouterr().err


def test_playbook_not_applying_the_role_is_ignored(repo, monkeypatch):
    (repo / "playbooks" / "unrelated.yml").write_text(
        "- name: Other\n  hosts: nowhere\n  roles:\n    - role: traefik\n"
    )
    _host_vars(repo, "sleep_hours_enabled: false\n")
    assert _run(monkeypatch) == 0


# ---------------------------------------------------------------------------
# The loader stays safe despite using yaml.load with a custom Loader


@pytest.mark.parametrize(
    "payload",
    ["!!python/object/apply:os.system ['echo pwned']", "!!python/name:os.system"],
)
def test_loader_refuses_python_object_tags(payload):
    with pytest.raises(yaml.YAMLError):
        yaml.load(payload, Loader=mod._TolerantLoader)


def test_loader_accepts_ansible_vault_tags():
    doc = "secret: !vault |\n  $ANSIBLE_VAULT;1.1;AES256\n  3363\n"
    assert yaml.load(doc, Loader=mod._TolerantLoader) == {"secret": "<vaulted>"}


def test_rejects_arguments(monkeypatch):
    assert _run(monkeypatch, argv=("check-sleep-hours-gate.py", "--force")) == 2
