# Part 2: Process Scheduling Algorithms in Red Hat Enterprise Linux

## Algorithm Selection

### 1. SCHED_OTHER (CFS - Completely Fair Scheduler)

The default Linux scheduler for normal (non-real-time) processes.

**Characteristics:**
- Uses a red-black tree to manage runnable processes
- Provides fair CPU time distribution based on "nice" values
- Time slice is dynamically calculated based on system load
- Priority range: nice values from -20 (highest) to 19 (lowest)

**Algorithm:**
```text
1. Each process has a "virtual runtime" (vruntime)
2. Scheduler always picks process with lowest vruntime
3. When process runs, its vruntime increases
4. Nice value affects how fast vruntime increases:
   - Lower nice = slower vruntime increase = more CPU time
   - Higher nice = faster vruntime increase = less CPU time
```

**Use Cases:**
- General-purpose computing
- Desktop applications
- Web servers
- Most workloads

### 2. SCHED_FIFO (First-In-First-Out Real-Time)

A real-time scheduling policy without time slicing.

**Characteristics:**
- Strict priority-based scheduling
- No time quantum - runs until blocks, yields, or preempted
- Priority range: 1 (lowest) to 99 (highest)
- Higher priority always preempts lower priority
- Requires root privileges or CAP_SYS_NICE

**Algorithm:**
```text
1. Maintain queue for each priority level (1-99)
2. Always run highest priority runnable thread
3. Thread runs until:
   - It blocks (I/O, sleep, mutex)
   - It explicitly yields (sched_yield)
   - Higher priority thread becomes runnable
4. When thread becomes runnable, add to END of its priority queue
```

**Use Cases:**
- Hard real-time systems
- Audio/video processing
- Industrial control systems
- Latency-critical applications

### 3. SCHED_RR (Round-Robin Real-Time)

A real-time scheduling policy with time slicing.

**Characteristics:**
- Similar to FIFO but with time quantum
- Processes of equal priority share CPU in round-robin fashion
- Default time slice: typically 100ms (configurable)
- Priority range: 1 (lowest) to 99 (highest)
- Requires root privileges or CAP_SYS_NICE

**Algorithm:**
```text
1. Same priority queues as FIFO
2. When thread exhausts its time slice:
   - Move to END of its priority queue
   - Give CPU to next thread in queue
3. Higher priority always preempts lower priority
```

**Use Cases:**
- Soft real-time systems
- Multiple real-time tasks of equal importance
- Gaming and multimedia

## Justification for Selection

| Algorithm | Justification |
|-----------|---------------|
| SCHED_OTHER | Baseline comparison; default for most Linux systems |
| SCHED_FIFO | Demonstrates real-time scheduling without preemption |
| SCHED_RR | Shows real-time scheduling with fairness among equals |

These three policies cover:
- Normal time-sharing (SCHED_OTHER)
- Non-preemptive real-time (SCHED_FIFO)
- Preemptive real-time with fairness (SCHED_RR)

## Implementation in Red Hat Enterprise Linux

### Method 1: Using `sched_setscheduler()` in Code

```rust
use libc::{sched_param, sched_setscheduler, SCHED_FIFO, SCHED_RR, SCHED_OTHER};

fn set_scheduling_policy(policy: i32, priority: i32) -> Result<(), String> {
    let param = sched_param {
        sched_priority: priority,
    };
    
    // 0 = current process
    let result = unsafe { sched_setscheduler(0, policy, &param) };
    
    if result == -1 {
        Err(format!("Failed: {}", std::io::Error::last_os_error()))
    } else {
        Ok(())
    }
}
```

### Method 2: Using `chrt` Command

```bash
# Show current policy
chrt -p $$

# Run with SCHED_FIFO, priority 50
sudo chrt -f 50 ./my_application

# Run with SCHED_RR, priority 25
sudo chrt -r 25 ./my_application

# Change running process
sudo chrt -f -p 50 <PID>
```

### Method 3: Using `nice` and `renice`

```bash
# Run with nice value 10 (lower priority)
nice -n 10 ./my_application

# Run with nice value -10 (higher priority, requires root)
sudo nice -n -10 ./my_application

# Change running process
renice -n 5 -p <PID>
sudo renice -n -5 -p <PID>
```

### Method 4: Using `taskset` for CPU Affinity

