#!/bin/bash
#
# Scheduler Testing Script
#
# Tests different CPU scheduling policies on Red Hat Enterprise Linux
# using the scheduler-sim application and system tools.
#
# Usage:
#   ./scheduler-test.sh              # Run all tests
#   ./scheduler-test.sh basic        # Run basic tests (no sudo)
#   ./scheduler-test.sh realtime     # Run real-time tests (requires sudo)
#   ./scheduler-test.sh analysis     # Run detailed analysis
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_ROOT/results"
SCHEDULER_BIN="$PROJECT_ROOT/target/release/scheduler-sim"

# Test parameters
THREADS=4
LIMIT=5000000
ITERATIONS=3
PRIORITIES=(1 25 50 75 99)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$RESULTS_DIR"

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# Check if binary exists
check_binary() {
  if [[ ! -f "$SCHEDULER_BIN" ]]; then
    log_info "Binary not found. Building project..."
    cd "$PROJECT_ROOT"
    cargo build --release
  fi
}

# Check system capabilities
check_system() {
  log_section "SYSTEM INFORMATION"

  echo "Kernel:"
  uname -r

  echo ""
  echo "CPU Scheduler:"
  if [[ -f /sys/block/sda/queue/scheduler ]]; then
    cat /sys/block/sda/queue/scheduler 2>/dev/null || echo "N/A"
  fi

  echo ""
  echo "Real-time limits (current user):"
  ulimit -r 2>/dev/null || echo "N/A"

  echo ""
  echo "Available scheduling policies:"
  if command -v chrt &>/dev/null; then
    chrt --max
  else
    echo "chrt not available"
  fi

  echo ""
  echo "Current process scheduling:"
  ps -o pid,ni,pri,policy,comm -p $$
}

# Run basic tests (no root required)
run_basic_tests() {
  log_section "BASIC SCHEDULING TESTS (SCHED_OTHER)"

  local output_file="$RESULTS_DIR/scheduler-basic.csv"

  log_info "Running SCHED_OTHER with different nice values..."
  echo ""

  # Header for CSV
  echo "policy,threads,priority,avg_wait_ms,avg_exec_ms,avg_turnaround_ms,wall_clock_ms,throughput" >"$output_file"

  # Test with default priority
  log_info "Testing SCHED_OTHER (default)..."
  "$SCHEDULER_BIN" \
    --policy other \
    --threads "$THREADS" \
    --limit "$LIMIT" \
    --iterations "$ITERATIONS" \
    --csv >>"$output_file"

  # Test with nice command (different priorities)
  for nice_val in 19 10 0; do
    log_info "Testing with nice value: $nice_val..."
    nice -n "$nice_val" "$SCHEDULER_BIN" \
      --policy other \
      --threads "$THREADS" \
      --limit "$LIMIT" \
      --iterations "$ITERATIONS" \
      --csv 2>/dev/null >>"$output_file" ||
      log_warn "nice $nice_val requires privileges, skipping"
  done

  echo ""
  log_info "Basic test results saved to: $output_file"

  # Display results
  echo ""
  echo "Results:"
  column -t -s',' "$output_file" 2>/dev/null || cat "$output_file"
}

# Run real-time scheduling tests (requires root)
run_realtime_tests() {
  log_section "REAL-TIME SCHEDULING TESTS"

  if [[ $EUID -ne 0 ]]; then
    log_warn "Real-time tests require root privileges."
    log_warn "Run with: sudo $0 realtime"

    # Try anyway with current user's RT limits
    log_info "Attempting with current user's real-time limits..."
  fi

  local output_file="$RESULTS_DIR/scheduler-realtime.csv"
  echo "policy,threads,priority,avg_wait_ms,avg_exec_ms,avg_turnaround_ms,wall_clock_ms,throughput" >"$output_file"

  # Test SCHED_FIFO with different priorities
  log_info "Testing SCHED_FIFO..."
  for priority in "${PRIORITIES[@]}"; do
    echo -n "  Priority $priority: "

    if [[ $EUID -eq 0 ]]; then
      chrt -f "$priority" "$SCHEDULER_BIN" \
        --policy fifo \
        --threads "$THREADS" \
        --priority "$priority" \
        --limit "$LIMIT" \
        --iterations "$ITERATIONS" \
        --csv >>"$output_file" 2>/dev/null && echo "✓" || echo "✗"
    else
      "$SCHEDULER_BIN" \
        --policy fifo \
        --threads "$THREADS" \
        --priority "$priority" \
        --limit "$LIMIT" \
        --iterations "$ITERATIONS" \
        --csv >>"$output_file" 2>/dev/null && echo "✓" || echo "✗ (needs sudo)"
    fi
  done

  echo ""

  # Test SCHED_RR with different priorities
  log_info "Testing SCHED_RR..."
  for priority in "${PRIORITIES[@]}"; do
    echo -n "  Priority $priority: "

    if [[ $EUID -eq 0 ]]; then
      chrt -r "$priority" "$SCHEDULER_BIN" \
        --policy rr \
        --threads "$THREADS" \
        --priority "$priority" \
        --limit "$LIMIT" \
        --iterations "$ITERATIONS" \
        --csv >>"$output_file" 2>/dev/null && echo "✓" || echo "✗"
    else
      "$SCHEDULER_BIN" \
        --policy rr \
        --threads "$THREADS" \
        --priority "$priority" \
        --limit "$LIMIT" \
        --iterations "$ITERATIONS" \
        --csv >>"$output_file" 2>/dev/null && echo "✓" || echo "✗ (needs sudo)"
    fi
  done

  echo ""
  log_info "Real-time test results saved to: $output_file"

  # Display results if file has content
  if [[ -s "$output_file" ]]; then
    echo ""
    echo "Results:"
    column -t -s',' "$output_file" 2>/dev/null || cat "$output_file"
  fi
}

