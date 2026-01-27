//! Multithreaded Prime Number Calculator
//!
//! This application calculates prime numbers using a segmented Sieve of
//! Eratosthenes with multiple threads for parallel processing.
//!
//! # Parallelization Strategy
//!
//! 1. Calculate "base primes" (primes up to √limit) sequentially
//! 2. Divide the remaining range into segments, one per thread
//! 3. Each thread uses the base primes to sieve its segment
//! 4. Collect and merge results from all threads

use clap::Parser;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

/// Multithreaded prime number calculator using Segmented Sieve
#[derive(Parser, Debug)]
#[command(name = "primes-multithread")]
#[command(about = "Calculate prime numbers using multiple threads", long_about = None)]
struct Args {
    /// Upper limit of the range to search for primes (inclusive)
    #[arg(short, long, default_value_t = 10_000_000)]
    limit: u64,

    /// Number of threads to use
    #[arg(short, long, default_value_t = 4)]
    threads: usize,

    /// Show the list of primes found (warning: can be very long)
    #[arg(short, long, default_value_t = false)]
    verbose: bool,

    /// Output results in CSV format for benchmarking
    #[arg(long, default_value_t = false)]
    csv: bool,
}

/// Simple Sieve for finding base primes (primes up to sqrt(limit))
///
/// This is used to find the "seed" primes that will be used by all
/// threads to sieve their respective segments.
fn simple_sieve(limit: u64) -> Vec<u64> {
    if limit < 2 {
        return vec![];
    }

    let mut is_prime = vec![true; (limit + 1) as usize];
    is_prime[0] = false;
    is_prime[1] = false;

    let sqrt_limit = (limit as f64).sqrt() as u64;

    for num in 2..=sqrt_limit {
        if is_prime[num as usize] {
            let mut multiple = num * num;
            while multiple <= limit {
                is_prime[multiple as usize] = false;
                multiple += num;
            }
        }
    }

    is_prime
        .iter()
        .enumerate()
        .filter(|(_, &prime)| prime)
        .map(|(idx, _)| idx as u64)
        .collect()
}

/// Sieve a segment of numbers using pre-computed base primes
///
/// # Algorithm
///
/// For each base prime p, we need to mark all multiples of p in our segment.
/// The first multiple of p in range [low, high] is:
///   - If low <= p*p: start at p*p
///   - Otherwise: start at the smallest multiple of p >= low
///
/// # Arguments
///
/// * `low` - Start of the segment (inclusive)
/// * `high` - End of the segment (inclusive)
/// * `base_primes` - Pre-computed primes up to sqrt(limit)
///
/// # Returns
///
/// Vector of primes found in the segment [low, high]
fn sieve_segment(low: u64, high: u64, base_primes: &[u64]) -> Vec<u64> {
    // Handle edge case where segment is invalid
    if low > high {
        return vec![];
    }

    let segment_size = (high - low + 1) as usize;

    // Create a local sieve for this segment
    // Index i represents number (low + i)
    let mut is_prime = vec![true; segment_size];

    // Mark 0 and 1 as non-prime if they fall within our segment
    if low == 0 && segment_size > 0 {
        is_prime[0] = false;
    }
    if low <= 1 && high >= 1 {
        is_prime[(1 - low) as usize] = false;
    }

    // For each base prime, mark its multiples in our segment
    for &prime in base_primes {
        // Skip if prime^2 is beyond our segment
        if prime * prime > high {
            continue;
        }

        // Find the first multiple of prime in our segment
        // We want the smallest k such that k >= low and k % prime == 0
        let start = if low <= prime * prime {
            // If our segment includes prime^2, start there
            prime * prime
        } else {
            // Find the first multiple of prime >= low
            // Formula: ((low + prime - 1) / prime) * prime
            // This rounds up low to the nearest multiple of prime
            let remainder = low % prime;
            if remainder == 0 {
                low
            } else {
                low + (prime - remainder)
            }
        };

        // Mark all multiples of prime in our segment as composite
        let mut multiple = start;
        while multiple <= high {
            // Convert global index to local segment index
            let local_idx = (multiple - low) as usize;
            is_prime[local_idx] = false;
            multiple += prime;
        }
    }

    // Collect primes from this segment
    is_prime
        .iter()
        .enumerate()
        .filter(|(_, &prime)| prime)
        .map(|(idx, _)| low + idx as u64)
        // Filter out base primes (they're handled separately)
        .filter(|&n| n > 1)
        .collect()
}

