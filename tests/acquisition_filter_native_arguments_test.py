#!/usr/bin/env python3
"""Filters must receive plain containers, not the play's templated proxies.

Ansible hands a filter its arguments as templated proxies whose every element
access re-enters the templating engine. The relationship filters walk deep
structures, so that cost multiplies: measured against one real converge, seven
Configarr tasks cost 554s with the proxies and disappear from the profile
without them, taking the play from 820s to 239s. The conversion is therefore
load-bearing, and this check fails if it is removed or narrowed.

The conversion itself lives in `module_utils/acquisition_schema.py`, and each of
the three acquisition filter plugins wraps every filter it exposes with it. All
three are checked here, so a plugin added later that forgets the wrapper is
caught by the same run.

Run with --self-test to prove the check detects its own regression.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "module_utils" / "acquisition_schema.py"
DOMAINS = ("servarr", "bazarr", "configarr")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"{path} cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_plugins():
    schema = load("acquisition_schema", SCHEMA)
    plugins = {
        domain: load(
            f"acquisition_{domain}", ROOT / "filter_plugins" / f"acquisition_{domain}.py"
        )
        for domain in DOMAINS
    }
    return schema, plugins


class TaggedStr(str):
    """Stands in for the play's tagged string type."""


class TaggedDict(dict):
    """Stands in for the play's lazy mapping type."""


class TaggedList(list):
    """Stands in for the play's lazy sequence type."""


def check(failures, condition, message):
    if not condition:
        failures.append(message)


def exact_types(failures, value, label):
    """Every container and scalar must be the base type, at every depth."""
    if isinstance(value, dict):
        check(failures, type(value) is dict, f"{label} is {type(value).__name__}, not dict")
        for key, item in value.items():
            exact_types(failures, key, f"{label} key")
            exact_types(failures, item, f"{label}[{key!r}]")
    elif isinstance(value, list):
        check(failures, type(value) is list, f"{label} is {type(value).__name__}, not list")
        for index, item in enumerate(value):
            exact_types(failures, item, f"{label}[{index}]")
    elif isinstance(value, str):
        check(failures, type(value) is str, f"{label} is {type(value).__name__}, not str")


def collect_failures(schema, plugins):
    failures = []

    native = schema.native
    tagged = TaggedDict({
        TaggedStr("name"): TaggedStr("Radarr"),
        TaggedStr("items"): TaggedList([
            TaggedDict({TaggedStr("id"): 11, TaggedStr("allowed"): True}),
            TaggedStr("plain"),
        ]),
        TaggedStr("absent"): None,
    })
    converted = native(tagged)
    exact_types(failures, converted, "converted")
    check(failures, converted == tagged, "conversion changed the value, not only the type")

    # Scalars must keep their identity: a bool must not become an int, and a
    # missing value must stay missing.
    check(failures, converted["items"][0]["allowed"] is True, "conversion lost a true boolean")
    check(failures, converted["absent"] is None, "conversion lost a null")
    check(failures, native(False) is False, "conversion lost a false boolean")

    # Every exposed filter of every acquisition plugin must be wrapped, so a
    # filter added later cannot silently skip the conversion.
    exposed_names = set()
    for domain, plugin in plugins.items():
        exposed = plugin.FilterModule().filters()
        check(failures, bool(exposed), f"acquisition_{domain} exposes no filters")
        for name, function in exposed.items():
            check(failures, name not in exposed_names,
                  f"filter {name} is exposed by more than one acquisition plugin")
            exposed_names.add(name)
            check(failures, hasattr(function, "__wrapped__"),
                  f"filter {name} is exposed without argument conversion")

    # The wrapper must reach the filter body, not merely sit beside it.
    seen = {}

    def spy(first, second=None):
        seen["first"] = first
        seen["second"] = second
        return "ok"

    wrapped = schema.with_native_arguments(spy)
    check(failures, wrapped(tagged, second=TaggedList([TaggedStr("x")])) == "ok",
          "the wrapper did not return the filter's own result")
    exact_types(failures, seen.get("first"), "filter positional argument")
    exact_types(failures, seen.get("second"), "filter keyword argument")

    return failures


def main():
    schema, plugins = load_plugins()

    if "--self-test" in sys.argv:
        # Plant the regression this check exists to catch: expose the filters
        # without the conversion.
        for plugin in plugins.values():
            plugin.FilterModule.filters = plugin.FilterModule._relationship_filters
            plugin._with_native_arguments = lambda function: function
        schema.with_native_arguments = lambda function: function
        if not collect_failures(schema, plugins):
            sys.exit("self-test failed: unconverted filter arguments were accepted")
        print("acquisition filter argument conversion: self-test detects its own removal")
        return

    failures = collect_failures(schema, plugins)
    if failures:
        sys.exit("\n".join(failures))
    print("acquisition filter arguments: every exposed filter receives plain containers")


if __name__ == "__main__":
    main()
