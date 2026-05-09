#!/usr/bin/env python3
import argparse
import json
import os
import sys


def parse_optional_int(value, name):
    if value is None or str(value).strip() == "":
        return None
    try:
        return int(str(value).strip())
    except ValueError:
        raise ValueError("{} must be an integer".format(name))


def build_matrix(shard_index=None, shard_count=None, max_parallel=None):
    if max_parallel is None:
        max_parallel = 40
    if max_parallel < 1 or max_parallel > 256:
        raise ValueError("max_parallel must be between 1 and 256")

    if shard_count is None:
        if shard_index is not None:
            raise ValueError("shard_index requires shard_count")
        indices = [None]
    else:
        if shard_count < 1 or shard_count > 256:
            raise ValueError("shard_count must be between 1 and 256")
        if shard_index is None:
            indices = list(range(shard_count))
        else:
            if shard_index < 0 or shard_index >= shard_count:
                raise ValueError("shard_index must satisfy 0 <= shard_index < shard_count")
            indices = [shard_index]

    width = max(2, len(str(max([idx for idx in indices if idx is not None], default=0))))
    include = []
    for idx in indices:
        if idx is None:
            include.append({"shard_suffix": "single", "shard_index": ""})
        else:
            include.append({"shard_suffix": "s{:0{}d}".format(idx, width), "shard_index": str(idx)})

    return {
        "matrix": {"include": include},
        "max_parallel": min(max_parallel, len(include)),
        "shard_jobs": len(include),
        "fanout": bool(shard_count is not None and shard_index is None and shard_count > 1),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shard-index", default=os.environ.get("SHARD_INDEX", ""))
    parser.add_argument("--shard-count", default=os.environ.get("SHARD_COUNT", ""))
    parser.add_argument("--max-parallel", default=os.environ.get("MAX_PARALLEL", "40"))
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args()

    try:
        payload = build_matrix(
            shard_index=parse_optional_int(args.shard_index, "shard_index"),
            shard_count=parse_optional_int(args.shard_count, "shard_count"),
            max_parallel=parse_optional_int(args.max_parallel, "max_parallel"),
        )
    except ValueError as exc:
        print("::error::{}".format(exc), file=sys.stderr)
        return 2

    lines = [
        "matrix={}".format(json.dumps(payload["matrix"], separators=(",", ":"))),
        "max_parallel={}".format(payload["max_parallel"]),
        "shard_jobs={}".format(payload["shard_jobs"]),
        "fanout={}".format(str(payload["fanout"]).lower()),
    ]
    if args.github_output:
        with open(args.github_output, "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
