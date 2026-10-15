"""Compares StabilityLab's measured body counts with the analyzer's predictions.

    python3 -I Validation/compare.py <lab-result.json> <analyze.json>

lab-result.json is the JSON printed after `STABILITY_LAB_RESULT`; analyze.json is
`swiftui-stability analyze Validation/StabilityLab/StabilityLab --json`. Prints a Markdown table and exits 1 when
a prediction disagrees with the measurement.
"""
import json
import sys

# Cases whose input really changes on every update: they must re-run, whatever the analyzer says.
CONTROLS = {"ChangingInput", "ChangingModifier", "NewObjectInput"}
# The parent itself and views with no inputs aren't predictions.
IGNORED = {"ContentView", "NoInputs"}


def main(result_path, analyze_path):
    result = json.load(open(result_path))
    updates = result["parentUpdates"]
    counts = {name.split("<")[0]: count for name, count in result["counts"].items()}
    reports = {report["name"]: report for report in json.load(open(analyze_path))}

    # Call sites that pass a self-capturing closure, by child name.
    flagged = set()
    for report in reports.values():
        for finding in report["findings"]:
            if finding["rule"] == "closure-captures-self":
                flagged.add(finding["message"].split("`")[1])

    rows, mismatches = [], 0
    for name in sorted(counts):
        if name in IGNORED:
            continue
        count = counts[name]
        # Re-running means once per parent update. A few extra runs (first layout, scene activation) happen to
        # every view, and launch hiccups can add more: anything short of every update is a skip.
        measured = "re-runs" if count >= updates else "skips"
        report = reports.get(name)
        if name in CONTROLS:
            predicted, basis = "re-runs", "control: input changes"
        elif report is None:
            predicted, basis = "?", "not analyzed"
        elif report["skippable"] == "no":
            unstable = [p["name"] for p in report["properties"] if p["compared"] and p["stability"] == "unstable"]
            predicted, basis = "re-runs", f"skippable: no ({', '.join(unstable)})"
        elif name in flagged:
            predicted, basis = "re-runs", "closure-captures-self at the call site"
        else:
            predicted, basis = "skips", f"skippable: {report['skippable']}"
        agree = predicted == measured
        mismatches += not agree
        rows.append(f"| `{name}` | {count} | {measured} | {predicted} | {basis} | {'✅' if agree else '❌'} |")

    print(f"{result['os']}, {updates} parent updates\n")
    print("| Case | Body runs | Measured | Predicted | Basis | |")
    print("|---|---|---|---|---|---|")
    print("\n".join(rows))
    print(f"\n{len(rows) - mismatches}/{len(rows)} agree")
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
