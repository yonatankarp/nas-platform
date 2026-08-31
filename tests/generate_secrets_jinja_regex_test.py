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

# Bazarr's settings form is POSTed exactly these two, and Bazarr casts every
# submitted value with int() unless the last dash-segment of its key is one of
# config.py's str_keys -- `apikey` is not. A key of only decimal digits is
# therefore an int by the time dynaconf validates the schema, fails
# `is_type_of str`, and the request is answered 406 for as long as the key is
# deployed. The other three keys never reach that cast, and the play must not
# refuse them for a shape Bazarr never sees, so the split is asserted in both
# directions rather than left to whichever conditions happen to be written.
BAZARR_SUBMITTED_KEYS = ["arr_radarr_api_key", "arr_sonarr_api_key"]
ALL_DIGIT_KEY = "1" * 32


def guards_for(environment, conditions, key, test):
    """Compile every `<key> is <test>(...)` condition, in the order written."""
    prefix = f"{key} is {test}("
    compiled = []
    for expression in conditions:
        if not expression.startswith(prefix):
            continue
        try:
            compiled.append(environment.compile_expression(expression))
        except (TemplateSyntaxError, SyntaxWarning) as error:
            raise AssertionError(
                f"{key} does not parse under strict warnings: {error}"
            ) from error
    return compiled


def main() -> None:
    play = yaml.safe_load((ROOT / "generate-secrets.yml").read_text())[0]
    assertion = next(
        task for task in play["tasks"]
        if task["name"] == "Fail loudly if any value did not parse"
    )
    conditions = assertion["ansible.builtin.assert"]["that"]
    environment = Environment()
    environment.tests["match"] = lambda value, pattern: re.match(pattern, value) is not None
    environment.tests["search"] = lambda value, pattern: re.search(pattern, value) is not None

    with warnings.catch_warnings():
        warnings.simplefilter("error")
        for key in API_KEYS:
            matches = guards_for(environment, conditions, key, "match")
            assert len(matches) == 1, f"{key} must carry exactly one shape guard"
            guard = matches[0]
            assert guard(**{key: "a" * 32}), f"{key} rejects 32 lowercase hex characters"
            for invalid in ("a" * 31, "a" * 33, "A" * 32, "g" * 32, "a" * 32 + "\n"):
                assert not guard(**{key: invalid}), f"{key} accepts invalid value {invalid!r}"

            searches = guards_for(environment, conditions, key, "search")
            expected = 1 if key in BAZARR_SUBMITTED_KEYS else 0
            assert len(searches) == expected, (
                f"{key} must carry {expected} letter guard(s), not {len(searches)}"
            )

            # The whole guard set for this key is what the play actually asserts,
            # so the all-digit verdict is read off all of it rather than off the
            # condition this test happens to have selected.
            accepted = all(
                guard(**{key: ALL_DIGIT_KEY}) for guard in matches + searches
            )
            if key in BAZARR_SUBMITTED_KEYS:
                assert not accepted, f"{key} accepts an all-digit key Bazarr refuses"
                assert all(
                    guard(**{key: "a" * 32}) for guard in searches
                ), f"{key} rejects a key that does contain an a-f character"
            else:
                assert accepted, f"{key} refuses an all-digit key Bazarr never sees"

    print("generated API-key guards: strict Jinja parsing, exact lowercase-hex "
          "semantics and the Bazarr all-digit split hold")


if __name__ == "__main__":
    main()