/// Segmented Sieve of Eratosthenes - Multithreaded Implementation
///
/// # Parallelization Strategy
///
/// ```text
/// Range: [2, limit]
///
/// Step 1: Calculate base primes [2, √limit] sequentially
///         These are needed by all threads
///
/// Step 2: Divide remaining range into segments
///         Thread 0: [√limit + 1, segment_end_0]
///         Thread 1: [segment_end_0 + 1, segment_end_1]
///         ...
///
/// Step 3: Each thread sieves its segment independently
///         (No synchronization needed during sieving!)
///
/// Step 4: Collect and merge results
/// ```
fn segmented_sieve_parallel(limit: u64, num_threads: usize) -> (Vec<u64>, ThreadMetrics) {
    if limit < 2 {
        return (vec![], ThreadMetrics::default());
    }

    let sqrt_limit = (limit as f64).sqrt() as u64;

    // Step 1: Find base primes (sequential)
    // These are all primes up to sqrt(limit)
    let base_primes = simple_sieve(sqrt_limit);

    // If limit is small, base primes might be all we need
    if sqrt_limit >= limit {
        return (
            base_primes,
            ThreadMetrics {
                segments: vec![],
            },
        );
    }

    // Step 2: Divide the range (sqrt_limit + 1, limit] among threads
    let range_start = sqrt_limit + 1;
    let range_size = limit - sqrt_limit;
    let segment_size = (range_size + num_threads as u64 - 1) / num_threads as u64;

    // Shared storage for results from each thread
    // Using Arc<Mutex<Vec>> for thread-safe collection
    let results: Arc<Mutex<Vec<Vec<u64>>>> = Arc::new(Mutex::new(vec![vec![]; num_threads]));

    // Metrics for reporting
    let metrics: Arc<Mutex<Vec<(u64, u64, usize)>>> = Arc::new(Mutex::new(vec![]));

    // Share base_primes among threads (read-only, so Arc is sufficient)
    let base_primes = Arc::new(base_primes);

    // Step 3: Spawn threads
    let mut handles = vec![];

    for thread_id in 0..num_threads {
        // Calculate this thread's segment boundaries
        let seg_low = range_start + (thread_id as u64 * segment_size);
        let seg_high = std::cmp::min(seg_low + segment_size - 1, limit);

        // Skip if this thread has no work (can happen with few numbers)
        if seg_low > limit {
            continue;
        }

        // Clone Arc references for this thread
        let results = Arc::clone(&results);
        let metrics = Arc::clone(&metrics);
        let base_primes = Arc::clone(&base_primes);

        let handle = thread::spawn(move || {
            // Each thread sieves its segment independently
            // No synchronization needed during computation!
            let segment_primes = sieve_segment(seg_low, seg_high, &base_primes);

            let prime_count = segment_primes.len();

            // Store results (requires lock)
            // CRITICAL SECTION: Accessing shared data
            {
                let mut results_guard = results.lock().unwrap();
                results_guard[thread_id] = segment_primes;
            } // Lock is released here

            // Store metrics
            {
                let mut metrics_guard = metrics.lock().unwrap();
                metrics_guard.push((seg_low, seg_high, prime_count));
            }
        });

        handles.push(handle);
    }

    // Step 4: Wait for all threads to complete
    for handle in handles {
        handle.join().expect("Thread panicked");
    }

    // Collect all primes in order
    let mut all_primes = simple_sieve(sqrt_limit); // Start with base primes

    // Add primes from each segment (already sorted within each segment)
    let results_guard = results.lock().unwrap();
    for segment_primes in results_guard.iter() {
        all_primes.extend(segment_primes);
    }

    // Build metrics
    let metrics_guard = metrics.lock().unwrap();
    let thread_metrics = ThreadMetrics {
        segments: metrics_guard.clone(),
    };

    (all_primes, thread_metrics)
}

