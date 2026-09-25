#!/usr/bin/env python3
"""Validate the hub-and-spoke address plan.

`az bicep build` cannot catch an address plan mistake: every CIDR is just a string as far
as the compiler is concerned. Azure catches some of these at deploy time and not others,
and the ones it does catch surface as opaque preflight errors well after a reviewer has
already approved the change. This runs on every pull request so an overlap is a review
comment rather than a failed deployment.

Three invariants are checked, all of them stated in the repository instructions or implied
by Azure's own rules:

  1. No two virtual networks overlap. This is the load-bearing one. Azure refuses to create
     a peering between overlapping virtual networks, so an overlap does not corrupt anything
     - it just fails the deployment partway through, after some resources already exist.
  2. Every subnet falls inside its own virtual network's address space.
  3. No two subnets inside the same virtual network overlap.

The input is the JSON produced by `az bicep build-params`, not the `.bicepparam` source.
That matters: the built output is the fully resolved parameter values, so any expression,
variable or import is already evaluated. Parsing the source text would validate something
subtly different from what actually deploys.

Usage:
    az bicep build-params --file infra/main.bicepparam --outfile params.json
    python .github/scripts/check_address_plan.py params.json

Exits non-zero and prints every violation it finds, rather than stopping at the first, so
one run tells you everything that needs fixing.
"""

from __future__ import annotations

import ipaddress
import json
import sys
from typing import Iterator, NamedTuple

IpNetwork = ipaddress.IPv4Network | ipaddress.IPv6Network


class Prefix(NamedTuple):
    """One CIDR with enough provenance to name it in an error message."""

    network: IpNetwork
    # Owning virtual network, e.g. "hub-cus".
    parent: str
    # Human label, e.g. "AzureBastionSubnet" or "vnet address prefix".
    label: str

    def describe(self) -> str:
        where = f"{self.parent} / {self.label}" if self.parent else self.label
        return f"{self.network} ({where})"


def _parse(cidr: str, parent: str, label: str, errors: list[str]) -> Prefix | None:
    """Parse a CIDR, recording a violation rather than raising if it is malformed."""
    try:
        # strict=True rejects host bits set, e.g. 10.0.0.1/24. Azure rejects these too, but
        # only at deploy time, which is exactly the class of late failure this script exists
        # to pull forward.
        return Prefix(ipaddress.ip_network(cidr, strict=True), parent, label)
    except ValueError as exc:
        errors.append(f"{parent or '<root>'} / {label}: {cidr!r} is not a valid CIDR ({exc})")
        return None


def _hub_subnets(hub: dict) -> Iterator[tuple[str, str]]:
    """Yield (label, cidr) for each subnet a hub declares.

    Hubs describe their subnets as named properties rather than a list, because each one has
    different semantics and some carry a fixed Azure name. Spokes use a plain list.
    """
    bastion = hub.get("bastion") or {}
    if bastion.get("subnetAddressPrefix"):
        yield "AzureBastionSubnet", bastion["subnetAddressPrefix"]

    jumpbox = hub.get("jumpboxSubnet") or {}
    if jumpbox.get("addressPrefix"):
        yield "snet-jumpbox", jumpbox["addressPrefix"]

    firewall = hub.get("firewall") or {}
    if firewall.get("subnetAddressPrefix"):
        yield "AzureFirewallSubnet", firewall["subnetAddressPrefix"]
    if firewall.get("managementSubnetAddressPrefix"):
        yield "AzureFirewallManagementSubnet", firewall["managementSubnetAddressPrefix"]


def _spoke_subnets(spoke: dict) -> Iterator[tuple[str, str]]:
    for subnet in spoke.get("subnets") or []:
        if subnet.get("addressPrefix"):
            yield subnet.get("name", "<unnamed>"), subnet["addressPrefix"]


