#!/bin/bash
#
# Benchmark script for comparing sequential vs multithreaded prime calculation
#
# Usage:
#   ./benchmark.sh sequential    # Run only sequential benchmarks
#   ./benchmark.sh multithread   # Run only multithreaded benchmarks
#   ./benchmark.sh all           # Run both and compare
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_ROOT/results"
SEQUENTIAL_BIN="$PROJECT_ROOT/target/release/primes-sequential"
MULTITHREAD_BIN="$PROJECT_ROOT/target/release/primes-multithread"

# Benchmark parameters
LIMIT=10000000
THREAD_COUNTS=(1 2 4 8)
ITERATIONS=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# Check if binaries exist
check_binaries() {
  if [[ ! -f "$SEQUENTIAL_BIN" ]] || [[ ! -f "$MULTITHREAD_BIN" ]]; then
    log_info "Binaries not found. Building project..."
    cd "$PROJECT_ROOT"
    cargo build --release
  fi
}

# Run sequential benchmark
run_sequential_benchmark() {
  log_section "SEQUENTIAL BENCHMARK"

  local output_file="$RESULTS_DIR/benchmark-sequential.csv"
  echo "limit,threads,time_ms,prime_count,iteration" >"$output_file"

  log_info "Running $ITERATIONS iterations with limit=$LIMIT"
  echo ""

  local total_time=0

  for i in $(seq 1 $ITERATIONS); do
    echo -n "  Iteration $i/$ITERATIONS: "

    # Run and capture CSV output
    result=$("$SEQUENTIAL_BIN" --limit "$LIMIT" --csv)

    # Parse time from result
    time_ms=$(echo "$result" | cut -d',' -f3)
    prime_count=$(echo "$result" | cut -d',' -f4)

    echo "${time_ms} ms (found $prime_count primes)"

    # Save to CSV with iteration number
    echo "$LIMIT,1,$time_ms,$prime_count,$i" >>"$output_file"

    total_time=$(echo "$total_time + $time_ms" | bc)
  done

  avg_time=$(echo "scale=3; $total_time / $ITERATIONS" | bc)
  echo ""
  log_info "Average time: ${avg_time} ms"
  log_info "Results saved to: $output_file"

  # Return average time for comparison
  echo "$avg_time" >"$RESULTS_DIR/.seq_avg_time"
}

# Run multithreaded benchmark
run_multithread_benchmark() {
  log_section "MULTITHREADED BENCHMARK"

  local output_file="$RESULTS_DIR/benchmark-multithread.csv"
  echo "limit,threads,time_ms,prime_count,iteration" >"$output_file"

  for threads in "${THREAD_COUNTS[@]}"; do
    log_info "Running with $threads thread(s)..."

    local total_time=0

    for i in $(seq 1 $ITERATIONS); do
      echo -n "  Iteration $i/$ITERATIONS: "

      result=$("$MULTITHREAD_BIN" --limit "$LIMIT" --threads "$threads" --csv)

      time_ms=$(echo "$result" | cut -d',' -f3)
      prime_count=$(echo "$result" | cut -d',' -f4)

      echo "${time_ms} ms"

      echo "$LIMIT,$threads,$time_ms,$prime_count,$i" >>"$output_file"

      total_time=$(echo "$total_time + $time_ms" | bc)
    done

    avg_time=$(echo "scale=3; $total_time / $ITERATIONS" | bc)
    echo -e "  ${CYAN}Average ($threads threads): ${avg_time} ms${NC}"
    echo ""

    # Save average for comparison
    echo "$avg_time" >"$RESULTS_DIR/.mt_avg_time_$threads"
  done

  log_info "Results saved to: $output_file"
}

