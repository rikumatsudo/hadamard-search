from sage.all import *

import hashlib
import json
import os
import sys
import time

from sage.rings.integer import Integer as SageInteger


class Tee(object):
    def __init__(self, path):
        self.terminal = sys.stdout
        self.log = open(path, "w")

    def write(self, data):
        self.terminal.write(data)
        self.log.write(data)

    def flush(self):
        self.terminal.flush()
        if not self.log.closed:
            self.log.flush()

    def close(self):
        if not self.log.closed:
            self.log.close()


def timestamp():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def stamp_for_path():
    return "{}_pid{}".format(time.strftime("%Y%m%d_%H%M%S"), os.getpid())


def setup_logging(script_name):
    os.makedirs("outputs/logs", exist_ok=True)
    stamp = stamp_for_path()
    path = os.path.join("outputs/logs", "{}_{}.log".format(script_name, stamp))
    tee = Tee(path)
    sys.stdout = tee
    print("Log:", path)
    return tee, stamp


def ensure_unique_path(path):
    if not os.path.exists(path):
        return path
    root, ext = os.path.splitext(path)
    idx = 1
    while True:
        candidate = "{}_{}{}".format(root, idx, ext)
        if not os.path.exists(candidate):
            return candidate
        idx += 1


def _json_default(obj):
    if isinstance(obj, SageInteger):
        return int(obj)
    raise TypeError("Object of type {} is not JSON serializable".format(type(obj).__name__))


def write_json(path, payload):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2, default=_json_default)


def canonical_block(block, v):
    """Return the lexicographically least cyclic translate of one block."""
    values = sorted(int(x) % int(v) for x in block)
    if not values:
        return tuple()
    best = None
    for shift in range(int(v)):
        translated = tuple(sorted(((x + shift) % int(v)) for x in values))
        if best is None or translated < best:
            best = translated
    return best


def _unit_multipliers(v):
    return [u for u in range(1, int(v)) if gcd(u, int(v)) == 1]


def canonical_candidate(blocks, ks, v):
    """
    Canonicalize a 4-block SDS candidate for discovery/dedup only.

    Allowed equivalences:
    - simultaneous multiplier by a unit modulo v, including inversion u=-1;
    - independent cyclic translation of each block;
    - permutation only among equal-size blocks.

    Complements and unequal-size block permutations are intentionally excluded.
    """
    v = int(v)
    ks = tuple(int(k) for k in ks)
    best = None
    for u in _unit_multipliers(v):
        normalized = []
        for block in blocks:
            multiplied = [int(u * int(x)) % v for x in block]
            normalized.append(canonical_block(multiplied, v))

        grouped = list(normalized)
        by_size = {}
        for idx, size in enumerate(ks):
            by_size.setdefault(int(size), []).append(idx)
        for indices in by_size.values():
            if len(indices) <= 1:
                continue
            sorted_blocks = sorted(grouped[idx] for idx in indices)
            for idx, block in zip(indices, sorted_blocks):
                grouped[idx] = block

        candidate = tuple(tuple(int(x) for x in block) for block in grouped)
        if best is None or candidate < best:
            best = candidate
    return best


def canonical_hash(blocks, ks, v):
    representation = canonical_candidate(blocks, ks, v)
    return canonical_hash_from_representation(representation, ks, v)


def canonical_hash_from_representation(representation, ks, v):
    payload = {
        "v": int(v),
        "ks": [int(k) for k in ks],
        "blocks": [[int(x) for x in block] for block in representation],
    }
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def canonical_repr_summary(blocks, ks, v):
    representation = canonical_candidate(blocks, ks, v)
    block_prefixes = []
    block_sizes = []
    for block in representation:
        values = [int(x) for x in block]
        block_sizes.append(len(values))
        block_prefixes.append(values[:12])
    return {
        "v": int(v),
        "ks": [int(k) for k in ks],
        "hash": canonical_hash_from_representation(representation, ks, v),
        "block_sizes": block_sizes,
        "block_prefixes": block_prefixes,
        "representation": [[int(x) for x in block] for block in representation],
    }


def validate_params(v, ks, lam):
    if v <= 0:
        raise ValueError("v must be positive")
    if len(ks) != 4:
        raise ValueError("ks must contain exactly four block sizes")
    if any(k < 0 or k > v for k in ks):
        raise ValueError("each block size must lie between 0 and v")
    if lam != sum(ks) - v:
        raise ValueError(
            "lambda={} does not equal sum(ks)-v={}".format(lam, sum(ks) - v)
        )
    lhs = sum(k * (k - 1) for k in ks)
    rhs = lam * (v - 1)
    if lhs != rhs:
        raise ValueError(
            "SDS parameter equation failed for ks={}, lambda={}: {} != {}".format(
                ks, lam, lhs, rhs
            )
        )