def collect(parameters: dict, errors: list[str]) -> tuple[list[Prefix], dict[str, list[Prefix]]]:
    """Return every virtual network prefix, and the subnets grouped by virtual network."""
    vnets: list[Prefix] = []
    subnets: dict[str, list[Prefix]] = {}

    networks = [
        (hub, _hub_subnets) for hub in (parameters.get("hubs", {}).get("value") or [])
    ] + [
        (spoke, _spoke_subnets) for spoke in (parameters.get("spokes", {}).get("value") or [])
    ]

    for network, subnet_source in networks:
        name = network.get("name", "<unnamed>")
        if name in subnets:
            errors.append(f"duplicate network name {name!r}: names must be unique")
        subnets.setdefault(name, [])

        for cidr in network.get("addressPrefixes") or []:
            prefix = _parse(cidr, name, "vnet address prefix", errors)
            if prefix:
                vnets.append(prefix)

        for label, cidr in subnet_source(network):
            prefix = _parse(cidr, name, label, errors)
            if prefix:
                subnets[name].append(prefix)

    return vnets, subnets


def _overlaps(left: IpNetwork, right: IpNetwork) -> bool:
    """Overlap test that tolerates a mixed IPv4/IPv6 plan.

    ipaddress raises TypeError when comparing across address families. Two networks of
    different families can never overlap, so treat that as False rather than crashing.
    """
    if left.version != right.version:
        return False
    return left.overlaps(right)


def check_vnet_overlaps(vnets: list[Prefix], errors: list[str]) -> None:
    """Invariant 1: no two virtual networks may overlap."""
    for i, left in enumerate(vnets):
        for right in vnets[i + 1:]:
            if _overlaps(left.network, right.network):
                errors.append(
                    f"virtual networks overlap: {left.describe()} and {right.describe()}. "
                    "Azure refuses to peer overlapping virtual networks."
                )


def check_subnets(
    vnets_by_name: dict[str, list[IpNetwork]],
    subnets: dict[str, list[Prefix]],
    errors: list[str],
) -> None:
    """Invariants 2 and 3: subnets sit inside their own vnet and do not overlap each other."""
    for name, entries in subnets.items():
        parents = vnets_by_name.get(name) or []

        for entry in entries:
            candidates = [p for p in parents if p.version == entry.network.version]
            if candidates and not any(entry.network.subnet_of(p) for p in candidates):
                space = ", ".join(str(p) for p in candidates)
                errors.append(
                    f"subnet {entry.describe()} is outside its virtual network's address "
                    f"space ({space})."
                )

        for i, left in enumerate(entries):
            for right in entries[i + 1:]:
                if _overlaps(left.network, right.network):
                    errors.append(
                        f"subnets overlap inside {name}: "
                        f"{left.network} ({left.label}) and {right.network} ({right.label})."
                    )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        print("error: expected exactly one argument, the built parameters JSON", file=sys.stderr)
        return 2

    try:
        with open(argv[1], encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: could not read {argv[1]}: {exc}", file=sys.stderr)
        return 2

    parameters = document.get("parameters") or {}
    errors: list[str] = []

    vnets, subnets = collect(parameters, errors)

    # A check that silently inspects nothing is indistinguishable from a passing one. If the
    # parameter shape ever drifts - `hubs`/`spokes` renamed, `addressPrefixes` restructured -
    # this script would keep reporting success while enforcing nothing at all. Refuse to do
    # that: finding no networks in a network template is itself the bug.
    if not vnets:
        print(
            f"error: found no virtual network prefixes in {argv[1]}. Expected 'hubs' and/or "
            "'spokes' parameters whose entries carry 'addressPrefixes'. The parameter shape "
            "has probably changed and this check needs updating - it is not passing, it is "
            "blind.",
            file=sys.stderr,
        )
        return 2

    check_vnet_overlaps(vnets, errors)

    vnets_by_name: dict[str, list[IpNetwork]] = {}
    for name in subnets:
        vnets_by_name[name] = [v.network for v in vnets if v.parent == name]
    check_subnets(vnets_by_name, subnets, errors)

    if errors:
        print("Address plan validation FAILED:\n", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        print(
            f"\n{len(errors)} problem(s) found. See the address plan comments in "
            "infra/main.bicepparam.",
            file=sys.stderr,
        )
        return 1

    subnet_count = sum(len(v) for v in subnets.values())
    print(
        f"Address plan OK: {len(vnets)} virtual network prefix(es) and "
        f"{subnet_count} subnet(s) checked, no overlaps."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