# Generate comparison report
generate_comparison() {
  log_section "PERFORMANCE COMPARISON"

  local report_file="$RESULTS_DIR/comparison-report.txt"

  # Get sequential average
  local seq_time
  if [[ -f "$RESULTS_DIR/.seq_avg_time" ]]; then
    seq_time=$(cat "$RESULTS_DIR/.seq_avg_time")
    seq_time=${seq_time/,/.}
    sec_time=$(echo $seq_time | tr -d '[:space:]')
  else
    echo "Sequential benchmark results not found. Run 'benchmark.sh sequential' first."
    return 1
  fi

  {
    echo "════════════════════════════════════════════════════════════"
    echo "           PRIME CALCULATION BENCHMARK REPORT"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Configuration:"
    echo "  Range: 2 to $LIMIT"
    echo "  Iterations per test: $ITERATIONS"
    echo "  Date: $(date)"
    echo ""
    echo "────────────────────────────────────────────────────────────"
    echo "                      RESULTS"
    echo "────────────────────────────────────────────────────────────"
    echo ""
    printf "%-15s %15s %15s %15s\n" "Mode" "Avg Time (ms)" "Speedup" "Efficiency"
    printf "%-15s %15s %15s %15s\n" "───────────────" "───────────────" "───────────────" "───────────────"
    LC_NUMERIC=C printf "%-15s %15.3f %15s %15s\n" "Sequential" "$seq_time" "1.00x" "100%"
  } >"$report_file"

  # Print header to console
  echo ""
  printf "%-15s %15s %15s %15s\n" "Mode" "Avg Time (ms)" "Speedup" "Efficiency"
  printf "%-15s %15s %15s %15s\n" "───────────────" "───────────────" "───────────────" "───────────────"
  printf "%-15s %15.3f %15s %15s\n" "Sequential" "$seq_time" "1.00x" "100%"

  for threads in "${THREAD_COUNTS[@]}"; do
    if [[ -f "$RESULTS_DIR/.mt_avg_time_$threads" ]]; then
      local mt_time
      mt_time=$(cat "$RESULTS_DIR/.mt_avg_time_$threads")

      # Calculate speedup: sequential_time / parallel_time
      local speedup
      speedup=$(echo "scale=2; $seq_time / $mt_time" | bc)

      # Calculate efficiency: (speedup / threads) * 100
      local efficiency
      efficiency=$(echo "scale=1; ($speedup / $threads) * 100" | bc)

      printf "%-15s %15.3f %14.2fx %14.1f%%\n" "$threads threads" "$mt_time" "$speedup" "$efficiency"
      printf "%-15s %15.3f %14.2fx %14.1f%%\n" "$threads threads" "$mt_time" "$speedup" "$efficiency" >>"$report_file"
    fi
  done

  {
    echo ""
    echo "────────────────────────────────────────────────────────────"
    echo "                      ANALYSIS"
    echo "────────────────────────────────────────────────────────────"
    echo ""
    echo "Speedup = Sequential Time / Parallel Time"
    echo "Efficiency = (Speedup / Thread Count) × 100%"
    echo ""
    echo "Notes:"
    echo "- Efficiency > 100% can occur due to cache effects"
    echo "- Efficiency < 100% is normal due to thread overhead"
    echo "- Optimal thread count depends on CPU cores and workload"
    echo ""
    echo "════════════════════════════════════════════════════════════"
  } >>"$report_file"

  echo ""
  log_info "Report saved to: $report_file"

  # Cleanup temp files
  rm -f "$RESULTS_DIR"/.seq_avg_time "$RESULTS_DIR"/.mt_avg_time_*
}

# Show system info
show_system_info() {
  log_section "SYSTEM INFORMATION"

  echo "CPU Information:"
  if [[ -f /proc/cpuinfo ]]; then
    echo "  Model: $(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
    echo "  Cores: $(grep -c "processor" /proc/cpuinfo)"
    echo "  Threads per core: $(lscpu 2>/dev/null | grep "Thread(s) per core" | cut -d':' -f2 | xargs || echo "N/A")"
  else
    echo "  Unable to read CPU info"
  fi

  echo ""
  echo "Memory:"
  if command -v free &>/dev/null; then
    free -h | grep "Mem:" | awk '{print "  Total: " $2 ", Available: " $7}'
  fi

  echo ""
  echo "OS:"
  if [[ -f /etc/redhat-release ]]; then
    echo "  $(cat /etc/redhat-release)"
  else
    uname -a
  fi
  echo ""
}

# Main
main() {
  local mode="${1:-all}"

  check_binaries
  show_system_info

  case "$mode" in
  sequential | seq)
    run_sequential_benchmark
    ;;
  multithread | mt)
    run_multithread_benchmark
    ;;
  all)
    run_sequential_benchmark
    run_multithread_benchmark
    generate_comparison
    ;;
  compare)
    generate_comparison
    ;;
  *)
    echo "Usage: $0 {sequential|multithread|all|compare}"
    exit 1
    ;;
  esac
}

main "$@"
