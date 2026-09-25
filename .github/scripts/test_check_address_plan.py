#!/usr/bin/env python3
"""Tests for check_address_plan.py.

A validator that cannot fail is worse than no validator, because it buys false confidence.
These tests exist to prove each rule actually rejects the thing it claims to reject.

Standard library only, so it runs anywhere the checker does:

    python .github/scripts/test_check_address_plan.py
"""

from __future__ import annotations

import contextlib
import json
import os
import tempfile
import unittest

import check_address_plan as checker


def _params(hubs: list[dict] | None = None, spokes: list[dict] | None = None) -> dict:
    return {
        "hubs": {"value": hubs or []},
        "spokes": {"value": spokes or []},
    }


def _run(parameters: dict) -> list[str]:
    """Run every check the way main() does and return the collected errors."""
    errors: list[str] = []
    vnets, subnets = checker.collect(parameters, errors)
    checker.check_vnet_overlaps(vnets, errors)
    vnets_by_name = {
        name: [v.network for v in vnets if v.parent == name] for name in subnets
    }
    checker.check_subnets(vnets_by_name, subnets, errors)
    return errors


HUB = {
    "name": "hub-cus",
    "addressPrefixes": ["10.0.0.0/19"],
    "bastion": {"subnetAddressPrefix": "10.0.0.0/26"},
    "jumpboxSubnet": {"addressPrefix": "10.0.0.64/27"},
    "firewall": {
        "subnetAddressPrefix": "10.0.0.192/26",
        "managementSubnetAddressPrefix": "10.0.1.0/26",
    },
}


class TestValidPlan(unittest.TestCase):
    def test_the_real_shape_passes(self):
        errors = _run(
            _params(
                hubs=[HUB],
                spokes=[
                    {
                        "name": "spoke-platform-cus",
                        "addressPrefixes": ["10.1.16.0/20"],
                        "subnets": [
                            {"name": "snet-privateendpoints", "addressPrefix": "10.1.16.0/24"}
                        ],
                    },
                    {
                        "name": "spoke-runners-wu3",
                        "addressPrefixes": ["10.2.0.0/20"],
                        "subnets": [{"name": "snet-runners", "addressPrefix": "10.2.0.0/26"}],
                    },
                ],
            )
        )
        self.assertEqual(errors, [])

    def test_empty_plan_produces_no_errors_at_the_rule_level(self):
        # main() separately refuses an empty plan as "blind" - see TestCli. The rules
        # themselves have nothing to complain about, which is the distinction being kept here.
        self.assertEqual(_run(_params()), [])

    def test_adjacent_ranges_do_not_count_as_overlapping(self):
        # 10.1.0.0/20 ends at 10.1.15.255 and the next starts at 10.1.16.0. Touching is fine;
        # only genuine intersection is an error. This guards against an off-by-one that would
        # reject a perfectly packed plan.
        errors = _run(
            _params(
                spokes=[
                    {"name": "a", "addressPrefixes": ["10.1.0.0/20"]},
                    {"name": "b", "addressPrefixes": ["10.1.16.0/20"]},
                ]
            )
        )
        self.assertEqual(errors, [])


class TestVnetOverlap(unittest.TestCase):
    def test_identical_vnets_are_rejected(self):
        errors = _run(
            _params(
                spokes=[
                    {"name": "a", "addressPrefixes": ["10.1.0.0/20"]},
                    {"name": "b", "addressPrefixes": ["10.1.0.0/20"]},
                ]
            )
        )
        self.assertTrue(any("overlap" in e for e in errors), errors)

    def test_contained_vnet_is_rejected(self):
        # A /24 sitting inside another network's /20 is the realistic mistake: it looks free
        # if you only skim the address plan comments.
        errors = _run(
            _params(
                spokes=[
                    {"name": "a", "addressPrefixes": ["10.1.0.0/20"]},
                    {"name": "b", "addressPrefixes": ["10.1.5.0/24"]},
                ]
            )
        )
        self.assertTrue(any("overlap" in e for e in errors), errors)

    def test_spoke_overlapping_the_hub_is_rejected(self):
        errors = _run(
            _params(
                hubs=[HUB],
                spokes=[{"name": "bad", "addressPrefixes": ["10.0.16.0/20"]}],
            )
        )
        self.assertTrue(any("overlap" in e for e in errors), errors)

    def test_overlap_in_a_second_address_prefix_is_rejected(self):
        # A vnet may declare several prefixes; the check must look at all of them, not just
        # the first.
        errors = _run(
            _params(
                spokes=[
                    {"name": "a", "addressPrefixes": ["10.1.0.0/20", "10.9.0.0/20"]},
                    {"name": "b", "addressPrefixes": ["10.9.8.0/24"]},
                ]
            )
        )
        self.assertTrue(any("overlap" in e for e in errors), errors)


class TestSubnetContainment(unittest.TestCase):
    def test_subnet_outside_its_vnet_is_rejected(self):
        errors = _run(
            _params(
                spokes=[
                    {
                        "name": "a",
                        "addressPrefixes": ["10.1.0.0/20"],
                        "subnets": [{"name": "stray", "addressPrefix": "10.7.0.0/24"}],
                    }
                ]
            )
        )
        self.assertTrue(any("outside" in e for e in errors), errors)

    def test_hub_subnet_outside_the_hub_is_rejected(self):
        bad_hub = dict(HUB, jumpboxSubnet={"addressPrefix": "10.8.0.0/27"})
        errors = _run(_params(hubs=[bad_hub]))
        self.assertTrue(any("outside" in e for e in errors), errors)


