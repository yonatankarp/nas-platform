#!/usr/bin/python
"""Ask a deployed resolver real DNS questions and report what came back."""

DOCUMENTATION = r"""
---
module: adguard_dns_probe
short_description: Resolve names against a published DNS listener and report the answers
description:
  - Sends one A query per name to a listener on the target host and returns the
    addresses and the response code, so a play can assert what a resolver
    actually answers rather than what its status page claims.
options:
  host: {type: str, required: true}
  port: {type: int, required: true}
  names: {type: list, elements: str, required: true}
  timeout_seconds: {type: int, required: true}
"""

EXAMPLES = r"""
- name: Ask the deployed resolver two questions
  adguard_dns_probe:
    host: 127.0.0.1
    port: 53
    names: [doubleclick.net, example.com]
    timeout_seconds: 10
"""

RETURN = r"""
answers:
  description: Per name, the A records returned and the response code.
  type: dict
  returned: always
"""

import random
import socket
import struct

from ansible.module_utils.basic import AnsibleModule

# WHY TCP AND NOT UDP. Measured on Docker Desktop for Mac: a UDP publication of a
# container port does not carry a query from the host to the container -- `dig
# +notcp` times out where `dig +tcp` against the same publication answers in
# milliseconds. TCP works on both Docker Desktop and a Linux daemon, so it is the
# portable choice, and RFC 7766 requires every resolver to serve it.
# tests/contracts/adguard-runtime.rb records the same measurement and made the
# same choice; this module is its counterpart for the host that has no Ruby.


def build_query(name):
    header = struct.pack("!6H", random.randint(0, 0xFFFF), 0x0100, 1, 0, 0, 0)
    labels = b"".join(
        struct.pack("!B", len(part)) + part
        for part in (segment.encode("idna") for segment in name.split("."))
    )
    return header + labels + b"\0" + struct.pack("!2H", 1, 1)


def skip_name(payload, offset):
    while True:
        if offset >= len(payload):
            raise ValueError("answer ended inside a name")
        length = payload[offset]
        if length & 0xC0 == 0xC0:
            return offset + 2
        if length == 0:
            return offset + 1
        offset += 1 + length


def parse_answers(payload):
    if len(payload) < 12:
        raise ValueError("answer is shorter than a DNS header")
    flags, _questions, answer_count = struct.unpack("!H2H", payload[2:8])
    offset = skip_name(payload, 12) + 4
    addresses = []
    for _ in range(answer_count):
        offset = skip_name(payload, offset)
        if offset + 10 > len(payload):
            raise ValueError("answer ended inside a record header")
        record_type, _klass, _ttl, rdlength = struct.unpack("!2HIH", payload[offset:offset + 10])
        offset += 10
        if record_type == 1 and rdlength == 4:
            addresses.append(".".join(str(octet) for octet in payload[offset:offset + 4]))
        offset += rdlength
    return addresses, flags & 0x000F


def read_exactly(connection, count):
    buffer = b""
    while len(buffer) < count:
        chunk = connection.recv(count - len(buffer))
        if not chunk:
            raise ValueError("the resolver closed the connection mid-answer")
        buffer += chunk
    return buffer


def ask(host, port, name, timeout_seconds):
    message = build_query(name)
    connection = socket.create_connection((host, port), timeout=timeout_seconds)
    try:
        connection.settimeout(timeout_seconds)
        connection.sendall(struct.pack("!H", len(message)) + message)
        length = struct.unpack("!H", read_exactly(connection, 2))[0]
        payload = read_exactly(connection, length)
    finally:
        connection.close()
    addresses, rcode = parse_answers(payload)
    return {"addresses": addresses, "rcode": rcode}


def main():
    module = AnsibleModule(
        argument_spec={
            "host": {"type": "str", "required": True},
            "port": {"type": "int", "required": True},
            "names": {"type": "list", "elements": "str", "required": True},
            "timeout_seconds": {"type": "int", "required": True},
        },
        supports_check_mode=True,
    )
    values = module.params
    if not values["names"]:
        module.fail_json(msg="adguard_dns_probe was given no name to ask about")

    answers = {}
    for name in values["names"]:
        try:
            answers[name] = ask(values["host"], values["port"], name, values["timeout_seconds"])
        except (OSError, ValueError, struct.error, UnicodeError) as error:
            # A transport failure is not a reading a caller can assert over: the
            # resolver did not answer at all. It is reported here, by endpoint,
            # rather than returned as an empty answer that an assertion would
            # then have to tell apart from a name that legitimately resolves to
            # nothing.
            module.fail_json(
                msg=(
                    f"no DNS answer for {name} from "
                    f"{values['host']}:{values['port']}/tcp: {type(error).__name__}. "
                    "The published listener is not answering questions, whatever its "
                    "status page reports."
                )
            )
    module.exit_json(changed=False, answers=answers)


if __name__ == "__main__":
    main()
