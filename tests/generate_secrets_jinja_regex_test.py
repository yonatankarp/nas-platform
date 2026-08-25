#!/usr/bin/env python3
"""Strictly parse and exercise generated acquisition API-key guards."""

from pathlib import Path
import re
import warnings

import yaml
from jinja2 import Environment, TemplateSyntaxError


ROOT = Path(__file__).resolve().parent.parent
API_KEYS = [
    "arr_radarr_api_key",
    "arr_sonarr_api_key",
    "arr_prowlarr_api_key",
    "arr_bazarr_api_key",
    "downloaders_sabnzbd_api_key",
]


def main() -> None:
    play = yaml.safe_load((ROOT / "generate-secrets.yml").read_text())[0]
    assertion = next(
        task for task in play["tasks"]
        if task["name"] == "Fail loudly if any value did not parse"
    )
    conditions = assertion["ansible.builtin.assert"]["that"]
    environment = Environment()
    environment.tests["match"] = lambda value, pattern: re.match(pattern, value) is not None

    with warnings.catch_warnings():
        warnings.simplefilter("error")
        for key in API_KEYS:
            expression = next(item for item in conditions if item.startswith(f"{key} is match("))
            try:
                guard = environment.compile_expression(expression)
            except (TemplateSyntaxError, SyntaxWarning) as error:
                raise AssertionError(f"{key} does not parse under strict warnings: {error}") from error
            assert guard(**{key: "a" * 32}), f"{key} rejects 32 lowercase hex characters"
            for invalid in ("a" * 31, "a" * 33, "A" * 32, "g" * 32, "a" * 32 + "\n"):
                assert not guard(**{key: invalid}), f"{key} accepts invalid value {invalid!r}"

    print("generated API-key guards: strict Jinja parsing and exact lowercase-hex semantics hold")


if __name__ == "__main__":
    main()