class TestSubnetOverlap(unittest.TestCase):
    def test_overlapping_subnets_in_one_vnet_are_rejected(self):
        errors = _run(
            _params(
                spokes=[
                    {
                        "name": "a",
                        "addressPrefixes": ["10.1.0.0/20"],
                        "subnets": [
                            {"name": "one", "addressPrefix": "10.1.0.0/24"},
                            {"name": "two", "addressPrefix": "10.1.0.128/25"},
                        ],
                    }
                ]
            )
        )
        self.assertTrue(any("overlap" in e for e in errors), errors)

    def test_hub_firewall_and_bastion_collision_is_rejected(self):
        bad_hub = dict(HUB, firewall={"subnetAddressPrefix": "10.0.0.0/26"})
        errors = _run(_params(hubs=[bad_hub]))
        self.assertTrue(any("overlap" in e for e in errors), errors)

    def test_same_prefix_in_two_different_vnets_is_fine(self):
        # Subnet overlap is only meaningful inside one vnet. Two separate vnets are allowed
        # to use the same subnet prefix as long as the vnets themselves do not overlap...
        # which, for distinct vnets, they cannot. This guards against comparing subnets
        # globally by mistake.
        errors = _run(
            _params(
                spokes=[
                    {
                        "name": "a",
                        "addressPrefixes": ["10.1.0.0/20"],
                        "subnets": [{"name": "s", "addressPrefix": "10.1.0.0/24"}],
                    },
                    {
                        "name": "b",
                        "addressPrefixes": ["10.2.0.0/20"],
                        "subnets": [{"name": "s", "addressPrefix": "10.2.0.0/24"}],
                    },
                ]
            )
        )
        self.assertEqual(errors, [])


class TestMalformedInput(unittest.TestCase):
    def test_nonsense_cidr_is_rejected(self):
        errors = _run(_params(spokes=[{"name": "a", "addressPrefixes": ["not-a-cidr"]}]))
        self.assertTrue(any("not a valid CIDR" in e for e in errors), errors)

    def test_host_bits_set_is_rejected(self):
        # Azure rejects 10.1.0.1/24 as well, but only at deploy time. Catching it here is the
        # whole point.
        errors = _run(_params(spokes=[{"name": "a", "addressPrefixes": ["10.1.0.1/24"]}]))
        self.assertTrue(any("not a valid CIDR" in e for e in errors), errors)

    def test_duplicate_network_names_are_rejected(self):
        errors = _run(
            _params(
                spokes=[
                    {"name": "same", "addressPrefixes": ["10.1.0.0/20"]},
                    {"name": "same", "addressPrefixes": ["10.2.0.0/20"]},
                ]
            )
        )
        self.assertTrue(any("duplicate network name" in e for e in errors), errors)

    def test_missing_optional_sections_do_not_crash(self):
        errors = _run(_params(hubs=[{"name": "bare", "addressPrefixes": ["10.5.0.0/20"]}]))
        self.assertEqual(errors, [])

    def test_all_violations_are_reported_not_just_the_first(self):
        errors = _run(
            _params(
                spokes=[
                    {"name": "a", "addressPrefixes": ["10.1.0.0/20"]},
                    {"name": "b", "addressPrefixes": ["10.1.0.0/20"]},
                    {
                        "name": "c",
                        "addressPrefixes": ["10.3.0.0/20"],
                        "subnets": [{"name": "stray", "addressPrefix": "10.9.0.0/24"}],
                    },
                ]
            )
        )
        self.assertGreaterEqual(len(errors), 2, errors)


class TestCli(unittest.TestCase):
    """Exercise main() end to end, including its exit codes.

    The rule-level tests above would all still pass if main() were wired up wrongly, so the
    process contract gets its own coverage: 0 clean, 1 violations, 2 unusable input.
    """

    def _write(self, document: dict) -> str:
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        )
        self.addCleanup(os.unlink, handle.name)
        with handle:
            json.dump(document, handle)
        return handle.name

    def _run_cli(self, document: dict) -> int:
        """Invoke main() on a temp file, muting its reporting so test output stays readable."""
        path = self._write(document)
        with open(os.devnull, "w", encoding="utf-8") as devnull:
            with contextlib.redirect_stdout(devnull), contextlib.redirect_stderr(devnull):
                return checker.main(["prog", path])

    def test_clean_plan_exits_zero(self):
        self.assertEqual(self._run_cli({"parameters": _params(hubs=[HUB])}), 0)

    def test_violating_plan_exits_one(self):
        self.assertEqual(
            self._run_cli(
                {
                    "parameters": _params(
                        hubs=[HUB],
                        spokes=[{"name": "bad", "addressPrefixes": ["10.0.16.0/20"]}],
                    )
                }
            ),
            1,
        )

    def test_a_plan_with_no_networks_is_an_error_not_a_pass(self):
        # The failure mode this guards against: the parameter shape drifts, the script finds
        # nothing, and CI goes green forever while enforcing nothing.
        self.assertEqual(self._run_cli({"parameters": {}}), 2)

    def test_renamed_parameters_are_an_error_not_a_pass(self):
        self.assertEqual(
            self._run_cli({"parameters": {"virtualNetworks": {"value": [HUB]}}}), 2
        )

    def test_missing_file_exits_two(self):
        with open(os.devnull, "w", encoding="utf-8") as devnull:
            with contextlib.redirect_stderr(devnull):
                self.assertEqual(checker.main(["prog", "no-such-file.json"]), 2)

    def test_wrong_argument_count_exits_two(self):
        with open(os.devnull, "w", encoding="utf-8") as devnull:
            with contextlib.redirect_stderr(devnull):
                self.assertEqual(checker.main(["prog"]), 2)
                self.assertEqual(checker.main(["prog", "a", "b"]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