def normalize_blocks(v, raw_blocks):
    if len(raw_blocks) != 4:
        raise ValueError("expected exactly four blocks, got {}".format(len(raw_blocks)))
    blocks = []
    for idx, raw_block in enumerate(raw_blocks):
        values = [int(x) for x in raw_block]
        out_of_range = [x for x in values if x < 0 or x >= v]
        if out_of_range:
            raise ValueError(
                "block {} has elements outside Z_{}: {}".format(
                    idx, v, out_of_range[:20]
                )
            )
        if len(values) != len(set(values)):
            raise ValueError("block {} has duplicate elements".format(idx))
        blocks.append(set(values))
    return blocks


def load_candidate(path):
    with open(path) as f:
        data = json.load(f)

    missing = [key for key in ["v", "n", "ks", "lambda", "blocks"] if key not in data]
    if missing:
        raise ValueError("candidate JSON is missing keys: {}".format(missing))

    v = int(data["v"])
    n = int(data["n"])
    ks = tuple(int(k) for k in data["ks"])
    lam = int(data["lambda"])
    if n != 4 * v:
        raise ValueError("n={} does not equal 4*v={}".format(n, 4 * v))

    validate_params(v, ks, lam)
    blocks = normalize_blocks(v, data["blocks"])
    block_sizes = tuple(len(block) for block in blocks)
    if block_sizes != ks:
        raise ValueError("block sizes {} do not match ks {}".format(block_sizes, ks))
    return data, v, n, ks, lam, blocks


def json_blocks(blocks):
    return [[int(x) for x in sorted(block)] for block in blocks]


def total_diff_counts(v, blocks):
    total = [0] * v
    for block in blocks:
        values = list(block)
        for x in values:
            for y in values:
                if x != y:
                    total[(x - y) % v] += 1
    return total


def delta_swap(v, block, removed, added):
    delta = [0] * v
    others = set(block)
    others.remove(removed)
    for y in others:
        delta[(removed - y) % v] -= 1
        delta[(y - removed) % v] -= 1
        delta[(added - y) % v] += 1
        delta[(y - added) % v] += 1
    return delta


def apply_delta(counts, delta):
    return [counts[d] + delta[d] for d in range(len(counts))]


def evaluate_swap(v, blocks, counts, lam, block_idx, removed, added):
    block = blocks[block_idx]
    if removed not in block:
        return None
    if added in block:
        return None
    delta = delta_swap(v, block, removed, added)
    new_counts = apply_delta(counts, delta)
    new_metrics = metrics_from_counts(new_counts, lam)
    return {
        "metrics": new_metrics,
        "block": int(block_idx),
        "removed": int(removed),
        "added": int(added),
        "delta": delta,
        "counts": new_counts,
    }


def apply_swap_to_blocks(blocks, swap):
    block_idx = int(swap["block"])
    removed = int(swap["removed"])
    added = int(swap["added"])
    if removed not in blocks[block_idx]:
        return False
    if added in blocks[block_idx]:
        return False
    blocks[block_idx].remove(removed)
    blocks[block_idx].add(added)
    return True


def move_block(move):
    if "block_index" in move:
        return int(move["block_index"])
    return int(move["block"])


def move_removed(move):
    if "remove" in move:
        return int(move["remove"])
    return int(move["removed"])


def move_added(move):
    if "add" in move:
        return int(move["add"])
    return int(move["added"])


def compact_move(move):
    block_idx = move_block(move)
    removed = move_removed(move)
    added = move_added(move)
    return {
        "block_index": int(block_idx),
        "remove": int(removed),
        "add": int(added),
        "block": int(block_idx),
        "removed": int(removed),
        "added": int(added),
    }


def selected_moves_from_payload(data):
    moves = []
    for key in ("selected_moves", "selected_swaps"):
        raw_moves = data.get(key)
        if not isinstance(raw_moves, list):
            continue
        for raw in raw_moves:
            if not isinstance(raw, dict):
                continue
            try:
                moves.append(compact_move(raw))
            except (KeyError, ValueError, TypeError):
                continue

    seen = set()
    out = []
    for move in moves:
        key = (move["block_index"], move["remove"], move["add"])
        if key in seen:
            continue
        seen.add(key)
        out.append(move)
    return out


def load_selected_moves(path):
    if not path:
        return []
    with open(path) as f:
        data = json.load(f)
    return selected_moves_from_payload(data)


