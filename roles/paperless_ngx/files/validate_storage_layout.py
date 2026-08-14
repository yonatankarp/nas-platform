import json
import os
import sys


def refuse(message):
    raise SystemExit(f"Unsafe Paperless storage layout: {message}")


def canonical_sources(raw, label, expected_count):
    try:
        sources = json.loads(raw)
    except json.JSONDecodeError:
        refuse(f"{label} sources are not valid JSON")
    if not isinstance(sources, list) or len(sources) != expected_count:
        refuse(f"expected exactly {expected_count} {label} sources")

    canonical = []
    for source in sources:
        if (
            not isinstance(source, str)
            or not os.path.isabs(source)
            or source != os.path.normpath(source)
        ):
            refuse(f"{label} sources must be absolute normalized paths")
        canonical.append(os.path.realpath(source))
    if len(set(canonical)) != expected_count:
        refuse(f"{label} sources alias one another")
    return canonical


def overlap(left, right):
    try:
        common = os.path.commonpath([left, right])
    except ValueError:
        refuse("sources cannot be compared")
    return common in {left, right}


def main(argv):
    if len(argv) != 2:
        refuse("expected document and state source arrays")
    documents = canonical_sources(argv[0], "document", 3)
    states = canonical_sources(argv[1], "state", 5)

    for index, left in enumerate(documents):
        for right in documents[index + 1 :]:
            if overlap(left, right):
                refuse("document sources overlap")
        for state in states:
            if overlap(left, state):
                refuse("document and state sources overlap")


if __name__ == "__main__":
    main(sys.argv[1:])
