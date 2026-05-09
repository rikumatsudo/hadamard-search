use std::collections::HashMap;
use std::env;
use std::error::Error;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
struct Config {
    name: String,
    random_seed_base: u64,
    p: usize,
    ks: Vec<usize>,
    lambda: i32,
    seeds: usize,
    steps: usize,
    candidates_per_family: usize,
    selected_per_family: usize,
}

#[derive(Clone, Debug)]
struct Args {
    config: PathBuf,
    out_dir: PathBuf,
    seeds: Option<usize>,
    seed_start: Option<usize>,
    seed_count: Option<usize>,
    total_seeds: Option<usize>,
    shard_index: Option<usize>,
    shard_count: Option<usize>,
    steps: Option<usize>,
    candidates_per_family: Option<usize>,
    selected_per_family: Option<usize>,
}

#[derive(Clone, Debug)]
struct SeedPartition {
    mode: String,
    seed_start: usize,
    seed_count: usize,
    total_seeds: Option<usize>,
    shard_index: Option<usize>,
    shard_count: Option<usize>,
}

#[derive(Clone, Debug)]
struct Candidate {
    seed: usize,
    step: usize,
    score: i64,
    blocks: Vec<Vec<usize>>,
}

#[derive(Clone, Debug)]
struct Move {
    block: usize,
    removed: usize,
    added: usize,
    h: i64,
    delta: Vec<(usize, i32)>,
}

#[derive(Clone)]
struct State {
    blocks: Vec<Vec<usize>>,
    membership: Vec<Vec<bool>>,
    counts: Vec<i32>,
    score: i64,
}

struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self { state: seed | 1 }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(2685821657736338717)
    }

    fn gen_range(&mut self, upper: usize) -> usize {
        if upper <= 1 {
            return 0;
        }
        (self.next_u64() as usize) % upper
    }
}

fn parse_args() -> Result<Args, Box<dyn Error>> {
    let mut values = HashMap::new();
    let raw: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < raw.len() {
        let key = raw[i].clone();
        if !key.starts_with("--") {
            return Err(format!("unexpected positional argument: {}", key).into());
        }
        if i + 1 >= raw.len() {
            return Err(format!("missing value for {}", key).into());
        }
        values.insert(key.trim_start_matches("--").to_string(), raw[i + 1].clone());
        i += 2;
    }
    let config = PathBuf::from(required(&values, "config")?);
    let out_dir = PathBuf::from(required(&values, "out-dir")?);
    Ok(Args {
        config,
        out_dir,
        seeds: parse_usize(&values, "seeds")?,
        seed_start: parse_usize(&values, "seed-start")?,
        seed_count: parse_usize(&values, "seed-count")?,
        total_seeds: parse_usize(&values, "total-seeds")?,
        shard_index: parse_usize(&values, "shard-index")?,
        shard_count: parse_usize(&values, "shard-count")?,
        steps: parse_usize(&values, "steps")?,
        candidates_per_family: parse_usize(&values, "candidates-per-family")?,
        selected_per_family: parse_usize(&values, "selected-per-family")?,
    })
}

fn required(values: &HashMap<String, String>, key: &str) -> Result<String, Box<dyn Error>> {
    values
        .get(key)
        .cloned()
        .ok_or_else(|| format!("missing --{}", key).into())
}

fn parse_usize(values: &HashMap<String, String>, key: &str) -> Result<Option<usize>, Box<dyn Error>> {
    match values.get(key) {
        Some(value) if !value.trim().is_empty() => Ok(Some(value.parse::<usize>()?)),
        _ => Ok(None),
    }
}

