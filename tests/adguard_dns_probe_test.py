#!/usr/bin/env python3
"""Direct and socket tests for the resolver probe roles/adguard verifies with.

library/adguard_dns_probe.py is what makes a dead upstream fail verification:
every other reading in roles/adguard/tasks/verify.yml is AdGuard's control API
answering for itself, and that API reports a healthy instance while the resolver
answers nothing (measured on v0.107.79 with the bootstrap resolver blackholed).
The module is exercised for real by the adguard integration lane, which converges
a sandbox AdGuard and then runs verify.yml against it -- but only on the happy
path, against one daemon's answers. What is tested here is the wire format,
because that is where a parser is wrong: compression pointers, response codes,
records that are not A records, and answers that stop early.

`--self-test` plants a defect in a copy of the module and requires this file to
catch it, so a clean report means the tests bite rather than that they ran.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = pathlib.Path(
    os.environ.get("ADGUARD_DNS_PROBE_MODULE", ROOT / "library" / "adguard_dns_probe.py")
)
failures: list[str] = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_module():
    spec = importlib.util.spec_from_file_location("adguard_dns_probe", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("adguard_dns_probe module cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


module = load_module()


def answer(name, records, rcode=0, compress=True):
    """One response, built the way a real resolver builds one.

    The answer names are compression pointers back to the question by default,
    which is what AdGuard actually sends -- a parser that walks them as literal
    labels reads the record type out of the middle of a name and returns
    nothing, which would read here as "the resolver answered with no addresses".
    """
    header = struct.pack("!6H", 0x1234, 0x8180 | rcode, 1, len(records), 0, 0)
    question = (
        b"".join(struct.pack("!B", len(part)) + part for part in name.encode().split(b"."))
        + b"\0"
        + struct.pack("!2H", 1, 1)
    )
    body = b""
    for record_type, rdata in records:
        if compress:
            body += struct.pack("!H", 0xC00C)
        else:
            body += question[: -4]
        body += struct.pack("!2HIH", record_type, 1, 300, len(rdata)) + rdata
    return header + question + body


def address(dotted):
    return bytes(int(octet) for octet in dotted.split("."))


# --- the pure wire format ---------------------------------------------------

addresses, rcode = module.parse_answers(answer("example.com", [(1, address("93.184.216.34"))]))
check(addresses == ["93.184.216.34"], f"a single A record must parse, got {addresses!r}")
check(rcode == 0, f"NOERROR must read as 0, got {rcode}")

addresses, _ = module.parse_answers(
    answer("example.com", [(1, address("1.2.3.4")), (1, address("5.6.7.8"))])
)
check(addresses == ["1.2.3.4", "5.6.7.8"], f"every A record must parse, got {addresses!r}")

addresses, _ = module.parse_answers(
    answer("example.com", [(1, address("1.2.3.4"))], compress=False)
)
check(addresses == ["1.2.3.4"], f"an uncompressed answer name must parse, got {addresses!r}")

# A CNAME ahead of the A record, which is what most real names return. The
# record after a variable-length rdata is only found if rdlength is honoured.
cname = b"\x03www\x07example\x03com\x00"
addresses, _ = module.parse_answers(
    answer("example.com", [(5, cname), (1, address("9.9.9.9"))])
)
check(addresses == ["9.9.9.9"], f"an A record behind a CNAME must parse, got {addresses!r}")

addresses, rcode = module.parse_answers(answer("example.com", [], rcode=2))
check(addresses == [] and rcode == 2,
      f"SERVFAIL must read as no addresses and rcode 2, got {addresses!r} {rcode}")

# The blocked shape: AdGuard's default blocking mode answers NOERROR/0.0.0.0.
addresses, rcode = module.parse_answers(answer("doubleclick.net", [(1, address("0.0.0.0"))]))
check(addresses == ["0.0.0.0"] and rcode == 0,
      f"a blocked answer must read as 0.0.0.0 NOERROR, got {addresses!r} {rcode}")

# An AAAA-only answer has no A record in it and must not be mistaken for one.
addresses, _ = module.parse_answers(answer("example.com", [(28, b"\x20\x01" + b"\0" * 14)]))
check(addresses == [], f"an AAAA record must not read as an address, got {addresses!r}")

# The type check has to do the work rather than the length check: `\x02ab\x00` is
# a legal name and exactly four bytes, so a CNAME to `ab` is a non-A record that
# a parser keying only on rdlength reads as the address 2.97.98.0.
addresses, _ = module.parse_answers(answer("example.com", [(5, b"\x02ab\x00")]))
check(addresses == [], f"a four-byte CNAME must not read as an address, got {addresses!r}")

# An answer that is not a DNS answer at all is refused BY NAME. The distinction
# is a diagnostic rather than a behaviour -- the module treats every parse
# failure alike -- and it is the difference between a reader being told the
# resolver sent something that is not a DNS message and being handed a struct
# error about two bytes.
try:
    module.parse_answers(b"")
    failures.append("an empty answer must be refused")
except ValueError as error:
    check("shorter than a DNS header" in str(error),
          f"an empty answer must be refused by name, got {error!r}")
except struct.error as error:
    failures.append(f"an empty answer must be refused by name, not by struct: {error!r}")

for truncated in (b"\0" * 11, answer("example.com", [(1, address("1.2.3.4"))])[:20]):
    try:
        module.parse_answers(truncated)
        failures.append(f"a truncated answer of {len(truncated)} bytes must be refused")
    except (ValueError, struct.error):
        pass

query = module.build_query("example.com")
check(query[4:6] == b"\x00\x01", "a query must ask exactly one question")
check(query.endswith(b"\x07example\x03com\x00\x00\x01\x00\x01"),
      "a query must ask for an A record in the IN class")
check(query[2:4] == b"\x01\x00", "a query must ask for recursion")


# --- the socket path --------------------------------------------------------

class StubResolver(threading.Thread):
    """Answers one TCP query per connection, or hangs up, or says nothing."""

    def __init__(self, behaviour):
        super().__init__(daemon=True)
        self.behaviour = behaviour
        self.socket = socket.socket()
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(4)
        self.port = self.socket.getsockname()[1]
        self.start()

    def run(self):
        while True:
            try:
                connection, _ = self.socket.accept()
            except OSError:
                return
            with connection:
                try:
                    length = struct.unpack("!H", connection.recv(2))[0]
                    connection.recv(length)
                    payload = self.behaviour()
                    if payload is None:
                        continue
                    connection.sendall(struct.pack("!H", len(payload)) + payload)
                except OSError:
                    continue

    def close(self):
        self.socket.close()


serving = StubResolver(lambda: answer("example.com", [(1, address("93.184.216.34"))]))
result = module.ask("127.0.0.1", serving.port, "example.com", 5)
check(result == {"addresses": ["93.184.216.34"], "rcode": 0},
      f"a served answer must come back through the socket, got {result!r}")
serving.close()

hanging_up = StubResolver(lambda: None)
try:
    module.ask("127.0.0.1", hanging_up.port, "example.com", 5)
    failures.append("a resolver that hangs up mid-answer must be refused")
except (ValueError, OSError):
    pass
hanging_up.close()

closed = socket.socket()
closed.bind(("127.0.0.1", 0))
refused_port = closed.getsockname()[1]
closed.close()
try:
    module.ask("127.0.0.1", refused_port, "example.com", 5)
    failures.append("a port nothing listens on must be refused")
except OSError:
    pass


# --- self-test --------------------------------------------------------------

MUTATIONS = {
    "a parser that walks compression pointers as labels":
        ("        if length & 0xC0 == 0xC0:\n            return offset + 2\n", ""),
    "a parser that ignores the response code":
        ("return addresses, flags & 0x000F", "return addresses, 0"),
    "a parser that takes every record for an A record":
        ("if record_type == 1 and rdlength == 4:", "if rdlength == 4:"),
    "a parser that trusts a short answer":
        ('    if len(payload) < 12:\n        raise ValueError("answer is shorter than a DNS header")\n', ""),
    "a query that asks no question":
        ('struct.pack("!6H", random.randint(0, 0xFFFF), 0x0100, 1, 0, 0, 0)',
         'struct.pack("!6H", random.randint(0, 0xFFFF), 0x0100, 0, 0, 0, 0)'),
    "a read that accepts a short answer body":
        ('        if not chunk:\n            raise ValueError("the resolver closed the connection mid-answer")\n',
         "        if not chunk:\n            return buffer\n"),
}

if "--self-test" in sys.argv[1:]:
    source = MODULE_PATH.read_text()
    undetected = []
    with tempfile.TemporaryDirectory(prefix="nas-platform-adguard-dns-probe-") as directory:
        for label, (original, replacement) in MUTATIONS.items():
            if source.count(original) != 1:
                undetected.append(f"{label}: its anchor is not in the module exactly once")
                continue
            mutant = pathlib.Path(directory) / "adguard_dns_probe.py"
            mutant.write_text(source.replace(original, replacement))
            environment = dict(os.environ, ADGUARD_DNS_PROBE_MODULE=str(mutant))
            completed = subprocess.run(
                [sys.executable, str(pathlib.Path(__file__).resolve())],
                env=environment, capture_output=True, text=True, check=False
            )
            if completed.returncode == 0:
                undetected.append(label)
    if undetected:
        for label in undetected:
            print(f"adguard dns probe self-test did not detect: {label}", file=sys.stderr)
        sys.exit(1)
    print(f"adguard dns probe: self-test detects {len(MUTATIONS)} planted regressions")
    sys.exit(0)

if failures:
    for failure in failures:
        print(f"adguard dns probe: {failure}", file=sys.stderr)
    sys.exit(1)
print("adguard dns probe: the wire format and the socket path hold")
