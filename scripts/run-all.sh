#!/bin/bash
#
# End-to-end runner for the OS Parallel Project.
#
# Runs:
#  - build (release)
#  - Part 1 benchmarks (seq vs multithread)
#  - Part 2 scheduling tests (basic by default; realtime optional)
#  - Part 3 cluster/MPI (optional, controlled by flags)
#  - Part 4 I/O analysis
#
# Usage:
#   ./scripts/run-all.sh
#   ./scripts/run-all.sh --with-mpi
#   sudo ./scripts/run-all.sh --with-realtime --with-mpi
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

WITH_REALTIME=0
WITH_MPI=0
WITH_MPI_BENCH=0

usage() {
  cat <<'EOF'
Usage: ./scripts/run-all.sh [options]

Options:
  --with-realtime   Run real-time scheduling tests (SCHED_FIFO/RR). Often needs sudo.
  --with-mpi        Run MPI cluster setup + a sample MPI run (Docker-based).
  --with-mpi-bench  Run distributed benchmark (single vs TCP vs MPI if cluster is up).
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --with-realtime)
    WITH_REALTIME=1
    shift
    ;;
  --with-mpi)
    WITH_MPI=1
    shift
    ;;
  --with-mpi-bench)
    WITH_MPI_BENCH=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1"
    usage
    exit 1
    ;;
  esac
done

section() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
  echo ""
}

cd "$PROJECT_ROOT"

section "BUILD (release)"
cargo build --release

section "PART 1: Benchmark (Sequential vs Multithread)"
"$SCRIPT_DIR/benchmark.sh" all

section "PART 2: Scheduling (basic)"
"$SCRIPT_DIR/scheduler-test.sh" basic

if [[ "$WITH_REALTIME" -eq 1 ]]; then
  section "PART 2: Scheduling (realtime)"
  "$SCRIPT_DIR/scheduler-test.sh" realtime || true
fi

if [[ "$WITH_MPI" -eq 1 ]]; then
  section "PART 3: Cluster Setup (Docker MPI cluster)"
  "$SCRIPT_DIR/cluster-setup.sh" setup

  section "PART 3: MPI Run (sample)"
  "$SCRIPT_DIR/cluster-run.sh" mpi
fi

if [[ "$WITH_MPI_BENCH" -eq 1 ]]; then
  section "PART 3: Distributed Benchmark"
  "$SCRIPT_DIR/cluster-run.sh" benchmark
fi

section "PART 4: I/O Analysis"
"$SCRIPT_DIR/io-analysis.sh"

section "DONE"
echo "Artifacts generated under:"
echo "  - results/"
echo "  - results/io-raw/"