fn parse_config(path: &Path) -> Result<Config, Box<dyn Error>> {
    let text = fs::read_to_string(path)?;
    let mut section = String::new();
    let mut values = HashMap::new();
    for line in text.lines() {
        let without_comment = line.split('#').next().unwrap_or("").trim_end();
        if without_comment.trim().is_empty() {
            continue;
        }
        if !without_comment.starts_with(' ') && without_comment.ends_with(':') {
            section = without_comment.trim_end_matches(':').trim().to_string();
            continue;
        }
        let trimmed = without_comment.trim();
        if let Some((key, value)) = trimmed.split_once(':') {
            let compound = if section.is_empty() {
                key.trim().to_string()
            } else {
                format!("{}.{}", section, key.trim())
            };
            values.insert(compound, value.trim().to_string());
        }
    }

    let ks = parse_list_usize(get_required(&values, "target.ks")?)?;
    if ks.len() != 4 {
        return Err("target.ks must contain exactly four sizes".into());
    }
    Ok(Config {
        name: trim_scalar(values.get("experiment.name").map(String::as_str).unwrap_or("rust_search")),
        random_seed_base: get_usize(&values, "experiment.random_seed_base", 0)? as u64,
        p: get_usize_required(&values, "target.p")?,
        ks,
        lambda: get_usize_required(&values, "target.lambda")? as i32,
        seeds: get_usize(&values, "run.seeds", 1)?,
        steps: get_usize(&values, "run.steps", 1000)?,
        candidates_per_family: get_usize(&values, "initialization.candidates_per_family", 20)?,
        selected_per_family: get_usize(&values, "initialization.selected_per_family", 5)?,
    })
}

fn get_required<'a>(values: &'a HashMap<String, String>, key: &str) -> Result<&'a str, Box<dyn Error>> {
    values
        .get(key)
        .map(String::as_str)
        .ok_or_else(|| format!("missing config key {}", key).into())
}

fn get_usize_required(values: &HashMap<String, String>, key: &str) -> Result<usize, Box<dyn Error>> {
    Ok(trim_scalar(get_required(values, key)?).parse::<usize>()?)
}

fn get_usize(values: &HashMap<String, String>, key: &str, default: usize) -> Result<usize, Box<dyn Error>> {
    match values.get(key) {
        Some(value) if !value.trim().is_empty() => Ok(trim_scalar(value).parse::<usize>()?),
        _ => Ok(default),
    }
}

fn trim_scalar(value: &str) -> String {
    value.trim().trim_matches('"').trim_matches('\'').to_string()
}

fn parse_list_usize(value: &str) -> Result<Vec<usize>, Box<dyn Error>> {
    let inner = value.trim().trim_start_matches('[').trim_end_matches(']');
    let mut out = Vec::new();
    for item in inner.split(',') {
        let trimmed = item.trim();
        if !trimmed.is_empty() {
            out.push(trimmed.parse::<usize>()?);
        }
    }
    Ok(out)
}

fn resolve_seed_indices(args: &Args, cfg: &Config) -> Result<(Vec<usize>, SeedPartition), Box<dyn Error>> {
    let mut requested = args.seeds.unwrap_or(cfg.seeds);
    if let Some(seed_count) = args.seed_count {
        requested = seed_count;
    }
    if requested == 0 {
        return Err("seed count must be positive".into());
    }
    let has_shard = args.shard_index.is_some() || args.shard_count.is_some();
    if has_shard {
        if args.seed_start.is_some() || args.seed_count.is_some() {
            return Err("--seed-start/--seed-count cannot be combined with shard arguments".into());
        }
        let shard_index = match args.shard_index {
            Some(value) => value,
            None => return Err("--shard-index and --shard-count must be provided together".into()),
        };
        let shard_count = match args.shard_count {
            Some(value) => value,
            None => return Err("--shard-index and --shard-count must be provided together".into()),
        };
        let total_seeds = args.total_seeds.unwrap_or(requested);
        if shard_count == 0 {
            return Err("--shard-count must be positive".into());
        }
        if total_seeds < shard_count {
            return Err("--total-seeds must be greater than or equal to --shard-count".into());
        }
        if shard_index >= shard_count {
            return Err("--shard-index must satisfy 0 <= shard_index < shard_count".into());
        }
        let start = total_seeds * shard_index / shard_count;
        let end = total_seeds * (shard_index + 1) / shard_count;
        return Ok((
            (start..end).collect(),
            SeedPartition {
                mode: "shard".to_string(),
                seed_start: start,
                seed_count: end - start,
                total_seeds: Some(total_seeds),
                shard_index: Some(shard_index),
                shard_count: Some(shard_count),
            },
        ));
    }
    let start = args.seed_start.unwrap_or(0);
    Ok((
        (start..start + requested).collect(),
        SeedPartition {
            mode: "range".to_string(),
            seed_start: start,
            seed_count: requested,
            total_seeds: None,
            shard_index: None,
            shard_count: None,
        },
    ))
}