def no_reversal_key(move):
    return (int(move["block_index"]), int(move["add"]), int(move["remove"]))


def swap_key(swap):
    return (int(swap["block"]), int(swap["removed"]), int(swap["added"]))


def swap_touches_move(swap, move):
    if int(swap["block"]) != int(move["block_index"]):
        return False
    touched = set([int(move["remove"]), int(move["add"])])
    return int(swap["removed"]) in touched or int(swap["added"]) in touched


def tabu_skips_swap(swap, selected_moves, no_reversal=False, touch_elements=False):
    if not selected_moves:
        return False
    if no_reversal:
        reversal_keys = set(no_reversal_key(move) for move in selected_moves)
        if swap_key(swap) in reversal_keys:
            return True
    if touch_elements:
        for move in selected_moves:
            if swap_touches_move(swap, move):
                return True
    return False


def all_one_swap_candidates(v, blocks, counts, lam, limit=None):
    candidates = []
    universe = list(range(v))
    for block_idx, block in enumerate(blocks):
        if len(block) == 0 or len(block) == v:
            continue
        outside = [x for x in universe if x not in block]
        for removed in sorted(block):
            for added in outside:
                item = evaluate_swap(v, blocks, counts, lam, block_idx, removed, added)
                if item is not None:
                    candidates.append(item)
    candidates.sort(
        key=lambda item: (
            item["metrics"],
            item["block"],
            item["removed"],
            item["added"],
        )
    )
    if limit is not None:
        return candidates[: int(limit)]
    return candidates


def metrics_from_counts(counts, lam):
    score = 0
    l1_error = 0
    max_abs_error = 0
    nonzero_defect_count = 0
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        abs_err = abs(err)
        score += err * err
        l1_error += abs_err
        if abs_err > max_abs_error:
            max_abs_error = abs_err
        if err != 0:
            nonzero_defect_count += 1
    return (
        int(score),
        int(l1_error),
        int(max_abs_error),
        int(nonzero_defect_count),
    )


def p_adic_moment_summary(counts, lam, powers=(2, 4, 6), modulus=None):
    """
    Return low-degree p-adic moment diagnostics for an SDS defect vector.

    For a target SDS over Z_p, the defect rho(d)=count[d]-lambda must satisfy
    sum_{d != 0} rho(d) d^(2a) == 0 mod p. These diagnostics are necessary
    conditions only; they are not success certificates.
    """
    if modulus is None:
        modulus = len(counts)
    modulus = int(modulus)
    moments = []
    zero_count = 0
    abs_sum = 0
    for power in powers:
        power = int(power)
        total = 0
        for d in range(1, len(counts)):
            total += int(counts[d] - lam) * pow(int(d) % modulus, power, modulus)
        residue = int(total % modulus)
        balanced_abs = min(residue, modulus - residue) if modulus > 0 else abs(residue)
        if residue == 0:
            zero_count += 1
        abs_sum += int(balanced_abs)
        moments.append(
            {
                "power": int(power),
                "residue": int(residue),
                "balanced_abs": int(balanced_abs),
                "zero": bool(residue == 0),
            }
        )
    return {
        "modulus": int(modulus),
        "powers": [int(power) for power in powers],
        "moments": moments,
        "moment_signature": ",".join(str(item["residue"]) for item in moments),
        "moment_zero_count": int(zero_count),
        "moment_all_zero": bool(zero_count == len(moments)),
        "moment_abs_sum": int(abs_sum),
    }


def error_histogram(counts, lam):
    hist = {}
    for d in range(1, len(counts)):
        err = int(counts[d] - lam)
        hist[err] = hist.get(err, 0) + 1
    return {str(key): int(hist[key]) for key in sorted(hist)}


def verify_sds(v, blocks, lam):
    counts = total_diff_counts(v, blocks)
    bad = []
    for d in range(1, v):
        if counts[d] != lam:
            bad.append((d, counts[d]))
    return len(bad) == 0, bad


def block_to_pm1_circulant(v, block):
    first_row = [-1 if i in block else 1 for i in range(v)]
    return matrix(ZZ, v, v, lambda i, j: first_row[(j - i) % v])


def back_identity(v):
    return matrix(ZZ, v, v, lambda i, j: 1 if i + j == v - 1 else 0)


def goethals_seidel_matrix(v, blocks):
    A, B, C, D = [block_to_pm1_circulant(v, block) for block in blocks]
    R = back_identity(v)
    return block_matrix(
        ZZ,
        [
            [A, B * R, C * R, D * R],
            [-B * R, A, -D.transpose() * R, C.transpose() * R],
            [-C * R, D.transpose() * R, A, -B.transpose() * R],
            [-D * R, -C.transpose() * R, B.transpose() * R, A],
        ],
        subdivide=False,
    )


