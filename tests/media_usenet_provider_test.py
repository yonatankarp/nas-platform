#!/usr/bin/env python3
"""Contract tests for the operator-owned Usenet provider shape filter.

Every rule in `filter_plugins/media_usenet_provider.py` moved out of
`vault_credential_schema` when the four non-credential provider values stopped
being vault-authored (#298). The rules did not change in that move and these
tests are what keeps them from drifting afterwards, so most cases here are the
same cases the vault filter's tests made against the six strings.

The one thing that did change is typing, and it is what most of the rejection
cases below are about. The vault could only carry `"563"` and `"1"`; operator
policy carries `563` and `true`, so the tests assert the types are enforced
rather than coerced. Two of them are worth naming:

* **A boolean port is rejected rather than clamped.** `isinstance(True, int)`
  is true in Python, so a filter that only range-checked would read `port:
  true` as the number 1 and accept it as a valid port.
* **A string TLS flag is rejected rather than accepted.** SABnzbd parses a
  server flag with `bool_conv(int_conv())`, so `"true"` is stored as 0. That is
  a silently disabled TLS connection on a server that still looks configured
  for it, which is the single worst outcome available in this file and the
  reason the value is a boolean at all.

The undeclared case is a first-class accepted shape, not an edge case. It is
the state every real target is in until someone buys a subscription (#292), and
#295's `downloaders` integration lane converges it.
"""

from pathlib import Path
import sys
import unittest

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "filter_plugins"))

from media_usenet_provider import (  # noqa: E402
    PROVIDER_CONNECTIONS_RANGE,
    PROVIDER_HOST,
    PROVIDER_KEYS,
    PROVIDER_PORT_RANGE,
    media_usenet_provider_errors,
)

DECLARED = {"host": "news.example.com", "port": 563,
            "connections": 8, "ssl": True}
UNDECLARED = {"host": "", "port": 563, "connections": 8, "ssl": True}


def declared(**overrides):
    """A declared provider with individual values replaced."""
    return {**DECLARED, **overrides}


class AcceptedShapesTest(unittest.TestCase):
    def test_a_declared_provider_is_accepted(self):
        self.assertEqual(media_usenet_provider_errors(DECLARED), [])

    def test_an_undeclared_provider_is_accepted(self):
        self.assertEqual(media_usenet_provider_errors(UNDECLARED), [])

    def test_an_undeclared_provider_ignores_the_other_three(self):
        # An operator who has not bought a subscription has no port, tier or
        # TLS preference to state, so nothing else is consulted. This is what
        # lets inventory carry one shape for both states.
        self.assertEqual(
            media_usenet_provider_errors(
                {"host": "", "port": 0, "connections": 0, "ssl": "no"}),
            [])

    def test_tls_may_be_declined_on_a_declared_provider(self):
        self.assertEqual(media_usenet_provider_errors(declared(ssl=False)), [])

    def test_the_plain_usenet_port_is_accepted(self):
        self.assertEqual(media_usenet_provider_errors(declared(port=119)), [])

    def test_a_single_label_host_is_accepted(self):
        self.assertEqual(media_usenet_provider_errors(declared(host="news")),
                         [])

    def test_both_range_bounds_are_inclusive(self):
        for key, (low, high) in (("port", PROVIDER_PORT_RANGE),
                                 ("connections", PROVIDER_CONNECTIONS_RANGE)):
            for bound in (low, high):
                with self.subTest(key=key, bound=bound):
                    self.assertEqual(
                        media_usenet_provider_errors(declared(**{key: bound})),
                        [])


class HostTest(unittest.TestCase):
    def test_an_uppercase_host_is_refused(self):
        # ConfigServer.set_dict lowercases the host, so a declaration carrying
        # uppercase can never equal what SABnzbd stored and would be pushed on
        # every run forever.
        errors = media_usenet_provider_errors(declared(host="News.Example.Com"))
        self.assertEqual(errors,
                         ["media_usenet_provider.host: must be a bare lowercase"
                          " hostname, because SABnzbd stores nothing else "
                          "unchanged"])

    def test_a_scheme_or_port_in_the_host_is_refused(self):
        for host in ("ssl://news.example.com", "news.example.com:563",
                     "news.example.com/", " news.example.com",
                     "news.example.com ", "news.example.com.",
                     "-news.example.com", "news_example.com"):
            with self.subTest(host=host):
                self.assertEqual(
                    len(media_usenet_provider_errors(declared(host=host))), 1)

    def test_a_non_string_host_is_refused_before_the_pattern(self):
        errors = media_usenet_provider_errors(declared(host=563))
        self.assertEqual(errors,
                         ["media_usenet_provider.host: must be a string"])

    def test_the_host_pattern_is_anchored_at_both_ends(self):
        # `is match` anchors only at the start, so losing the end anchor would
        # accept a valid prefix followed by junk.
        self.assertIsNone(PROVIDER_HOST.match("news.example.com\nrubbish"))


