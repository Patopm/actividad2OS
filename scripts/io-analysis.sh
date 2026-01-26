#!/bin/bash
#
# I/O Device Identification and OS I/O Management Analysis (RHEL)
#
# Collects system information relevant to I/O devices and the I/O stack:
# - Block devices (disks, partitions)
# - PCI/USB devices
# - Filesystems and mounts
# - Interrupts and IRQ affinity
# - Basic I/O performance stats (iostat) when available
#
# Output:
# - results/io-analysis-report.md
# - results/io-raw/*.txt (raw command outputs)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_ROOT/results"
RAW_DIR="$RESULTS_DIR/io-raw"
REPORT="$RESULTS_DIR/io-analysis-report.md"

mkdir -p "$RESULTS_DIR" "$RAW_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

run_cmd() {
  local name="$1"
  shift
  local out="$RAW_DIR/$name.txt"

  {
    echo "# Command: $*"
    echo "# Date: $(date)"
    echo ""
    "$@"
  } >"$out" 2>&1 || true
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

main() {
  log_section "COLLECTING I/O INFORMATION"

  log_info "Collecting OS and kernel info..."
  run_cmd "os-release" bash -c "cat /etc/redhat-release 2>/dev/null || true; uname -a"
  run_cmd "kernel-cmdline" bash -c "cat /proc/cmdline 2>/dev/null || true"

  log_info "Collecting block device and filesystem info..."
  run_cmd "lsblk" lsblk -a -o NAME,KNAME,TYPE,SIZE,ROTA,MOUNTPOINTS,FSTYPE,MODEL,SERIAL
  run_cmd "blkid" bash -c "blkid 2>/dev/null || true"
  run_cmd "df" df -hT
  run_cmd "mount" mount
  run_cmd "findmnt" bash -c "findmnt -a 2>/dev/null || true"

  log_info "Collecting PCI/USB device info..."
  if have_cmd lspci; then
    run_cmd "lspci" lspci -nnk
  else
    log_warn "lspci not found (install pciutils)."
  fi

  if have_cmd lsusb; then
    run_cmd "lsusb" lsusb -v
  else
    log_warn "lsusb not found (install usbutils)."
  fi

  log_info "Collecting kernel messages about storage and USB..."
  run_cmd "dmesg-storage-usb" bash -c "dmesg -T 2>/dev/null | egrep -i 'nvme|scsi|ata|sd[a-z]|usb|xhci|ehci' | tail -n 200 || true"

  log_info "Collecting interrupts and IRQ info..."
  run_cmd "proc-interrupts" bash -c "cat /proc/interrupts 2>/dev/null || true"
  run_cmd "proc-softirqs" bash -c "cat /proc/softirqs 2>/dev/null || true"
  run_cmd "irqbalance-status" bash -c "systemctl status irqbalance --no-pager 2>/dev/null || true"

  log_info "Collecting I/O scheduler / queue settings (where available)..."
  run_cmd "block-queue-schedulers" bash -c '
    for dev in /sys/block/*; do
      d=$(basename "$dev")
      if [[ -f "$dev/queue/scheduler" ]]; then
        echo "$d scheduler: $(cat "$dev/queue/scheduler")"
      fi
      if [[ -f "$dev/queue/rotational" ]]; then
        echo "$d rotational: $(cat "$dev/queue/rotational")"
      fi
      if [[ -f "$dev/queue/nr_requests" ]]; then
        echo "$d nr_requests: $(cat "$dev/queue/nr_requests")"
      fi
      echo ""
    done
  '

  log_info "Collecting basic live I/O stats (optional)..."
  if have_cmd iostat; then
    run_cmd "iostat" iostat -xz 1 3
  else
    log_warn "iostat not found (install sysstat). Skipping."
  fi

  if have_cmd vmstat; then
    run_cmd "vmstat" vmstat 1 5
  fi

  if have_cmd pidstat; then
    run_cmd "pidstat" pidstat -dru 1 3
  fi

  log_info "Collecting process/file descriptor snapshot..."
  if have_cmd lsof; then
    run_cmd "lsof-top" bash -c "lsof -nP 2>/dev/null | head -n 200 || true"
  else
    log_warn "lsof not found (install lsof). Skipping."
  fi

  log_section "GENERATING REPORT"

  cat >"$REPORT" <<EOF
# Part 4: I/O Devices and I/O Management Report (RHEL)

Generated: $(date)

## Host / OS

\`\`\`text
$(cat "$RAW_DIR/os-release.txt")
\`\`\`

## I/O Devices Used by This Project

### Application Inputs
- CLI parameters (limit, threads, policy)
- (Optional) Hostfile for MPI runs: \`apps/primes-mpi/hostfile\`
- (Optional) Log/CSV outputs produced under \`results/\`

### Application Outputs
- STDOUT/STDERR (terminal)
- Benchmark CSV files under \`results/\`
- Scheduling reports under \`results/\`
- Cluster benchmark CSV under \`results/\`

> Note: Prime calculation is primarily CPU-bound. I/O is minimal and mainly related
> to logging and writing benchmark results.

## Block Devices

\`\`\`text
$(cat "$RAW_DIR/lsblk.txt")
\`\`\`

## Filesystems / Mounts

\`\`\`text
$(cat "$RAW_DIR/df.txt")
\`\`\`

## PCI Devices (storage/network controllers)

\`\`\`text
$(if [[ -f "$RAW_DIR/lspci.txt" ]]; then cat "$RAW_DIR/lspci.txt"; else echo "lspci not available"; fi)
\`\`\`

## USB Devices (if any)

\`\`\`text
$(if [[ -f "$RAW_DIR/lsusb.txt" ]]; then head -n 200 "$RAW_DIR/lsusb.txt"; else echo "lsusb not available"; fi)
\`\`\`

## Interrupts and IRQs (I/O by Interrupts)

\`\`\`text
$(head -n 200 "$RAW_DIR/proc-interrupts.txt")
\`\`\`

## I/O Queue / Scheduler Settings (per block device)

\`\`\`text
$(cat "$RAW_DIR/block-queue-schedulers.txt")
\`\`\`

## OS I/O Organization Techniques (Conceptual)

### Programmed I/O (PIO)
- CPU actively polls device registers and moves data itself.
- High CPU overhead, low throughput.

### Interrupt-driven I/O
- Device interrupts CPU when it needs attention (completion, data ready).
- CPU is free to do other work between interrupts.
- Common for many device operations, especially with buffering.

### Direct Memory Access (DMA)
- Device (via DMA engine) transfers data directly to/from memory.
- CPU initiates transfer and handles completion interrupt.
- Highest throughput and lowest CPU overhead for bulk transfers.

## Which Technique Fits This Project Best?

- The prime computation itself is CPU-bound, so the main bottleneck is not I/O.
- For writing benchmark results and logs, typical buffered file I/O is efficient.
- Under the hood, storage devices use **DMA** for block transfers and
  **interrupts** for completion signaling.

**Most efficient overall approach for our workload:**
- Use buffered file I/O (append CSV results), avoid excessive logging.
- Prefer fewer, larger writes instead of many tiny writes.

## Optional Live I/O Stats

### iostat

\`\`\`text
$(if [[ -f "$RAW_DIR/iostat.txt" ]]; then cat "$RAW_DIR/iostat.txt"; else echo "iostat not available"; fi)
\`\`\`

### vmstat

\`\`\`text
$(if [[ -f "$RAW_DIR/vmstat.txt" ]]; then cat "$RAW_DIR/vmstat.txt"; else echo "vmstat not available"; fi)
\`\`\`

---

## Raw Outputs
All raw command outputs are stored under:
- \`results/io-raw/\`

EOF

  log_info "Report written to: $REPORT"
  log_info "Raw outputs stored in: $RAW_DIR"
}

main "$@"
