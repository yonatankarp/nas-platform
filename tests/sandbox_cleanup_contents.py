# Clear one disposable sandbox directory, from inside a container, without ever
# following a symlink out of it.
#
# usage: python sandbox_cleanup_contents.py NAME PRESERVE
#
# NAME is a basename under /sandbox-parent, which tests/sandbox_cleanup.sh
# bind-mounts the sandbox's parent at, and PRESERVE is the ownership marker to
# keep and restore if the final rmdir fails -- empty when there is none. Both
# are validated against fixed patterns before anything is opened, because this
# program deletes trees and the only thing standing between it and the wrong
# tree is the shape of its first argument.
#
# Every traversal is by directory file descriptor with O_NOFOLLOW, so a symlink
# planted mid-walk is unlinked rather than followed. That is what the
# `--filter` and marker checks in the shell cannot provide and why this is
# Python at all: `rm -rf` cannot express it.
#
# It arrived as a `cat <<'PY'` heredoc inside a shell function until #315, where
# no linter reached it, `python -m py_compile` could not, and a reader had to
# find it inside a wrapper. tests/sandbox_cleanup.sh redirects this file into
# the container's standard input instead, which is byte for byte what the
# heredoc piped there. The body below is unchanged.
import os
import re
import stat
import sys


name = sys.argv[1]
preserve = sys.argv[2]
supported_names = (
    r"nas-platform-integration\.[A-Za-z0-9]{6}",
    r"nas-platform-cleanup\.[A-Za-z0-9]{6}",
    r"nas-platform-mac\.[A-Za-z0-9]{6}",
    r"nas-platform-mac\.[A-Za-z0-9]{6}\.reports",
)
if not any(re.fullmatch(pattern, name) for pattern in supported_names):
    raise ValueError("invalid sandbox basename")
if preserve and not (
    (re.fullmatch(r"nas-platform-mac\.[A-Za-z0-9]{6}", name)
     and preserve == ".nas-platform-mac-owned")
    or (re.fullmatch(r"nas-platform-mac\.[A-Za-z0-9]{6}\.reports", name)
        and preserve == ".nas-platform-mac-report-owned")
):
    raise ValueError("invalid preserved marker")

open_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def clear_directory(directory_fd, preserved_entry=""):
    for entry in os.listdir(directory_fd):
        if entry == preserved_entry:
            continue
        entry_stat = os.stat(
            entry, dir_fd=directory_fd, follow_symlinks=False
        )
        if stat.S_ISDIR(entry_stat.st_mode):
            child_fd = os.open(entry, open_flags, dir_fd=directory_fd)
            try:
                clear_directory(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(entry, dir_fd=directory_fd)
        else:
            os.unlink(entry, dir_fd=directory_fd)


parent_fd = os.open("/sandbox-parent", open_flags)
try:
    sandbox_fd = os.open(name, open_flags, dir_fd=parent_fd)
    try:
        if preserve:
            marker_fd = os.open(preserve, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=sandbox_fd)
            try:
                marker_stat = os.fstat(marker_fd)
                if not stat.S_ISREG(marker_stat.st_mode):
                    raise ValueError("preserved marker is not regular")
                marker_data = os.read(marker_fd, 4097)
                if len(marker_data) > 4096:
                    raise ValueError("preserved marker is unexpectedly large")
            finally:
                os.close(marker_fd)

            clear_directory(sandbox_fd, preserve)
            os.unlink(preserve, dir_fd=sandbox_fd)
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                recovery_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                recovery_fd = os.open(
                    preserve,
                    recovery_flags,
                    stat.S_IMODE(marker_stat.st_mode),
                    dir_fd=sandbox_fd,
                )
                try:
                    os.write(recovery_fd, marker_data)
                    os.fchmod(recovery_fd, stat.S_IMODE(marker_stat.st_mode))
                    os.fchown(recovery_fd, marker_stat.st_uid, marker_stat.st_gid)
                finally:
                    os.close(recovery_fd)
                raise
        else:
            clear_directory(sandbox_fd)
    finally:
        os.close(sandbox_fd)
finally:
    os.close(parent_fd)