fn validate_params(cfg: &Config) -> Result<(), Box<dyn Error>> {
    if cfg.p == 0 || cfg.ks.len() != 4 {
        return Err("invalid target dimensions".into());
    }
    if cfg.ks.iter().any(|&k| k > cfg.p) {
        return Err("block size exceeds p".into());
    }
    let sum_k: i32 = cfg.ks.iter().map(|&k| k as i32).sum();
    if cfg.lambda != sum_k - cfg.p as i32 {
        return Err("lambda must equal sum(ks)-p".into());
    }
    let lhs: i32 = cfg.ks.iter().map(|&k| (k * (k - 1)) as i32).sum();
    let rhs = cfg.lambda * (cfg.p as i32 - 1);
    if lhs != rhs {
        return Err("SDS parameter equation failed".into());
    }
    Ok(())
}

fn random_block(rng: &mut Rng, p: usize, k: usize) -> Vec<usize> {
    let mut values: Vec<usize> = (0..p).collect();
    for i in 0..k {
        let j = i + rng.gen_range(p - i);
        values.swap(i, j);
    }
    let mut block = values[..k].to_vec();
    block.sort_unstable();
    block
}

fn membership_from_blocks(blocks: &[Vec<usize>], p: usize) -> Vec<Vec<bool>> {
    let mut membership = vec![vec![false; p]; blocks.len()];
    for (idx, block) in blocks.iter().enumerate() {
        for &x in block {
            membership[idx][x] = true;
        }
    }
    membership
}

fn total_diff_counts(p: usize, blocks: &[Vec<usize>]) -> Vec<i32> {
    let mut counts = vec![0i32; p];
    for block in blocks {
        for &x in block {
            for &y in block {
                if x != y {
                    counts[(x + p - y) % p] += 1;
                }
            }
        }
    }
    counts
}

fn score_counts(counts: &[i32], lambda: i32) -> i64 {
    counts
        .iter()
        .enumerate()
        .skip(1)
        .map(|(_, &count)| {
            let err = (count - lambda) as i64;
            err * err
        })
        .sum()
}

fn initial_state(cfg: &Config, rng: &mut Rng) -> State {
    let blocks: Vec<Vec<usize>> = cfg.ks.iter().map(|&k| random_block(rng, cfg.p, k)).collect();
    let membership = membership_from_blocks(&blocks, cfg.p);
    let counts = total_diff_counts(cfg.p, &blocks);
    let score = score_counts(&counts, cfg.lambda);
    State {
        blocks,
        membership,
        counts,
        score,
    }
}

fn sparse_delta(p: usize, block: &[usize], removed: usize, added: usize) -> Vec<(usize, i32)> {
    let mut delta = vec![0i32; p];
    for &y in block {
        if y == removed {
            continue;
        }
        delta[(removed + p - y) % p] -= 1;
        delta[(y + p - removed) % p] -= 1;
        delta[(added + p - y) % p] += 1;
        delta[(y + p - added) % p] += 1;
    }
    delta
        .into_iter()
        .enumerate()
        .filter_map(|(idx, value)| if value == 0 { None } else { Some((idx, value)) })
        .collect()
}

fn score_delta(counts: &[i32], lambda: i32, delta: &[(usize, i32)]) -> i64 {
    let mut h = 0i64;
    for &(d, dv) in delta {
        if d == 0 {
            continue;
        }
        let rho = (counts[d] - lambda) as i64;
        let dv = dv as i64;
        h += 2 * rho * dv + dv * dv;
    }
    h
}

fn best_improving_move(state: &State, cfg: &Config) -> Option<Move> {
    let mut best: Option<Move> = None;
    for block_idx in 0..state.blocks.len() {
        let block = &state.blocks[block_idx];
        for &removed in block {
            for added in 0..cfg.p {
                if state.membership[block_idx][added] {
                    continue;
                }
                let delta = sparse_delta(cfg.p, block, removed, added);
                let h = score_delta(&state.counts, cfg.lambda, &delta);
                if h >= 0 {
                    continue;
                }
                let replace = best.as_ref().map(|m| h < m.h).unwrap_or(true);
                if replace {
                    best = Some(Move {
                        block: block_idx,
                        removed,
                        added,
                        h,
                        delta,
                    });
                }
            }
        }
    }
    best
}

