#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_jsonl(path):
    with Path(path).open() as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)


def candidate_payload(row):
    v = int(row.get("v", row.get("p")))
    return {
        "v": v,
        "n": int(row.get("n", 4 * v)),
        "ks": [int(k) for k in row["ks"]],
        "lambda": int(row["lambda"]),
        "blocks": [[int(x) for x in block] for block in row["blocks"]],
        "score": int(row["score"]),
        "search_method": row.get("search_method", "rust_search_mvp"),
        "source_engine": "rust_search_mvp",
        "seed": row.get("seed"),
        "step": row.get("step"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--summary", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    total = 0
    for row in load_jsonl(args.candidates):
        total += 1
        if int(row.get("score", -1)) != 0:
            continue
        payload = candidate_payload(row)
        seed = "na" if payload.get("seed") is None else str(payload["seed"])
        step = "na" if payload.get("step") is None else str(payload["step"])
        path = out_dir / "rust_score0_seed{}_step{}.json".format(seed, step)
        path.write_text(json.dumps(payload, indent=2) + "\n")
        paths.append(str(path))

    summary = {
        "source": str(args.candidates),
        "candidate_count": total,
        "score0_count": len(paths),
        "score0_candidate_paths": paths,
    }
    Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