```bash
# Run on CPU 0 only
taskset -c 0 ./my_application

# Run on CPUs 0-3
taskset -c 0-3 ./my_application

# Show current affinity
taskset -p $$
```

## System Configuration

### Enabling Real-Time Scheduling for Non-Root Users

Edit `/etc/security/limits.conf`:

```text
# Allow users in 'realtime' group to use RT scheduling
@realtime    soft    rtprio    99
@realtime    hard    rtprio    99
@realtime    soft    memlock   unlimited
@realtime    hard    memlock   unlimited
```

Then add user to the group:

```bash
sudo groupadd realtime
sudo usermod -a -G realtime $USER
# Log out and back in
```

### Checking Available Priorities

```bash
# Show min/max priorities for each policy
chrt --max

# Output:
# SCHED_OTHER min/max priority    : 0/0
# SCHED_FIFO min/max priority     : 1/99
# SCHED_RR min/max priority       : 1/99
```

### Viewing Process Scheduling Information

```bash
# Using ps
ps -o pid,ni,pri,policy,comm -p <PID>

# Using /proc
cat /proc/<PID>/sched

# Real-time priorities
cat /proc/<PID>/stat | awk '{print "Priority:", $18, "Nice:", $19}'
```

## Running the Tests

### Basic Tests (No Root Required)

```bash
# Run SCHED_OTHER tests
pnpm run scheduler:test basic

# Or directly
./scripts/scheduler-test.sh basic
```

### Real-Time Tests (Root Required)

```bash
# Run with sudo
sudo pnpm run scheduler:test realtime

# Or directly
sudo ./scripts/scheduler-test.sh realtime
```

### Full Analysis

```bash
# Run all tests and generate report
sudo ./scripts/scheduler-test.sh analysis
```

## Metrics Explanation

| Metric | Description |
|--------|-------------|
| **Wait Time** | Time from thread creation to first execution |
| **Execution Time** | Time spent actually computing |
| **Turnaround Time** | Total time from creation to completion |
| **Throughput** | Primes calculated per second |

## Expected Results Analysis

### SCHED_OTHER vs Real-Time

```text
┌─────────────────────────────────────────────────────────────────────┐
│                    Expected Behavior                                 │
├─────────────────────────────────────────────────────────────────────┤
│ SCHED_OTHER:                                                        │
│   - Fair distribution among threads                                  │
│   - Moderate latency variation                                       │
│   - Good for throughput-oriented workloads                          │
│                                                                      │
│ SCHED_FIFO:                                                         │
│   - Lowest latency for high-priority threads                        │
│   - Risk of priority inversion without proper design                │
│   - Best for single critical thread                                  │
│                                                                      │
│ SCHED_RR:                                                           │
│   - Fair among same-priority real-time threads                      │
│   - Bounded latency due to time slicing                             │
│   - Good for multiple real-time threads                             │
└─────────────────────────────────────────────────────────────────────┘
```

### Priority Impact

```text
Higher Priority (RT 99) ──► Lower wait time, higher throughput
                  │
                  │
Lower Priority (RT 1)  ──► Higher wait time, may be starved
```

## Sample Results

```text
═══════════════════════════════════════════════════════════
                    COMPARISON SUMMARY
═══════════════════════════════════════════════════════════

        Policy     Wait(ms)     Exec(ms)   Turn.(ms)   Throughput
─────────────────────────────────────────────────────────────────
   SCHED_OTHER        1.234      245.678      246.912      2034521
    SCHED_FIFO        0.456      242.123      242.579      2065432
      SCHED_RR        0.512      243.456      243.968      2054321

✓ Lowest wait time: SCHED_FIFO (0.456 ms)
✓ Highest throughput: SCHED_FIFO (2065432 primes/s)
```

## Conclusion

The scheduling policy affects:

1. **Latency**: Real-time policies provide lower and more predictable latency
2. **Fairness**: SCHED_OTHER and SCHED_RR ensure fair sharing
3. **Throughput**: Generally similar for CPU-bound tasks
4. **Predictability**: Real-time policies offer more deterministic behavior

For our prime calculation workload:
- **SCHED_OTHER** is sufficient for general use
- **SCHED_FIFO** is best for single-threaded critical sections
- **SCHED_RR** is ideal for multi-threaded real-time applications
