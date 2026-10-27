#!/usr/bin/env python3
"""Compare the implemented CREATE TABLE + INSERT path with SQLite's CLI."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import pathlib
import statistics
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]
SQLITE_SOURCE = ROOT / "bench/3rdparty/sqlite-src-3540100"
DEFAULT_SQZITE = ROOT / "zig-out/bin/zig_hello"


def workload(rows: int) -> str:
    statements = ["CREATE TABLE bench (id INTEGER, payload TEXT);"]
    statements.extend(
        f"INSERT INTO bench VALUES ({row}, 'payload-{row}');" for row in range(rows)
    )
    return "\n".join(statements) + "\n"


def run_once(engine: str, executable: pathlib.Path, rows: int, repeat: int, root: pathlib.Path, sql: str) -> dict:
    database = root / f"{engine}-{rows}-{repeat}.db"
    command = [str(executable), str(database)]
    started = time.perf_counter()
    completed = subprocess.run(
        command,
        input=(f"BEGIN;\n{sql}COMMIT;\n" if engine == "sqlite" else sql),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    elapsed = time.perf_counter() - started
    if completed.returncode:
        raise RuntimeError(f"{engine} failed ({completed.returncode}): {completed.stderr}")
    if engine == "sqzite" and ("错误:" in completed.stdout or completed.stdout.count("执行成功") != rows + 1):
        raise RuntimeError(f"sqzite did not execute all statements successfully: {completed.stdout[-1000:]}")
    validation = {"success_messages": rows + 1} if engine == "sqzite" else None
    if engine == "sqlite":
        verified = subprocess.run(
            [str(executable), str(database), f"SELECT count(*) FROM bench;"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if verified.returncode or verified.stdout.strip() != str(rows):
            raise RuntimeError(f"SQLite row-count verification failed: {verified.stdout} {verified.stderr}")
        validation = {"row_count": int(verified.stdout.strip())}
    return {
        "engine": engine,
        "rows": rows,
        "elapsed_seconds": elapsed,
        "rows_per_second": rows / elapsed if elapsed else None,
        "database_bytes": database.stat().st_size if database.exists() else 0,
        "validation": validation,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sqlite", type=pathlib.Path, help="SQLite CLI override; by default build from bench/3rdparty source")
    parser.add_argument("--sqzite", type=pathlib.Path, default=DEFAULT_SQZITE)
    parser.add_argument("--rows", type=int, nargs="+", default=[100, 1000, 5000, 10000, 50000, 100000])
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--build-mode", default="ReleaseFast", help="sqzite build optimization mode")
    parser.add_argument("--output-dir", type=pathlib.Path, default=ROOT / "bench/results/source-aligned")
    args = parser.parse_args()

    if not args.sqzite.is_file():
        raise SystemExit(f"Executable not found: {args.sqzite}; build it with zig build -Doptimize=ReleaseFast")
    if args.repeat < 1 or any(rows < 1 for rows in args.rows):
        raise SystemExit("--repeat and each --rows value must be positive")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    raw: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="sqzite-bench-") as temp:
        temp_root = pathlib.Path(temp)
        sqlite_build_dir = None
        sqlite_executable = args.sqlite
        if sqlite_executable is None:
            if not SQLITE_SOURCE.is_dir():
                raise SystemExit(f"SQLite source tree not found: {SQLITE_SOURCE}")
            sqlite_build_dir = temp_root / "sqlite-build"
            sqlite_build_dir.mkdir()
            configure = subprocess.run(
                [str(SQLITE_SOURCE / "configure"), "--disable-shared", "--enable-static"],
                cwd=sqlite_build_dir,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if configure.returncode:
                raise RuntimeError(f"SQLite configure failed:\n{configure.stdout[-4000:]}")
            build = subprocess.run(
                ["make", "-j2", "sqlite3"],
                cwd=sqlite_build_dir,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if build.returncode:
                raise RuntimeError(f"SQLite source build failed:\n{build.stdout[-4000:]}")
            sqlite_executable = sqlite_build_dir / "sqlite3"
        assert sqlite_executable is not None
        if not sqlite_executable.is_file():
            raise SystemExit(f"SQLite executable not found: {sqlite_executable}")
        for rows in args.rows:
            sql = workload(rows)
            sql_sha256 = hashlib.sha256(sql.encode("utf-8")).hexdigest()
            for repeat in range(1, args.repeat + 1):
                for engine, executable in (("sqzite", args.sqzite), ("sqlite", sqlite_executable)):
                    result = run_once(engine, executable, rows, repeat, temp_root, sql)
                    result["repeat"] = repeat
                    result["workload_sha256"] = sql_sha256
                    raw.append(result)

    timestamp = dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    raw_path = args.output_dir / f"raw-{timestamp}.json"
    summary_path = args.output_dir / f"summary-{timestamp}.csv"
    metadata = {
        "created_at": dt.datetime.now().astimezone().isoformat(),
        "sqzite_executable": str(args.sqzite),
        "sqlite_executable": str(args.sqlite) if args.sqlite else "built from repository SQLite source",
        "sqlite_source": str(SQLITE_SOURCE) if args.sqlite is None else None,
        "sqlite_source_version": (SQLITE_SOURCE / "VERSION").read_text(encoding="utf-8").strip() if args.sqlite is None else None,
        "sqlite_configure_command": "configure --disable-shared --enable-static" if args.sqlite is None else None,
        "sqlite_build_command": "make -j2 sqlite3" if args.sqlite is None else None,
        "rows": args.rows,
        "repeat": args.repeat,
        "sqzite_build_mode": args.build_mode,
        "method": "wall-clock process time; fresh database per sample; same CREATE TABLE and individual INSERT workload; SQLite wraps statements in one explicit transaction to match sqzite process-close batch flush; SQLite row count verified after timing",
        "measurements": raw,
    }
    raw_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    summaries = []
    for rows in args.rows:
        pair = {engine: [r["elapsed_seconds"] for r in raw if r["rows"] == rows and r["engine"] == engine] for engine in ("sqzite", "sqlite")}
        sqzite_median = statistics.median(pair["sqzite"])
        sqlite_median = statistics.median(pair["sqlite"])
        summaries.append({
            "rows": rows,
            "repeat": args.repeat,
            "sqzite_median_seconds": sqzite_median,
            "sqzite_rows_per_second": rows / sqzite_median,
            "sqlite_median_seconds": sqlite_median,
            "sqlite_rows_per_second": rows / sqlite_median,
            "sqlite_time_over_sqzite_time": sqlite_median / sqzite_median,
        })
    with summary_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=summaries[0].keys())
        writer.writeheader()
        writer.writerows(summaries)
    print(f"Raw measurements: {raw_path}")
    print(f"Summary: {summary_path}")
    for row in summaries:
        print(
            f"{row['rows']:>6} rows | sqzite {row['sqzite_median_seconds']:.4f}s | "
            f"SQLite {row['sqlite_median_seconds']:.4f}s | SQLite/sqzite time {row['sqlite_time_over_sqzite_time']:.2f}x"
        )


if __name__ == "__main__":
    main()
