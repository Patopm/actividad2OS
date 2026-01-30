# Part 4: I/O Devices and I/O Management Report (RHEL)

Generated: Thu Jan 29 09:23:31 CST 2026

## Host / OS

```text
# Command: bash -c cat /etc/redhat-release 2>/dev/null || true; uname -a
# Date: Thu Jan 29 09:23:31 CST 2026

Darwin Patricios-MacBook-Air.local 25.2.0 Darwin Kernel Version 25.2.0: Tue Nov 18 21:08:48 PST 2025; root:xnu-12377.61.12~1/RELEASE_ARM64_T8132 arm64
```

## I/O Devices Used by This Project

### Application Inputs
- CLI parameters (limit, threads, policy)
- (Optional) Hostfile for MPI runs: `apps/primes-mpi/hostfile`
- (Optional) Log/CSV outputs produced under `results/`

### Application Outputs
- STDOUT/STDERR (terminal)
- Benchmark CSV files under `results/`
- Scheduling reports under `results/`
- Cluster benchmark CSV under `results/`

> Note: Prime calculation is primarily CPU-bound. I/O is minimal and mainly related
> to logging and writing benchmark results.

## Block Devices

```text
# Command: lsblk -a -o NAME,KNAME,TYPE,SIZE,ROTA,MOUNTPOINTS,FSTYPE,MODEL,SERIAL
# Date: Thu Jan 29 09:23:31 CST 2026

scripts/io-analysis.sh: line 58: lsblk: command not found
```

## Filesystems / Mounts

```text
# Command: df -hT
# Date: Thu Jan 29 09:23:31 CST 2026

df: option requires an argument -- T
usage: df [--libxo] [-b | -g | -H | -h | -k | -m | -P] [-acIilnY] [-,] [-T type] [-t type]
          [file | filesystem ...]
```

## PCI Devices (storage/network controllers)

```text
lspci not available
```

## USB Devices (if any)

```text
# Command: lsusb -v
# Date: Thu Jan 29 09:23:31 CST 2026
```

## Interrupts and IRQs (I/O by Interrupts)

```text
# Command: bash -c cat /proc/interrupts 2>/dev/null || true
# Date: Thu Jan 29 09:23:31 CST 2026
```

## I/O Queue / Scheduler Settings (per block device)

```text
# Command: bash -c 
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
  
# Date: Thu Jan 29 09:23:31 CST 2026
```

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

```text
# Command: iostat -xz 1 3
# Date: Thu Jan 29 09:23:31 CST 2026

iostat: illegal option -- x
usage: iostat [-CUdIKoT?] [-c count] [-n devs]
	      [-w wait] [drives]
```

### vmstat

```text
vmstat not available
```

---

## Raw Outputs
All raw command outputs are stored under:
- `results/io-raw/`