fn apply_move(state: &mut State, mv: &Move, lambda: i32) {
    let block = &mut state.blocks[mv.block];
    if let Some(pos) = block.iter().position(|&x| x == mv.removed) {
        block[pos] = mv.added;
    }
    block.sort_unstable();
    state.membership[mv.block][mv.removed] = false;
    state.membership[mv.block][mv.added] = true;
    for &(d, value) in &mv.delta {
        state.counts[d] += value;
    }
    state.score = score_counts(&state.counts, lambda);
}

fn run_seed(cfg: &Config, seed_index: usize) -> Candidate {
    let mut rng = Rng::new(cfg.random_seed_base + 100_000 * (seed_index as u64 + 1));
    let mut best = initial_state(cfg, &mut rng);
    let mut state = best.clone();
    let mut best_step = 0;
    for step in 1..=cfg.steps {
        let Some(mv) = best_improving_move(&state, cfg) else {
            break;
        };
        apply_move(&mut state, &mv, cfg.lambda);
        if state.score < best.score {
            best = state.clone();
            best_step = step;
        }
        if state.score == 0 {
            break;
        }
    }
    Candidate {
        seed: seed_index,
        step: best_step,
        score: best.score,
        blocks: best.blocks,
    }
}

fn json_blocks(blocks: &[Vec<usize>]) -> String {
    let parts: Vec<String> = blocks
        .iter()
        .map(|block| {
            let values: Vec<String> = block.iter().map(|x| x.to_string()).collect();
            format!("[{}]", values.join(","))
        })
        .collect();
    format!("[{}]", parts.join(","))
}

fn write_candidate<W: Write>(writer: &mut W, cfg: &Config, candidate: &Candidate) -> Result<(), Box<dyn Error>> {
    writeln!(
        writer,
        "{{\"search_method\":\"rust_search_mvp\",\"p\":{},\"v\":{},\"n\":{},\"ks\":[{}],\"lambda\":{},\"seed\":{},\"step\":{},\"score\":{},\"is_score0\":{},\"blocks\":{}}}",
        cfg.p,
        cfg.p,
        4 * cfg.p,
        cfg.ks.iter().map(|k| k.to_string()).collect::<Vec<_>>().join(","),
        cfg.lambda,
        candidate.seed,
        candidate.step,
        candidate.score,
        if candidate.score == 0 { "true" } else { "false" },
        json_blocks(&candidate.blocks)
    )?;
    Ok(())
}

fn write_summary(
    out_dir: &Path,
    cfg: &Config,
    partition: &SeedPartition,
    candidates: &[Candidate],
) -> Result<(), Box<dyn Error>> {
    let best_score = candidates.iter().map(|c| c.score).min();
    let score0_count = candidates.iter().filter(|c| c.score == 0).count();
    let summary_json = out_dir.join("engine_summary.json");
    let mut json = BufWriter::new(File::create(summary_json)?);
    writeln!(
        json,
        "{{\"engine\":\"rust_search_mvp\",\"experiment\":\"{}\",\"p\":{},\"ks\":[{}],\"lambda\":{},\"run_count\":{},\"best_score\":{},\"score0_count\":{},\"seed_partition\":{{\"mode\":\"{}\",\"seed_start\":{},\"seed_count\":{},\"total_seeds\":{},\"shard_index\":{},\"shard_count\":{}}}}}",
        cfg.name,
        cfg.p,
        cfg.ks.iter().map(|k| k.to_string()).collect::<Vec<_>>().join(","),
        cfg.lambda,
        candidates.len(),
        best_score.map(|x| x.to_string()).unwrap_or_else(|| "null".to_string()),
        score0_count,
        partition.mode,
        partition.seed_start,
        partition.seed_count,
        option_json(partition.total_seeds),
        option_json(partition.shard_index),
        option_json(partition.shard_count)
    )?;

    let summary_md = out_dir.join("engine_summary.md");
    let mut md = BufWriter::new(File::create(summary_md)?);
    writeln!(md, "# Rust Search Engine Summary")?;
    writeln!(md)?;
    writeln!(md, "- engine: `rust_search_mvp`")?;
    writeln!(md, "- experiment: `{}`", cfg.name)?;
    writeln!(md, "- p: `{}`", cfg.p)?;
    writeln!(md, "- ks: `{:?}`", cfg.ks)?;
    writeln!(md, "- lambda: `{}`", cfg.lambda)?;
    writeln!(md, "- run count: `{}`", candidates.len())?;
    writeln!(md, "- best score: `{}`", best_score.map(|x| x.to_string()).unwrap_or_else(|| "n/a".to_string()))?;
    writeln!(md, "- score0 candidates: `{}`", score0_count)?;
    Ok(())
}