class NumberTest(unittest.TestCase):
    def test_a_port_outside_the_stored_range_is_refused(self):
        for port in (0, -1, 65536):
            with self.subTest(port=port):
                self.assertEqual(
                    media_usenet_provider_errors(declared(port=port)),
                    ["media_usenet_provider.port: must be within the range "
                     "SABnzbd stores without clamping"])

    def test_a_connection_count_outside_the_stored_range_is_refused(self):
        for connections in (0, -1, 501):
            with self.subTest(connections=connections):
                self.assertEqual(
                    media_usenet_provider_errors(
                        declared(connections=connections)),
                    ["media_usenet_provider.connections: must be within the "
                     "range SABnzbd stores without clamping"])

    def test_a_string_number_is_refused_rather_than_coerced(self):
        # The vault carried these as strings and this filter deliberately does
        # not, so accepting "563" here would reintroduce the untyped shape the
        # move exists to replace.
        for key in ("port", "connections"):
            with self.subTest(key=key):
                self.assertEqual(
                    media_usenet_provider_errors(declared(**{key: "8"})),
                    [f"media_usenet_provider.{key}: must be an integer"])

    def test_a_boolean_number_is_refused_rather_than_clamped(self):
        # isinstance(True, int) is true, so a range check alone would read
        # `port: true` as the number 1 and accept it.
        for key in ("port", "connections"):
            for number in (True, False):
                with self.subTest(key=key, number=number):
                    self.assertEqual(
                        media_usenet_provider_errors(
                            declared(**{key: number})),
                        [f"media_usenet_provider.{key}: must be an integer"])

    def test_a_float_port_is_refused(self):
        self.assertEqual(media_usenet_provider_errors(declared(port=563.0)),
                         ["media_usenet_provider.port: must be an integer"])


class TlsFlagTest(unittest.TestCase):
    def test_a_string_flag_is_refused(self):
        # bool_conv(int_conv()) stores "true" as 0. Accepting the string would
        # mean a declaration that reads as TLS-on deploying TLS-off in silence.
        for flag in ("true", "1", "0", "yes"):
            with self.subTest(flag=flag):
                self.assertEqual(
                    media_usenet_provider_errors(declared(ssl=flag)),
                    ["media_usenet_provider.ssl: must be a boolean, because "
                     "SABnzbd parses a server flag with bool_conv(int_conv()) "
                     "and stores any other spelling as 0"])

    def test_an_integer_flag_is_refused(self):
        for flag in (0, 1):
            with self.subTest(flag=flag):
                self.assertEqual(
                    len(media_usenet_provider_errors(declared(ssl=flag))), 1)


class MappingShapeTest(unittest.TestCase):
    def test_a_non_mapping_is_refused(self):
        for value in (None, "", [], "news.example.com", 563):
            with self.subTest(value=value):
                self.assertEqual(media_usenet_provider_errors(value),
                                 ["media_usenet_provider: must be a mapping"])

    def test_a_missing_key_is_named(self):
        for key in PROVIDER_KEYS:
            with self.subTest(key=key):
                partial = {k: v for k, v in DECLARED.items() if k != key}
                self.assertEqual(
                    media_usenet_provider_errors(partial),
                    [f"media_usenet_provider: missing {key}"])

    def test_an_unexpected_key_is_named(self):
        errors = media_usenet_provider_errors({**DECLARED, "username": "who"})
        self.assertEqual(errors,
                         ["media_usenet_provider: unexpected username"])

    def test_a_credential_key_here_is_refused_as_unexpected(self):
        # The whole point of the split is that the account name and password
        # are not operator policy. Writing one here has to fail rather than be
        # quietly ignored, or a reader could believe it took effect.
        errors = media_usenet_provider_errors(
            {**DECLARED, "username": "who", "password": "secret"})
        self.assertEqual(errors,
                         ["media_usenet_provider: unexpected password, "
                          "username"])

    def test_a_shape_violation_suppresses_the_rule_violations(self):
        # Reporting a rule against a mapping of the wrong shape would name a
        # key the operator did not write, or miss one they did.
        errors = media_usenet_provider_errors({"host": "News.Example.Com"})
        self.assertEqual(
            errors, ["media_usenet_provider: missing port, connections, ssl"])

    def test_no_message_carries_a_value_or_a_comparand(self):
        # The same rule vault_credential_schema keeps: a diagnostic names
        # fields and nothing else, so it stays printable from a fail_msg.
        planted = declared(host="SECRETHOST", port=99999, connections=0,
                           ssl="SECRETFLAG")
        joined = " ".join(media_usenet_provider_errors(planted))
        for leaked in ("SECRETHOST", "SECRETFLAG", "99999"):
            with self.subTest(leaked=leaked):
                self.assertNotIn(leaked, joined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
