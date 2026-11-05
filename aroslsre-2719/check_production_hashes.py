#!/usr/bin/env python3
"""Check the appended-input hypothesis against reported production FNV states.

This restores an observed numeric FNV-1a state. It does not hash the hexadecimal
characters, recover a historical configuration, or identify an annotation writer.
"""

import json


def continue_fnv(previous, suffix):
    state = int(previous, 16)
    for byte in suffix.encode("utf-8"):
        state = ((state ^ byte) * 16777619) & 0xFFFFFFFF
    return f"{state:08x}"


def main():
    rows = []
    for region, baseline, target in [
        ("UK", "2862414f", "a9ac72f5"),
        ("AU", "321ab288", "f907c476"),
    ]:
        actual = continue_fnv(baseline, "private=true")
        assert actual == target, (region, actual, target)
        negative_controls = {
            suffix: continue_fnv(baseline, suffix)
            for suffix in ["private=false", "private=true,port=6443"]
        }
        assert target not in negative_controls.values()
        rows.append(
            {
                "region": region,
                "observed_baseline": baseline,
                "appended_bytes": "private=true",
                "calculated_target": actual,
                "reported_target": target,
                "match": actual == target,
                "negative_controls": negative_controls,
            }
        )
    print(json.dumps(rows, indent=2))


if __name__ == "__main__":
    main()
