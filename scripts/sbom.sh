#!/bin/sh
# Emit a CycloneDX 1.5 JSON SBOM for pippin's Swift package dependencies.
#
#   scripts/sbom.sh               SBOM for ./Package.resolved on stdout
#   scripts/sbom.sh <resolved>    SBOM for another Package.resolved
#   scripts/sbom.sh --self-check  verify the generator, print nothing but OK
#
# Reads only Package.resolved and pippin/Version.swift: no network, no
# dependencies beyond python3. Output is deterministic (no timestamp or
# serial number), so two runs on the same lockfile are byte-identical.
# shortcut: lists SwiftPM pins only, not the macOS SDK frameworks pippin links.
set -eu
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import json
import re
import sys


def purl(location, version):
    # pkg:swift/<host>/<namespace>/<name>@<version>, per the purl swift type.
    path = re.sub(r"^[a-z]+://", "", location)
    path = re.sub(r"\.git$", "", path).strip("/")
    return "pkg:swift/%s@%s" % (path, version)


def build(resolved, app_version):
    components = []
    for pin in sorted(resolved["pins"], key=lambda p: p["identity"]):
        state = pin["state"]
        # A branch or revision pin has no version; the commit is the version.
        version = state.get("version") or state["revision"]
        components.append({
            "type": "library",
            "bom-ref": purl(pin["location"], version),
            "name": pin["identity"],
            "version": version,
            "purl": purl(pin["location"], version),
            "externalReferences": [{"type": "vcs", "url": pin["location"]}],
            "properties": [
                {"name": "swiftpm:kind", "value": pin["kind"]},
                {"name": "swiftpm:revision", "value": state["revision"]},
            ],
        })
    root = "pkg:swift/pippin@%s" % app_version
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {"type": "application", "bom-ref": root, "name": "pippin", "version": app_version},
            "properties": [{"name": "swiftpm:originHash", "value": resolved.get("originHash", "")}],
        },
        "components": components,
        "dependencies": [{"ref": root, "dependsOn": [c["bom-ref"] for c in components]}],
    }


def app_version():
    with open("pippin/Version.swift") as handle:
        return re.search(r'static let version = "([^"]+)"', handle.read()).group(1)


def self_check():
    sample = {"originHash": "abc", "pins": [
        {"identity": "zeta", "kind": "remoteSourceControl", "location": "https://example.com/o/Zeta.git",
         "state": {"revision": "f" * 40, "version": "2.0.1"}},
        {"identity": "alpha", "kind": "remoteSourceControl", "location": "https://example.com/o/alpha",
         "state": {"revision": "a" * 40}},
    ]}
    bom = build(sample, "9.9.9")
    assert bom["bomFormat"] == "CycloneDX" and bom["specVersion"] == "1.5"
    assert [c["name"] for c in bom["components"]] == ["alpha", "zeta"], "components must be sorted"
    assert bom["components"][1]["purl"] == "pkg:swift/example.com/o/Zeta@2.0.1"
    assert bom["components"][0]["version"] == "a" * 40, "unversioned pin falls back to its revision"
    assert bom["dependencies"][0]["dependsOn"] == [c["bom-ref"] for c in bom["components"]]
    assert json.dumps(bom, sort_keys=True) == json.dumps(build(sample, "9.9.9"), sort_keys=True)
    # The real lockfile: every pin must appear, with its exact revision.
    with open("Package.resolved") as handle:
        resolved = json.load(handle)
    real = build(resolved, app_version())
    revisions = {p["value"] for c in real["components"] for p in c["properties"]}
    assert len(real["components"]) == len(resolved["pins"]) > 0
    assert all(pin["state"]["revision"] in revisions for pin in resolved["pins"])
    print("sbom self-check OK (%d components)" % len(real["components"]))


if sys.argv[1:] == ["--self-check"]:
    self_check()
else:
    with open(sys.argv[1] if len(sys.argv) > 1 else "Package.resolved") as handle:
        json.dump(build(json.load(handle), app_version()), sys.stdout, indent=2)
    sys.stdout.write("\n")
PY
