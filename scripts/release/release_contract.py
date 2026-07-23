#!/usr/bin/env python3
"""Shared, deterministic Dockmint release metadata."""

from __future__ import annotations

import dataclasses
import re


MINIMUM_SYSTEM_VERSION = "14.0"
REPOSITORY = "apotenza92/dockmint"
SPARKLE_PUBLIC_ED_KEY = "zM3fwyZrb6uCBvOIv8Smh91DRMyrKVQPbWBGpkCcgDI="

STABLE_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
BETA_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-beta\.([1-9]\d*)$")


@dataclasses.dataclass(frozen=True)
class ParsedTag:
    major: int
    minor: int
    patch: int
    beta_number: int | None

    @property
    def prerelease(self) -> str | None:
        return None if self.beta_number is None else f"beta.{self.beta_number}"

    @property
    def tag(self) -> str:
        return f"v{self.version}"

    @property
    def core_version(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @property
    def version(self) -> str:
        suffix = "" if self.beta_number is None else f"-beta.{self.beta_number}"
        return f"{self.core_version}{suffix}"

    @property
    def is_prerelease(self) -> bool:
        return self.beta_number is not None

    @property
    def build_number(self) -> str:
        core = (self.major * 1_000_000) + (self.minor * 1_000) + self.patch
        stage = 90_000 if self.beta_number is None else min(max(self.beta_number, 1), 89_999)
        return str((core * 100_000) + stage)


@dataclasses.dataclass(frozen=True)
class PackageContract:
    channel: str
    arch: str
    xcode_arch: str
    product_name: str
    app_name: str
    bundle_id: str
    icon_name: str
    package_prefix: str

    def artifact_name(self, version: str) -> str:
        return f"{self.package_prefix}-v{version}-macos-{self.arch}.zip"

    @property
    def feed_name(self) -> str:
        return f"{self.channel}-{self.arch}.xml"

    @property
    def feed_url(self) -> str:
        return f"https://raw.githubusercontent.com/{REPOSITORY}/main/appcasts/{self.feed_name}"


def parse_tag(tag: str) -> ParsedTag | None:
    stable = STABLE_TAG_RE.fullmatch(tag)
    if stable:
        return ParsedTag(*(int(value) for value in stable.groups()), beta_number=None)

    beta = BETA_TAG_RE.fullmatch(tag)
    if beta:
        major, minor, patch, beta_number = (int(value) for value in beta.groups())
        return ParsedTag(major, minor, patch, beta_number)
    return None


def require_tag(tag: str) -> ParsedTag:
    parsed = parse_tag(tag)
    if parsed is None:
        raise ValueError(f"tag must match vX.Y.Z or vX.Y.Z-beta.N with N >= 1: {tag}")
    return parsed


def version_key(parsed: ParsedTag) -> tuple[int, int, int, int, int]:
    stable_rank = 1 if parsed.beta_number is None else 0
    beta_number = 0 if parsed.beta_number is None else parsed.beta_number
    return (parsed.major, parsed.minor, parsed.patch, stable_rank, beta_number)


def package_contract(channel: str, arch: str) -> PackageContract:
    if channel not in {"stable", "beta"}:
        raise ValueError(f"unsupported release channel: {channel}")
    if arch not in {"arm64", "x64"}:
        raise ValueError(f"unsupported release architecture: {arch}")

    beta = channel == "beta"
    return PackageContract(
        channel=channel,
        arch=arch,
        xcode_arch="arm64" if arch == "arm64" else "x86_64",
        product_name="Dockmint Beta" if beta else "Dockmint",
        app_name="Dockmint Beta.app" if beta else "Dockmint.app",
        bundle_id="pzc.Dockmint.beta" if beta else "pzc.Dockmint",
        icon_name="AppIconBeta" if beta else "AppIcon",
        package_prefix="Dockmint-Beta" if beta else "Dockmint",
    )


def stable_asset_names(version: str, arch: str) -> tuple[str, ...]:
    return (package_contract("stable", arch).artifact_name(version),)


def beta_asset_names(version: str, arch: str) -> tuple[str, ...]:
    return (package_contract("beta", arch).artifact_name(version),)