def verify_hadamard_exact(v, blocks):
    H = goethals_seidel_matrix(v, blocks)
    n = 4 * v
    entries_ok = all(x in (-1, 1) for x in H.list())
    hh_t = H * H.transpose() == n * identity_matrix(ZZ, n)
    return bool(entries_ok), bool(hh_t)


def base_payload(
    v,
    ks,
    lam,
    blocks,
    metrics,
    source_json,
    search_method,
    round_index,
    step_label,
    counts,
    extra=None,
):
    score, l1_error, max_abs_error, nonzero_defect_count = metrics
    payload = {
        "v": int(v),
        "n": int(4 * v),
        "ks": [int(k) for k in ks],
        "lambda": int(lam),
        "blocks": json_blocks(blocks),
        "score": int(score),
        "l1_error": int(l1_error),
        "max_abs_error": int(max_abs_error),
        "nonzero_defect_count": int(nonzero_defect_count),
        "source_json": source_json,
        "round": int(round_index),
        "step": int(step_label),
        "verify_sds": False,
        "generated_hadamard": False,
        "hh_t": False,
        "construction": "Goethals-Seidel",
        "search_method": search_method,
        "timestamp": timestamp(),
        "error_histogram": error_histogram(counts, lam),
    }
    payload["canonical_hash"] = canonical_hash(blocks, ks, v)
    payload["canonical_repr_summary"] = canonical_repr_summary(blocks, ks, v)
    if extra:
        payload.update(extra)
    return payload


def save_near_hit(
    outdir,
    v,
    ks,
    lam,
    blocks,
    metrics,
    source_json,
    search_method,
    round_index,
    step_label,
    counts,
    extra=None,
):
    os.makedirs(outdir, exist_ok=True)
    score = metrics[0]
    payload = base_payload(
        v,
        ks,
        lam,
        blocks,
        metrics,
        source_json,
        search_method,
        round_index,
        step_label,
        counts,
        extra,
    )
    name = "near_hit_v{}_score{}_{}_round{}.json".format(
        v, score, search_method, round_index
    )
    path = ensure_unique_path(os.path.join(outdir, name))
    write_json(path, payload)
    print(
        "NEAR_HIT saved path={} score={} l1_error={} max_abs_error={} "
        "nonzero_defect_count={}".format(
            path, metrics[0], metrics[1], metrics[2], metrics[3]
        )
    )
    return path


def save_success(
    outdir,
    near_hit_dir,
    v,
    ks,
    lam,
    blocks,
    metrics,
    source_json,
    search_method,
    round_index,
    step_label,
    counts,
    extra=None,
):
    payload = base_payload(
        v,
        ks,
        lam,
        blocks,
        metrics,
        source_json,
        search_method,
        round_index,
        step_label,
        counts,
        extra,
    )

    sds_ok, bad = verify_sds(v, blocks, lam)
    payload["verify_sds"] = bool(sds_ok)
    if not sds_ok:
        payload["sds_failure_first_bad_shifts"] = [
            [int(d), int(count)] for d, count in bad[:30]
        ]
        path = ensure_unique_path(
            os.path.join(
                near_hit_dir,
                "near_hit_v{}_score0_{}_round{}.json".format(
                    v, search_method, round_index
                ),
            )
        )
        write_json(path, payload)
        raise RuntimeError(
            "score 0 candidate failed explicit SDS verification; saved {}".format(
                path
            )
        )

    entries_ok, hh_t = verify_hadamard_exact(v, blocks)
    payload["generated_hadamard"] = bool(entries_ok)
    payload["hh_t"] = bool(hh_t)
    if not entries_ok or not hh_t:
        path = ensure_unique_path(
            os.path.join(
                near_hit_dir,
                "near_hit_v{}_score0_{}_round{}.json".format(
                    v, search_method, round_index
                ),
            )
        )
        write_json(path, payload)
        raise RuntimeError(
            "score 0 SDS failed Goethals-Seidel Hadamard verification; saved {}".format(
                path
            )
        )

    os.makedirs(outdir, exist_ok=True)
    name = "candidate_sds_v{}_n{}_{}_round{}.json".format(
        v, 4 * v, search_method, round_index
    )
    path = ensure_unique_path(os.path.join(outdir, name))
    write_json(path, payload)
    print("SUCCESS saved:", path)
    return path
