from sage.all import *

import argparse
import cmath
import json
import math
import os

from sds_repair_utils import (
    load_candidate,
    metrics_from_counts,
    setup_logging,
    total_diff_counts,
    write_json,
)


SCRIPT_NAME = "28_fourier_defect_analysis"


def defect_vector(v, counts, lam):
    values = [0] * v
    for d in range(1, v):
        values[d] = int(counts[d] - lam)
    return values


def real_part(z):
    attr = z.real
    return float(attr() if callable(attr) else attr)


def imag_part(z):
    attr = z.imag
    return float(attr() if callable(attr) else attr)


def dft_coeff(values, mode):
    v = len(values)
    total = complex(0.0, 0.0)
    for d, value in enumerate(values):
        if value:
            angle = -2.0 * math.pi * float(mode * d) / float(v)
            total += float(value) * complex(math.cos(angle), math.sin(angle))
    return total


def fourier_spectrum(values):
    rows = []
    for mode in range(1, len(values)):
        coeff = dft_coeff(values, mode)
        real = real_part(coeff)
        imag = imag_part(coeff)
        energy = real * real + imag * imag
        rows.append(
            {
                "mode": int(mode),
                "real": float(real),
                "imag": float(imag),
                "energy": float(energy),
                "magnitude": float(math.sqrt(max(0.0, energy))),
            }
        )
    rows.sort(key=lambda row: (-row["energy"], row["mode"]))
    return rows


def support_summary(values):
    positive = []
    negative = []
    for d in range(1, len(values)):
        value = int(values[d])
        if value > 0:
            positive.append(d)
        elif value < 0:
            negative.append(d)
    return {
        "positive_count": int(len(positive)),
        "negative_count": int(len(negative)),
        "zero_count": int((len(values) - 1) - len(positive) - len(negative)),
        "positive_shifts": positive,
        "negative_shifts": negative,
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="Analyze an SDS near-hit defect vector in the Fourier domain."
    )
    parser.add_argument("json_path")
    parser.add_argument("--top-modes", type=int, default=24)
    parser.add_argument("--out", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    tee, stamp = setup_logging(SCRIPT_NAME)
    try:
        data, v, n, ks, lam, blocks = load_candidate(args.json_path)
        counts = total_diff_counts(v, blocks)
        metrics = metrics_from_counts(counts, lam)
        defects = defect_vector(v, counts, lam)
        spectrum = fourier_spectrum(defects)
        score = int(metrics[0])
        total_frequency_energy = float(sum(row["energy"] for row in spectrum))
        parseval_score = total_frequency_energy / float(v)
        top = spectrum[: int(args.top_modes)]
        top_energy = float(sum(row["energy"] for row in top))
        payload = {
            "script": SCRIPT_NAME,
            "input": args.json_path,
            "v": int(v),
            "n": int(n),
            "ks": [int(k) for k in ks],
            "lambda": int(lam),
            "stored_metrics": {
                "score": data.get("score"),
                "l1_error": data.get("l1_error"),
                "max_abs_error": data.get("max_abs_error"),
                "nonzero_defect_count": data.get("nonzero_defect_count"),
            },
            "computed_metrics": {
                "score": int(metrics[0]),
                "l1_error": int(metrics[1]),
                "max_abs_error": int(metrics[2]),
                "nonzero_defect_count": int(metrics[3]),
            },
            "defect_vector": [int(x) for x in defects],
            "support_summary": support_summary(defects),
            "parseval": {
                "score": score,
                "frequency_energy_sum": total_frequency_energy,
                "frequency_energy_sum_div_v": parseval_score,
                "absolute_error": float(abs(parseval_score - float(score))),
            },
            "top_modes": top,
            "top_modes_energy": top_energy,
            "top_modes_energy_fraction": float(top_energy / total_frequency_energy)
            if total_frequency_energy
            else 0.0,
            "spectrum": spectrum,
            "notes": [
                "Fourier quantities are floating-point diagnostics only.",
                "Hadamard/SDS success is still determined by exact integer checks.",
            ],
        }
        out = args.out or os.path.join(
            "outputs/fourier",
            "fourier_defect_{}_score{}.json".format(stamp, metrics[0]),
        )
        write_json(out, payload)
        print("Input:", args.json_path)
        print("computed_metrics:", payload["computed_metrics"])
        print(
            "parseval score={} frequency_energy/v={:.8f} error={:.3e}".format(
                score, parseval_score, abs(parseval_score - float(score))
            )
        )
        print(
            "top_{}_energy_fraction={:.4f}".format(
                int(args.top_modes), payload["top_modes_energy_fraction"]
            )
        )
        print("Top modes:")
        for row in top[: min(12, len(top))]:
            print(
                "  mode={mode} energy={energy:.3f} magnitude={magnitude:.3f}".format(
                    **row
                )
            )
        print("WROTE:", out)
    finally:
        tee.close()


if __name__ == "__main__":
    main()
