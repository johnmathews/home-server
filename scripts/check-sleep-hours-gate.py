#!/usr/bin/env python3
"""Decide whether the sleep_hours suite should run — and fail loudly if it cannot tell.

This replaces the grep that `.github/workflows/test.yml` used to run:

    if grep -rq 'sleep_hours_enabled:\\s*true' host_vars/; then ... else skip; fi

That grep is unsafe by default. A renamed variable, a typo, a deleted `host_vars/`
and a genuinely-disabled feature all produce the same answer — "no match" — and the
workflow skipped every real step while reporting success. It did so on every run
from 2026-01-27 to 2026-08-22, seven months of green checks attesting to nothing.

The gate is kept; its failure mode is inverted. There are now three outcomes, not
two:

    run    every host the role targets declares sleep_hours_enabled, and at least
           one declares it true
    skip   every host the role targets declares sleep_hours_enabled, and all of
           them declare it false -- a deliberate, verified skip
    ERROR  anything else: host_vars/ missing or empty, a file that will not parse,
           a targeted host with no declaration, or a declaration that is not a
           YAML boolean

"Anything else" is the case the old grep silently folded into "skip".

The set of hosts that must declare the variable is derived, not hardcoded: it is
the `hosts:` of every playbook that applies `roles/sleep_hours`. Add the role to a
fifth playbook and that host is required to declare the variable from then on.

Exit codes: 0 = decided (run or skip), 1 = ERROR, 2 = bad usage.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
PLAYBOOK_DIR = REPO_ROOT / "playbooks"
HOST_VARS_DIR = REPO_ROOT / "host_vars"
ROLE_NAME = "sleep_hours"
VAR_NAME = "sleep_hours_enabled"


class _TolerantLoader(yaml.SafeLoader):
    """SafeLoader that does not choke on Ansible's `!vault` tags.

    host_vars files are not vaulted today, but group_vars are, and nothing stops a
    host_vars file from gaining an inline `!vault` block. Refusing to parse one
    would turn this gate red for a reason that has nothing to do with the gate.

    This subclasses SafeLoader and stays safe. The multi-constructor below is
    registered for the single-bang prefix `!`, which matches only local tags such
    as `!vault`. PyYAML expands `!!python/object/apply:os.system` to
    `tag:yaml.org,2002:python/object/apply:os.system` -- no leading `!` -- so it
    does not match, SafeLoader has no constructor for it, and it raises
    ConstructorError. tests/test_check_sleep_hours_gate.py asserts exactly that.
    """


_TolerantLoader.add_constructor(
    "!vault", lambda loader, node: "<vaulted>"
)
_TolerantLoader.add_multi_constructor(
    "!", lambda loader, suffix, node: f"<unparsed-tag:{suffix}>"
)


class GateError(Exception):
    """A condition the old grep would have silently reported as 'skip'."""


def _load_yaml(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return yaml.load(handle, Loader=_TolerantLoader)
    except (OSError, yaml.YAMLError) as exc:
        raise GateError(f"{path.relative_to(REPO_ROOT)} could not be parsed: {exc}") from exc


def _play_uses_role(play: Any, role_name: str) -> bool:
    """True if `play` applies `role_name`, in either roles: spelling.

    Ansible accepts both `- rolename` and `- role: rolename` (plus `name:`), so a
    check that understood only one of them would go quietly blind the day someone
    switched spelling.
    """
    if not isinstance(play, dict):
        return False
    for entry in play.get("roles") or []:
        if isinstance(entry, str) and entry == role_name:
            return True
        if isinstance(entry, dict) and entry.get("role", entry.get("name")) == role_name:
            return True
    return False


def targeted_hosts() -> dict[str, Path]:
    """Map each host that the sleep_hours role is applied to -> its playbook."""
    if not PLAYBOOK_DIR.is_dir():
        raise GateError(f"{PLAYBOOK_DIR.relative_to(REPO_ROOT)}/ does not exist")

    hosts: dict[str, Path] = {}
    for playbook in sorted(PLAYBOOK_DIR.glob("*.yml")):
        plays = _load_yaml(playbook)
        if not isinstance(plays, list):
            continue
        for play in plays:
            if not _play_uses_role(play, ROLE_NAME):
                continue
            target = play.get("hosts")
            if not isinstance(target, str) or not target.strip():
                raise GateError(
                    f"{playbook.relative_to(REPO_ROOT)} applies the {ROLE_NAME} role "
                    f"but its `hosts:` is missing or not a plain string"
                )
            hosts[target.strip()] = playbook

    if not hosts:
        raise GateError(
            f"no playbook in {PLAYBOOK_DIR.relative_to(REPO_ROOT)}/ applies the "
            f"{ROLE_NAME} role. Either the role was removed and this workflow "
            f"should go with it, or the roles: entry was renamed and this gate can "
            f"no longer tell which hosts to check."
        )
    return hosts


def declared_state(host: str, playbook: Path) -> bool:
    """Read `sleep_hours_enabled` for one host. Absent or non-boolean is an error."""
    path = HOST_VARS_DIR / f"{host}.yml"
    if not path.is_file():
        raise GateError(
            f"{playbook.relative_to(REPO_ROOT)} applies the {ROLE_NAME} role to "
            f"'{host}', but host_vars/{host}.yml does not exist, so {VAR_NAME} "
            f"cannot be read"
        )

    data = _load_yaml(path)
    if not isinstance(data, dict):
        raise GateError(f"host_vars/{host}.yml did not parse to a mapping")

    if VAR_NAME not in data:
        raise GateError(
            f"host_vars/{host}.yml does not define {VAR_NAME}. The {ROLE_NAME} role "
            f"is applied to this host, so the variable must be declared explicitly "
            f"-- true or false. An absent variable used to read as 'false' here and "
            f"skip the whole suite; it is now an error, because a rename and a "
            f"deliberate disable are not the same thing."
        )

    value = data[VAR_NAME]
    if not isinstance(value, bool):
        raise GateError(
            f"host_vars/{host}.yml sets {VAR_NAME}: {value!r} "
            f"({type(value).__name__}). It must be a YAML boolean -- bare true or "
            f"false, not a quoted string, not 'yes'/'no'."
        )
    return value


def main() -> int:
    if len(sys.argv) > 1:
        print(f"usage: {Path(sys.argv[0]).name}   (takes no arguments)", file=sys.stderr)
        return 2

    if not HOST_VARS_DIR.is_dir():
        print(f"ERROR: {HOST_VARS_DIR.relative_to(REPO_ROOT)}/ does not exist", file=sys.stderr)
        return 1
    if not any(HOST_VARS_DIR.glob("*.yml")):
        print(f"ERROR: {HOST_VARS_DIR.relative_to(REPO_ROOT)}/ contains no .yml files", file=sys.stderr)
        return 1

    try:
        hosts = targeted_hosts()
        states = {host: declared_state(host, pb) for host, pb in sorted(hosts.items())}
    except GateError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for host, value in states.items():
        print(f"  {host:24} {VAR_NAME} = {str(value).lower()}")

    enabled = any(states.values())
    if enabled:
        on = [h for h, v in states.items() if v]
        print(f"\n{VAR_NAME} is true on {len(on)} of {len(states)} hosts ({', '.join(on)}).")
        print("Running the sleep_hours suite.")
    else:
        print(f"\nAll {len(states)} hosts that run the {ROLE_NAME} role declare "
              f"{VAR_NAME}: false.")
        print("Skipping the sleep_hours suite -- this is a verified skip, not an "
              "unreadable config.")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            handle.write(f"enabled={'true' if enabled else 'false'}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