fn option_json(value: Option<usize>) -> String {
    value.map(|x| x.to_string()).unwrap_or_else(|| "null".to_string())
}

fn write_run_config(out_dir: &Path, cfg: &Config, partition: &SeedPartition) -> Result<(), Box<dyn Error>> {
    let mut file = BufWriter::new(File::create(out_dir.join("run_config.json"))?);
    writeln!(
        file,
        "{{\"engine\":\"rust_search_mvp\",\"experiment\":\"{}\",\"random_seed_base\":{},\"target\":{{\"p\":{},\"ks\":[{}],\"lambda\":{}}},\"run\":{{\"seeds\":{},\"steps\":{},\"seed_partition\":{{\"mode\":\"{}\",\"seed_start\":{},\"seed_count\":{}}}}}}}",
        cfg.name,
        cfg.random_seed_base,
        cfg.p,
        cfg.ks.iter().map(|k| k.to_string()).collect::<Vec<_>>().join(","),
        cfg.lambda,
        cfg.seeds,
        cfg.steps,
        partition.mode,
        partition.seed_start,
        partition.seed_count
    )?;
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let args = parse_args()?;
    let mut cfg = parse_config(&args.config)?;
    if let Some(seeds) = args.seeds {
        cfg.seeds = seeds;
    }
    if let Some(steps) = args.steps {
        cfg.steps = steps;
    }
    if let Some(candidates_per_family) = args.candidates_per_family {
        cfg.candidates_per_family = candidates_per_family;
    }
    if let Some(selected_per_family) = args.selected_per_family {
        cfg.selected_per_family = selected_per_family;
    }
    validate_params(&cfg)?;
    let (seed_indices, partition) = resolve_seed_indices(&args, &cfg)?;
    fs::create_dir_all(&args.out_dir)?;
    write_run_config(&args.out_dir, &cfg, &partition)?;

    let candidates_path = args.out_dir.join("candidates.jsonl");
    let mut candidates_file = BufWriter::new(File::create(candidates_path)?);
    let mut candidates = Vec::new();
    for seed in seed_indices {
        let candidate = run_seed(&cfg, seed);
        write_candidate(&mut candidates_file, &cfg, &candidate)?;
        println!("seed {} best score {} step {}", seed, candidate.score, candidate.step);
        candidates.push(candidate);
    }
    write_summary(&args.out_dir, &cfg, &partition, &candidates)?;
    println!("SUMMARY: {}", args.out_dir.join("engine_summary.md").display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn score_zero_for_tiny_sds_counts() {
        let counts = vec![0, 1, 1];
        assert_eq!(score_counts(&counts, 1), 0);
    }

    #[test]
    fn shard_split_matches_contiguous_ranges() {
        let args = Args {
            config: PathBuf::from("x"),
            out_dir: PathBuf::from("out"),
            seeds: None,
            seed_start: None,
            seed_count: None,
            total_seeds: Some(200),
            shard_index: Some(39),
            shard_count: Some(40),
            steps: None,
            candidates_per_family: None,
            selected_per_family: None,
        };
        let cfg = Config {
            name: "x".to_string(),
            random_seed_base: 0,
            p: 167,
            ks: vec![73, 78, 79, 81],
            lambda: 144,
            seeds: 1,
            steps: 1,
            candidates_per_family: 1,
            selected_per_family: 1,
        };
        let (indices, partition) = resolve_seed_indices(&args, &cfg).unwrap();
        assert_eq!(indices, vec![195, 196, 197, 198, 199]);
        assert_eq!(partition.seed_count, 5);
    }
}
