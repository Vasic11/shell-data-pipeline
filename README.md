# Shell Data Pipeline

A fault-tolerant Bash pipeline that processes large CSV files in parallel. It splits the input into chunks, runs a worker process on each one, supervises those workers, retries the ones that fail, kills the ones that hang, and merges everything into a single aggregated result. An interrupted run can be resumed where it stopped.

Built as the first project for the Shell Programming course at RAF (Računarski fakultet, Belgrade). The orchestrator, `pipeline.sh`, is my work. The data generator and the chunk processor (`provided/`) were given by the course. The processor deliberately fails, crashes, hangs and writes corrupt output at configurable rates, so the pipeline has to survive all of it.

## What it does

Input is a CSV of sales transactions:

```
transaction_id,timestamp,region,category,amount,quantity
1,2026-01-01T08:15:02,Beograd,elektronika,1299.99,1
```

Output is one row per region (or category) with totals:

```
group,count,sum_amount,avg_amount,min_amount,max_amount,sum_quantity
Beograd,300512,...
```

Along the way the pipeline:

- **Splits** the input into chunks (100,000 rows by default) and checks that no row was lost in the split.
- **Runs chunks in parallel**, up to `workers` processes at a time.
- **Validates every output**: header, row counts and the `#END` summary line must match the chunk, otherwise the result counts as corrupt.
- **Retries failures** with exponential backoff (1s, 2s, 4s... capped at `backoff_max`), up to `max_retries` times.
- **Detects hung workers** by watching their progress output. A worker silent for `hang_timeout` seconds gets `SIGTERM`, then `SIGKILL` if it is still alive after `kill_grace` seconds.
- **Aborts** when more than `max_failed_chunks` chunks fail for good, instead of producing a mostly empty result.
- **Merges** the chunk results with `awk` into `result.csv`, or `result.partial.csv` if some chunks failed.
- **Handles Ctrl+C cleanly**: running workers are stopped, their chunks go back to pending, and the run is marked `interrupted` so it can be resumed.
- **Locks** each run with `flock`, so the same run cannot be processed twice at once.

## Requirements

Linux with Bash 4+, Python 3, GNU coreutils (`split`, `stat`, `df`), `awk` and `flock` (util-linux).

## Usage

Generate test data:

```bash
python3 provided/gen_data.py --rows 1000000 --seed 42 --output data.csv
```

Run the pipeline:

```bash
./pipeline.sh run --input data.csv
./pipeline.sh run --input data.csv --workers 8 --config my.conf
```

Other modes:

```bash
./pipeline.sh status [run_id]   # progress of a run (latest by default)
./pipeline.sh resume <run_id>   # continue an interrupted run
./pipeline.sh report <run_id>   # summary of a finished run
./pipeline.sh list              # all runs
./pipeline.sh clean --keep 5    # delete old runs, keep the 5 newest
./pipeline.sh help
```

### Testing failure handling

The processor reads fault rates from environment variables, which makes it easy to see the recovery logic at work:

```bash
PROC_FAIL_RATE=0.2 PROC_HANG_RATE=0.1 PROC_CORRUPT_RATE=0.1 \
  ./pipeline.sh run --input data.csv
```

Press Ctrl+C in the middle of a run, then `./pipeline.sh resume <run_id>` to continue it.

## Configuration

Settings come from `pipeline.conf` (`key = value`). Command-line options override the config file, and the config file overrides the built-in defaults. Every value is validated before the run starts.

| Key | Default | Meaning |
|---|---|---|
| `processor` | (required) | Program that processes one chunk |
| `python` | `python3` | Interpreter for the processor |
| `group_by` | `region` | `region` or `category` |
| `chunk_lines` | `100000` | Rows per chunk |
| `workers` | `4` | Chunks processed at the same time |
| `max_retries` | `3` | Retries per chunk after the first attempt |
| `backoff_base` / `backoff_max` | `1` / `30` | Retry delay in seconds: base × 2^(attempt−1), capped at max |
| `hang_timeout` | `10` | Seconds without progress before a worker counts as hung |
| `kill_grace` | `3` | Seconds between `SIGTERM` and `SIGKILL` |
| `max_failed_chunks` | `2` | Abort the run when more chunks than this fail |
| `work_dir` | `./runs` | Where runs are stored |
| `keep_chunks` | `no` | Keep chunk files after a successful run |
| `log_level` | `INFO` | `DEBUG`, `INFO`, `WARN` or `ERROR` |

## Run directory

Each run gets its own folder, `runs/run_YYYYMMDD_HHMMSS/`:

```
config.snapshot    settings this run used (resume reads them back)
run.meta           input, start and end time, status
manifest.csv       state of every chunk: status, attempts, duration, exit code, failure reason
pipeline.log       timestamped log
chunks/            input chunks
results/           validated output of each finished chunk
logs/              stderr of every attempt
result.csv         final result (result.partial.csv if some chunks failed)
report.txt         summary: retries, failure reasons, hang kills, throughput, slowest chunks
```

`runs/history.csv` keeps one line per finished run.

Exit codes: `0` completed, `1` partial result, `2` usage or config error, `3` run already locked, `4` aborted, `130` interrupted.
