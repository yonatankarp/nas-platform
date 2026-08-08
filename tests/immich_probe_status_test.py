#!/usr/bin/env python3
"""Render the Immich database probe classifier with the pinned Jinja engine."""

from pathlib import Path

import ansible
import yaml
from jinja2 import Environment, StrictUndefined


ROOT = Path(__file__).resolve().parents[1]


def load_classifier_template():
    role_path = ROOT / "roles" / "immich" / "tasks" / "main.yml"
    tasks = yaml.safe_load(role_path.read_text())
    classifier = next(
        task
        for task in tasks
        if task.get("name") == "Classify the Immich database credential probe"
    )
    return classifier["ansible.builtin.set_fact"]["immich_database_probe_status"]


def render_status(environment, template, identity):
    return environment.from_string(template).render(
        immich_database_identity=identity,
        vault_immich_db_username="immich",
        vault_immich_db_name="immich",
    )


def expect_exact(label, rendered, expected):
    if rendered != expected:
        raise AssertionError(
            f"{label}: expected {expected!r}, got {rendered!r}"
        )


def main():
    template = load_classifier_template()
    environment = Environment(undefined=StrictUndefined)

    cases = [
        ("missing rc", {}, "execution-failed"),
        ("connection rejected", {"rc": 1, "stdout": ""}, "connection-rejected"),
        (
            "identity mismatch",
            {"rc": 0, "stdout": "other/immich\n"},
            "identity-mismatch",
        ),
        ("verified", {"rc": 0, "stdout": "immich/immich\n"}, "verified"),
    ]
    for label, identity, expected in cases:
        rendered = render_status(environment, template, identity)
        expect_exact(label, rendered, expected)

    padded_rendered = render_status(
        environment,
        " " + template,
        {"rc": 0, "stdout": "immich/immich\n"},
    )
    try:
        expect_exact("leading-space counterexample", padded_rendered, "verified")
    except AssertionError:
        pass
    else:
        raise AssertionError("leading-space counterexample passed exact comparison")

    print(f"Immich probe semantic test passed (ansible-core {ansible.__version__})")


if __name__ == "__main__":
    main()