# Run comprehensive comparison
run_comparison() {
  log_section "POLICY COMPARISON"

  local output_file="$RESULTS_DIR/scheduler-comparison.csv"

  log_info "Running all policies for comparison..."
  echo ""

  # Use the built-in --policy all option
  if [[ $EUID -eq 0 ]]; then
    "$SCHEDULER_BIN" \
      --policy all \
      --threads "$THREADS" \
      --priority 50 \
      --limit "$LIMIT" \
      --iterations "$ITERATIONS" \
      --verbose
  else
    "$SCHEDULER_BIN" \
      --policy all \
      --threads "$THREADS" \
      --priority 50 \
      --limit "$LIMIT" \
      --iterations "$ITERATIONS" \
      --verbose 2>&1
  fi

  # Save CSV version
  if [[ $EUID -eq 0 ]]; then
    "$SCHEDULER_BIN" \
      --policy all \
      --threads "$THREADS" \
      --priority 50 \
      --limit "$LIMIT" \
      --iterations "$ITERATIONS" \
      --csv >"$output_file" 2>/dev/null
  else
    "$SCHEDULER_BIN" \
      --policy all \
      --threads "$THREADS" \
      --priority 50 \
      --limit "$LIMIT" \
      --iterations "$ITERATIONS" \
      --csv >"$output_file" 2>/dev/null || true
  fi

  log_info "Comparison results saved to: $output_file"
}

# Monitor scheduling in real-time
run_monitoring() {
  log_section "REAL-TIME SCHEDULING MONITOR"

  log_info "Starting scheduler-sim in background and monitoring..."
  echo ""

  # Start the application in background
  "$SCHEDULER_BIN" \
    --policy other \
    --threads 8 \
    --limit 10000000 \
    --iterations 5 &

  local pid=$!

  echo "Application PID: $pid"
  echo ""

  # Monitor for a few seconds
  echo "Thread scheduling info (sampled every 0.5s):"
  echo ""

  for _ in {1..10}; do
    if ps -p $pid >/dev/null 2>&1; then
      echo "--- $(date +%H:%M:%S.%N | cut -c1-12) ---"
      ps -L -o pid,lwp,ni,pri,policy,stat,pcpu,comm -p $pid 2>/dev/null | head -10
      echo ""
      sleep 0.5
    else
      break
    fi
  done

  # Wait for completion
  wait $pid 2>/dev/null || true

  log_info "Monitoring complete"
}

# Demonstrate chrt and taskset
run_tools_demo() {
  log_section "LINUX SCHEDULING TOOLS DEMONSTRATION"

  echo "1. chrt - Change real-time attributes of a process"
  echo "   ─────────────────────────────────────────────────"
  echo ""
  echo "   Show current scheduling policy:"
  echo "   \$ chrt -p \$\$"
  chrt -p $$ 2>/dev/null || echo "   (requires chrt)"
  echo ""

  echo "   Show max priorities:"
  echo "   \$ chrt --max"
  chrt --max 2>/dev/null || echo "   (requires chrt)"
  echo ""

  echo "2. nice/renice - Adjust process priority"
  echo "   ─────────────────────────────────────────────────"
  echo ""
  echo "   Current nice value:"
  echo "   \$ nice"
  nice
  echo ""

  echo "   Run command with nice value 10:"
  echo "   \$ nice -n 10 command"
  echo ""

  echo "3. taskset - Set CPU affinity"
  echo "   ─────────────────────────────────────────────────"
  echo ""
  echo "   Show current CPU affinity:"
  echo "   \$ taskset -p \$\$"
  taskset -p $$ 2>/dev/null || echo "   (requires taskset)"
  echo ""

  echo "4. Process priority in /proc"
  echo "   ─────────────────────────────────────────────────"
  echo ""
  echo "   \$ cat /proc/\$\$/sched | head -10"
  cat /proc/$$/sched 2>/dev/null | head -10 || echo "   (not available)"
  echo ""
}

