#!/bin/sh
# Name-only wrapper: the shared plumbing lives in run-contract.sh. The path is
# kept because the drift hooks and the Mac hook regression tests address it by
# name, the latter by replacing it with a stub of their own.
set -eu
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/run-contract.sh" beszel "$@"