#[derive(Default)]
struct ThreadMetrics {
    segments: Vec<(u64, u64, usize)>, // (low, high, prime_count)
}

struct PrimeStatistics {
    count: usize,
    largest: u64,
    density: f64,
}

fn calculate_statistics(primes: &[u64], limit: u64) -> PrimeStatistics {
    PrimeStatistics {
        count: primes.len(),
        largest: primes.last().copied().unwrap_or(0),
        density: if limit > 0 {
            primes.len() as f64 / limit as f64
        } else {
            0.0
        },
    }
}

fn main() {
    let args = Args::parse();

    // Validate thread count
    let num_threads = if args.threads == 0 { 1 } else { args.threads };

    if !args.csv {
        println!("═══════════════════════════════════════════════════════════");
        println!("       MULTITHREADED PRIME NUMBER CALCULATOR");
        println!("═══════════════════════════════════════════════════════════");
        println!("Configuration:");
        println!("  Range: 2 to {}", args.limit);
        println!("  Threads: {}", num_threads);
        println!("  Algorithm: Segmented Sieve of Eratosthenes");
        println!("  Mode: Parallel (multithreaded)");
        println!("═══════════════════════════════════════════════════════════");
        println!("\nCalculating primes...\n");
    }

    // Start timing
    let start_time = Instant::now();

    // Run the parallel sieve
    let (primes, metrics) = segmented_sieve_parallel(args.limit, num_threads);

    // Stop timing
    let elapsed = start_time.elapsed();

    // Calculate statistics
    let stats = calculate_statistics(&primes, args.limit);

    if args.csv {
        // CSV format: limit,threads,time_ms,prime_count
        println!(
            "{},{},{:.3},{}",
            args.limit,
            num_threads,
            elapsed.as_secs_f64() * 1000.0,
            stats.count
        );
    } else {
        println!("═══════════════════════════════════════════════════════════");
        println!("                      RESULTS");
        println!("═══════════════════════════════════════════════════════════");
        println!("  Primes found:        {:>12}", stats.count);
        println!("  Largest prime:       {:>12}", stats.largest);
        println!("  Prime density:       {:>12.6}", stats.density);
        println!("───────────────────────────────────────────────────────────");
        println!("  Execution time:      {:>12.3} ms", elapsed.as_secs_f64() * 1000.0);
        println!("  Execution time:      {:>12.6} s", elapsed.as_secs_f64());
        println!("───────────────────────────────────────────────────────────");
        println!("  Thread Metrics:");

        for (i, (low, high, count)) in metrics.segments.iter().enumerate() {
            println!(
                "    Thread {}: [{:>10}, {:>10}] -> {} primes",
                i, low, high, count
            );
        }

        println!("═══════════════════════════════════════════════════════════");

        if args.verbose {
            println!("\nPrime numbers found:");
            for (i, prime) in primes.iter().enumerate() {
                if i > 0 && i % 10 == 0 {
                    println!();
                }
                print!("{:>8} ", prime);
            }
            println!();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_sieve() {
        let primes = simple_sieve(30);
        assert_eq!(primes, vec![2, 3, 5, 7, 11, 13, 17, 19, 23, 29]);
    }

    #[test]
    fn test_parallel_sieve_matches_sequential() {
        let limit = 10_000;
        let sequential = simple_sieve(limit);
        let (parallel, _) = segmented_sieve_parallel(limit, 4);
        assert_eq!(sequential, parallel);
    }

    #[test]
    fn test_different_thread_counts() {
        let limit = 10_000;
        let expected = simple_sieve(limit);

        for threads in [1, 2, 4, 8] {
            let (result, _) = segmented_sieve_parallel(limit, threads);
            assert_eq!(
                result, expected,
                "Mismatch with {} threads",
                threads
            );
        }
    }

    #[test]
    fn test_segment_sieve() {
        let base_primes = vec![2, 3, 5, 7];
        let segment = sieve_segment(10, 20, &base_primes);
        assert_eq!(segment, vec![11, 13, 17, 19]);
    }
}
