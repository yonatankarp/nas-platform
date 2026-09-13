"""Filter for identifying the encrypted vault artifacts a run was made against.

`platform_vault_file` is report identity and nothing else: no credential reaches
Ansible through it. `roles/vault_contract` selects the encrypted artifacts, and
this turns that selection into one stable identifier so the recorded fact keeps
the single 64-character shape its consumers expect however many files there are.

The identifier is a digest over `"<basename>:<digest>"` lines rather than over
the concatenated file digests, because the names are part of what identifies a
deployment: two vaults holding the same ciphertext under different service names
are not the same artifact set, and a digest of digests alone cannot say so.
"""

import hashlib
import os

from ansible.errors import AnsibleFilterError

HEX_DIGITS = set("0123456789abcdef")


def vault_artifact_identity(files):
    """Fold selected vault artifacts into one SHA-256 identifier.

    Takes the `files` list of an `ansible.builtin.find` result gathered with
    `get_checksum: true` and `checksum_algorithm: sha256`.

    Refuses an empty selection rather than returning the digest of nothing. A
    selection rule that selects none of its subjects is the failure this
    repository keeps closing, and an empty list has a perfectly good digest that
    would read as success.
    """
    if not isinstance(files, list):
        raise AnsibleFilterError("vault artifact selection must be a list")
    if not files:
        raise AnsibleFilterError(
            "no encrypted vault artifact was selected; an empty selection has a "
            "digest and would otherwise report a successful identification"
        )

    entries = []
    for entry in files:
        if not isinstance(entry, dict):
            raise AnsibleFilterError("each vault artifact must be a mapping")

        path = entry.get("path")
        checksum = entry.get("checksum")
        if not isinstance(path, str) or not path:
            raise AnsibleFilterError("each vault artifact must carry a nonempty path")
        if (
            not isinstance(checksum, str)
            or len(checksum) != 64
            or not set(checksum).issubset(HEX_DIGITS)
        ):
            # Reached when find ran without get_checksum, which would otherwise
            # fold None into the identifier and produce a stable-looking value
            # that identifies nothing.
            raise AnsibleFilterError(
                f"vault artifact {os.path.basename(path)} has no SHA-256 checksum"
            )

        entries.append((os.path.basename(path), checksum))

    names = [name for name, _ in entries]
    if len(set(names)) != len(names):
        # find does not recurse here, so this means two selections resolved to
        # one basename, and the identifier would silently depend on which came
        # first.
        raise AnsibleFilterError("vault artifacts must have distinct basenames")

    # Sorted by basename, stated rather than incidental: the identifier has to
    # be the same on the NAS, in CI and on a Mac, and find's order is the
    # directory's.
    #
    # NUL-delimited rather than ":" and newline, because a basename may contain
    # either of those and the join would then be ambiguous -- "a.yml:<digest>\n
    # b.yml" as one name reads the same as two records. NUL cannot occur in a
    # basename on any filesystem this runs on, and a checksum is exactly 64 hex
    # characters, so a NUL after each field makes every record self-delimiting.
    digest = hashlib.sha256()
    for name, checksum in sorted(entries):
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(checksum.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


class FilterModule:
    """Expose the vault artifact identity filter."""

    def filters(self):
        return {"vault_artifact_identity": vault_artifact_identity}