# Generate analysis report
generate_report() {
  log_section "GENERATING ANALYSIS REPORT"

  local report_file="$RESULTS_DIR/scheduler-analysis-report.md"

  cat >"$report_file" <<'EOF'
# Scheduling Policy Analysis Report

## Test Configuration

| Parameter | Value |
|-----------|-------|
EOF

  echo "| Threads | $THREADS |" >>"$report_file"
  echo "| Prime Limit | $LIMIT |" >>"$report_file"
  echo "| Iterations | $ITERATIONS |" >>"$report_file"
  echo "| Date | $(date) |" >>"$report_file"
  echo "| Kernel | $(uname -r) |" >>"$report_file"

  cat >>"$report_file" <<'EOF'

## Results Summary

### Basic Tests (SCHED_OTHER)

EOF

  if [[ -f "$RESULTS_DIR/scheduler-basic.csv" ]]; then
    echo '```' >>"$report_file"
    column -t -s',' "$RESULTS_DIR/scheduler-basic.csv" >>"$report_file" 2>/dev/null ||
      cat "$RESULTS_DIR/scheduler-basic.csv" >>"$report_file"
    echo '```' >>"$report_file"
  else
    echo "No basic test results found." >>"$report_file"
  fi

  cat >>"$report_file" <<'EOF'

### Real-time Tests (SCHED_FIFO, SCHED_RR)

EOF

  if [[ -f "$RESULTS_DIR/scheduler-realtime.csv" ]]; then
    echo '```' >>"$report_file"
    column -t -s',' "$RESULTS_DIR/scheduler-realtime.csv" >>"$report_file" 2>/dev/null ||
      cat "$RESULTS_DIR/scheduler-realtime.csv" >>"$report_file"
    echo '```' >>"$report_file"
  else
    echo "No real-time test results found. (Requires sudo)" >>"$report_file"
  fi

  cat >>"$report_file" <<'EOF'

## Analysis

### SCHED_OTHER (CFS - Completely Fair Scheduler)
- Default Linux scheduler for normal processes
- Uses "nice" values (-20 to 19) for priority adjustment
- Provides fair CPU time distribution among processes
- Suitable for general-purpose workloads

### SCHED_FIFO (First-In-First-Out)
- Real-time scheduling policy
- Highest priority thread runs until it blocks or yields
- No time slicing - runs until completion
- Suitable for time-critical applications

### SCHED_RR (Round-Robin)
- Real-time scheduling policy with time slicing
- Similar to FIFO but with time quantum
- Threads of equal priority share CPU time
- Suitable for real-time applications needing fairness

## Recommendations

1. **General workloads**: Use SCHED_OTHER (default)
2. **Latency-sensitive**: Consider SCHED_FIFO with appropriate priority
3. **Real-time with fairness**: Use SCHED_RR
4. **Always test** before deploying real-time policies in production

EOF

  log_info "Report saved to: $report_file"
}

# Main
main() {
  local mode="${1:-all}"

  check_binary

  case "$mode" in
  basic)
    check_system
    run_basic_tests
    ;;
  realtime | rt)
    check_system
    run_realtime_tests
    ;;
  compare)
    check_system
    run_comparison
    ;;
  monitor)
    run_monitoring
    ;;
  tools)
    run_tools_demo
    ;;
  analysis)
    check_system
    run_basic_tests
    run_realtime_tests
    run_comparison
    generate_report
    ;;
  all)
    check_system
    run_basic_tests
    run_realtime_tests
    run_comparison
    run_tools_demo
    generate_report
    ;;
  *)
    echo "Usage: $0 {basic|realtime|compare|monitor|tools|analysis|all}"
    echo ""
    echo "Modes:"
    echo "  basic     - Run SCHED_OTHER tests (no sudo required)"
    echo "  realtime  - Run SCHED_FIFO/RR tests (sudo recommended)"
    echo "  compare   - Run all policies comparison"
    echo "  monitor   - Monitor scheduling in real-time"
    echo "  tools     - Demonstrate Linux scheduling tools"
    echo "  analysis  - Full analysis with report generation"
    echo "  all       - Run everything"
    exit 1
    ;;
  esac
}

main "$@"
