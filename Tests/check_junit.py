#!/usr/bin/env python3
"""Sequential release integration checks; all generated files stay in examples/tmp."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(bundle, command, *extra):
    return json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", command,
        "--path", str(bundle), *extra,
    ]))


def walk(node):
    yield node
    for child in node.get("children", []):
        yield from walk(child)


def test_nodes(node, suite="Default"):
    if node.get("nodeType") == "Test Suite":
        suite = node.get("name", suite)
    if node.get("nodeType") == "Test Case":
        yield suite, node
    for child in node.get("children", []):
        yield from test_nodes(child, suite)


def snapshot(directory):
    result = {}
    for path in directory.rglob("*"):
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            result[path.relative_to(directory)] = digest.hexdigest()
    return result


def typography(text):
    return text.replace("->", "→").replace('"', "“").replace("'", "‘").strip()


def export(binary, bundle, output, report=None, force=True):
    command = [str(binary), "export", str(bundle), "-o", str(output), "--raw-attachments"]
    if force:
        command.append("--force")
    if report is not None:
        command += ["--junit", str(report)]
    subprocess.run(command, check=True)


def verify_report(report, bundle):
    subprocess.run(["xmllint", "--noout", str(report)], check=True)
    root = ET.fromstring(report.read_bytes())
    assert root.tag == "testsuites"
    assert len(root) == 1 and root[0].tag == "testsuite", "Expected one flat suite"
    cases = root[0].findall("testcase")
    assert len(root[0]) == len(cases), "Unexpected nested elements"
    summary = read(bundle, "summary")
    nodes = [test for node in read(bundle, "tests")["testNodes"] for test in test_nodes(node)]
    assert len(cases) == len(nodes) == summary["totalTestCount"]
    assert len({(case.attrib["classname"], case.attrib["name"]) for case in cases}) == len(cases)
    failures = sum(case.find("failure") is not None for case in cases)
    skipped = sum(case.find("skipped") is not None for case in cases)
    assert failures == summary["failedTests"]
    assert skipped == summary["skippedTests"]
    total_time = sum(Decimal(case.attrib["time"]) for case in cases)
    for element in (root, root[0]):
        assert int(element.attrib["tests"]) == len(cases)
        assert int(element.attrib["failures"]) == failures
        assert int(element.attrib["skipped"]) == skipped
        assert element.attrib["errors"] == "0"
        assert Decimal(element.attrib["time"]) == total_time
    for case, (suite, node) in zip(cases, nodes):
        assert (case.attrib["classname"], case.attrib["name"]) == (suite, node["name"])
        identifier = node.get("nodeIdentifierURL")
        details = read(bundle, "test-details", "--test-id", identifier) if identifier else {}
        assert abs(Decimal(case.attrib["time"]) - Decimal(str(details.get("durationInSeconds", 0)))) <= Decimal(".001")
        status = node["result"]
        assert status in {"Passed", "Expected Failure", "Failed", "Skipped"}
        failure = case.find("failure")
        assert (failure is not None) == (status == "Failed")
        assert (case.find("skipped") is not None) == (status == "Skipped")
        assert len(case) == (1 if status in {"Failed", "Skipped"} else 0)
        if failure is not None:
            assert failure.attrib["message"].strip() and failure.text.strip()
            # Compare real input messages, including non-XCTest failures and repeated runs.
            messages = [n["name"] for n in walk(node) if n.get("nodeType") == "Failure Message"]
            messages += [n["name"] for run in details.get("testRuns", []) for n in walk(run)
                         if n.get("nodeType") == "Test Case Run" and n.get("result") == "Failed"]
            for message in messages:
                assert typography(message) in failure.text, f"Lost failure message: {message}"


def verify_failures_preserve_output(binary, bundle, output, work):
    blocked_parent = work / "not-a-directory"
    blocked_parent.write_text("keep")
    (output / "keep-on-failure").write_text("must survive a failed --force export")
    old_artifact = output / "00000000-0000-4000-8000-000000000000-attachment.xml"
    old_artifact.write_text("attachment from an earlier bundle")
    existing = snapshot(output)
    artifact = next(output.glob("*-result.json"))
    for destination in (output, bundle / "database.sqlite3", artifact, old_artifact, blocked_parent / "report.xml"):
        result = subprocess.run(
            [str(binary), "export", str(bundle), "-o", str(output), "--raw-attachments",
             "--force", "--junit", str(destination)], capture_output=True, text=True
        )
        assert result.returncode != 0 and "--junit" in result.stderr, result.stderr
        assert snapshot(output) == existing, f"Output changed after failure for {destination}"
    # A genuine write error must also happen before publishing the staged Allure results.
    readonly = work / "readonly"
    readonly.mkdir()
    readonly.chmod(0o555)
    try:
        result = subprocess.run(
            [str(binary), "export", str(bundle), "-o", str(output), "--raw-attachments",
             "--force", "--junit", str(readonly / "report.xml")], capture_output=True, text=True
        )
        assert result.returncode != 0, "Expected report write to fail in a read-only directory"
        assert snapshot(output) == existing, "Allure was replaced before the report could be written"
    finally:
        readonly.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "output/xcualr")
    parser.add_argument("--reference", type=Path, help="Optional previous release for exact Allure parity")
    parser.add_argument("bundles", type=Path, nargs="*")
    args = parser.parse_args()
    binary = args.binary.resolve()
    reference = args.reference.resolve() if args.reference else None
    bundles = [path.resolve() for path in args.bundles] or [
        ROOT / "examples" / f"TestResults_{index}.xcresult" for index in range(3)
    ]
    for path in [binary, *([reference] if reference else []), *bundles]:
        if not path.exists():
            parser.error(f"Missing required binary or fixture: {path}")

    work_root = ROOT / "examples/tmp/junit-check"
    work_root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=work_root))
    print(f"Artifacts: {work}", flush=True)
    if not args.bundles:
        merged = work / "merged.xcresult"
        subprocess.run(["xcrun", "xcresulttool", "merge", *map(str, bundles[:2]),
                        "--output-path", str(merged)], check=True)
        bundles.append(merged)

    for index, bundle in enumerate(bundles):
        report = work / f"{index}.xml"
        output = work / f"{index}-allure"
        export(binary, bundle, output, report)
        verify_report(report, bundle)
        first = report.read_bytes()
        expected_allure = snapshot(output)

        # A report inside the replaced directory must survive --force.
        internal_report = output / "reports/.junit.xml"
        marker = output / "old-marker"
        marker.write_text("must be removed by --force")
        export(binary, bundle, output, internal_report)
        assert not marker.exists()
        assert internal_report.read_bytes() == first, "JUnit is not deterministic"

        # Append preserves both old artifacts and siblings of a nested/hidden report.
        sibling = internal_report.parent / "keep.txt"
        sibling.write_text("keep")
        before_append = snapshot(output)
        export(binary, bundle, output, internal_report, force=False)
        assert snapshot(output) == before_append, "Append lost an existing artifact or the JUnit report"

        export(binary, bundle, output)
        assert snapshot(output) == expected_allure, "Allure changed with --junit"
        if reference:
            baseline = work / f"{index}-reference"
            export(reference, bundle, baseline)
            assert snapshot(baseline) == expected_allure, "Allure differs from the reference release"
        if index == 0:
            verify_failures_preserve_output(binary, bundle, output, work)
        print(f"{bundle.name}: XML, counts, text, timing, repeat/append and Allure parity passed", flush=True)

    for missing in ([], ["--force"], [""]):
        result = subprocess.run([str(binary), "export", str(bundles[0]), "-o", str(work),
                                 "--junit", *missing], capture_output=True, text=True)
        assert result.returncode != 0 and "Missing value for --junit" in result.stderr
    print("JUnit integration checks passed", flush=True)


if __name__ == "__main__":
    main()
