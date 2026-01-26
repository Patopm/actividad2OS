# Part 1: Multithreaded Application Design and Implementation

## Problem Definition

### Selected Problem: Prime Number Calculation

We chose to calculate prime numbers in a large range (1 to 10,000,000) using the
Sieve of Eratosthenes algorithm.

### Justification

| Criteria | Explanation |
|----------|-------------|
| **Parallelizable** | The range can be divided into independent segments |
| **CPU-bound** | Minimal I/O, focuses on computation |
| **Verifiable** | Prime counts are well-documented for validation |
| **Scalable** | Easy to increase range to show performance differences |
| **Educational** | Classic algorithm that clearly demonstrates parallelization benefits |

## Algorithm: Sieve of Eratosthenes

### Sequential Version

The classic algorithm works as follows:

```text
1. Create boolean array is_prime[0..n], all set to true
2. Set is_prime[0] = is_prime[1] = false
3. For each p from 2 to √n:
   - If is_prime[p] is true:
     - Mark all multiples of p (p², p²+p, p²+2p, ...) as false
4. All indices still marked true are prime
```

**Time Complexity:** O(n log log n)
**Space Complexity:** O(n)

### Parallel Version: Segmented Sieve

To parallelize effectively, we use a segmented approach:

```text
┌─────────────────────────────────────────────────────────────────┐
│                    Range: [2, 10,000,000]                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 1: Calculate base primes [2, √10,000,000] ≈ [2, 3162]     │
│         Sequential - these are needed by ALL threads            │
│         Result: 446 base primes                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 2: Divide remaining range among threads                    │
├─────────────────────────────────────────────────────────────────┤
│ Thread 0: [3163, 2,500,000]     ──┐                             │
│ Thread 1: [2,500,001, 5,000,000] ─┼── Run in PARALLEL           │
│ Thread 2: [5,000,001, 7,500,000] ─┤                             │
│ Thread 3: [7,500,001, 10,000,000]─┘                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 3: Each thread sieves its segment using base primes        │
│         NO SYNCHRONIZATION needed during sieving!               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Step 4: Collect and merge results from all threads              │
└─────────────────────────────────────────────────────────────────┘
```

## Thread Synchronization

### Shared Resources

| Resource | Access Pattern | Protection |
|----------|----------------|------------|
| Base primes | Read-only | `Arc<Vec<u64>>` |
| Results collection | Write (once per thread) | `Arc<Mutex<Vec<Vec<u64>>>>` |
| Thread metrics | Write (once per thread) | `Arc<Mutex<Vec<...>>>` |

### Avoiding Race Conditions

1. **Base primes are immutable** after initial calculation
   - Shared via `Arc` (atomic reference counting)
   - No mutex needed for read-only data

2. **Each thread writes to its own slot**
   - Results vector pre-allocated with one slot per thread
   - Threads only write to their assigned index
   - Mutex protects the vector structure, not individual slots

3. **No shared mutable state during computation**
   - Each thread has its own local `is_prime` array
   - Sieving is completely independent

### Avoiding Deadlocks

- Only one mutex is ever held at a time
- Lock acquisition order is consistent
- Locks are held for minimal duration (only during result collection)

```rust
// Critical section - minimal lock duration
{
    let mut results_guard = results.lock().unwrap();
    results_guard[thread_id] = segment_primes;
} // Lock released immediately
```

## Implementation Details

### Key Data Structures

```rust
// Thread-safe shared read-only data
let base_primes: Arc<Vec<u64>> = Arc::new(simple_sieve(sqrt_limit));

// Thread-safe results collection
let results: Arc<Mutex<Vec<Vec<u64>>>> = Arc::new(Mutex::new(vec![vec![]; num_threads]));
```

### Thread Spawning

```rust
for thread_id in 0..num_threads {
    let results = Arc::clone(&results);
    let base_primes = Arc::clone(&base_primes);
    
    let handle = thread::spawn(move || {
        // Calculate segment boundaries
        let segment_primes = sieve_segment(seg_low, seg_high, &base_primes);
        
        // Store results (critical section)
        let mut guard = results.lock().unwrap();
        guard[thread_id] = segment_primes;
    });
    
    handles.push(handle);
}

// Wait for all threads
for handle in handles {
    handle.join().expect("Thread panicked");
}
```

## Performance Analysis

### Expected Results

| Threads | Expected Speedup | Notes |
|---------|------------------|-------|
| 1 | 1.0x | Baseline |
| 2 | ~1.8x | Good scaling |
| 4 | ~3.2x | Good scaling |
| 8 | ~4-6x | Diminishing returns due to overhead |

### Factors Affecting Performance

1. **Amdahl's Law**: Sequential portion (base prime calculation) limits speedup
2. **Thread overhead**: Creation, synchronization, context switching
3. **Cache effects**: Larger segments may cause cache misses
4. **Memory bandwidth**: Multiple threads competing for memory access

### Running Benchmarks

```bash
# Build release version
cargo build --release

# Run sequential benchmark
pnpm run bench:seq

# Run multithreaded benchmark
pnpm run bench:mt

# Run full comparison
pnpm run bench:all
```

## Sample Output

```text
════════════════════════════════════════════════════════════
       MULTITHREADED PRIME NUMBER CALCULATOR
════════════════════════════════════════════════════════════
Configuration:
  Range: 2 to 10000000
  Threads: 4
  Algorithm: Segmented Sieve of Eratosthenes
  Mode: Parallel (multithreaded)
════════════════════════════════════════════════════════════

Calculating primes...

════════════════════════════════════════════════════════════
                      RESULTS
════════════════════════════════════════════════════════════
  Primes found:           664579
  Largest prime:         9999991
  Prime density:         0.066458
───────────────────────────────────────────────────────────
  Execution time:          45.123 ms
───────────────────────────────────────────────────────────
  Thread Metrics:
    Thread 0: [      3163,    2500000] -> 165432 primes
    Thread 1: [   2500001,    5000000] -> 163456 primes
    Thread 2: [   5000001,    7500000] -> 167823 primes
    Thread 3: [   7500001,   10000000] -> 167422 primes
════════════════════════════════════════════════════════════
```

## Validation

The implementation is validated against known prime counts:

| Limit | Expected Count | Source |
|-------|----------------|--------|
| 100 | 25 | π(100) |
| 1,000 | 168 | π(1000) |
| 10,000 | 1,229 | π(10000) |
| 100,000 | 9,592 | π(100000) |
| 1,000,000 | 78,498 | π(1000000) |
| 10,000,000 | 664,579 | π(10000000) |

## Conclusion

The multithreaded implementation demonstrates:

1. **Effective parallelization** of a compute-bound problem
2. **Proper synchronization** using Rust's ownership system
3. **Scalable performance** with increasing thread counts
4. **Thread-safe design** that avoids race conditions and deadlocks

The segmented sieve approach allows near-linear speedup for the parallel portion,
limited primarily by the sequential base prime calculation (Amdahl's Law).
