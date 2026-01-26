//! Sequential Prime Number Calculator
//!
//! This application calculates prime numbers in a given range using
//! the Sieve of Eratosthenes algorithm without any parallelization.
//! Used as a baseline for performance comparison.

use clap::Parser;
use std::time::Instant;

/// Sequential prime number calculator using Sieve of Eratosthenes
#[derive(Parser, Debug)]
#[command(name = "primes-sequential")]
#[command(about = "Calculate prime numbers sequentially", long_about = None)]
struct Args {
    /// Upper limit of the range to search for primes (inclusive)
    #[arg(short, long, default_value_t = 10_000_000)]
    limit: u64,

    /// Show the list of primes found (warning: can be very long)
    #[arg(short, long, default_value_t = false)]
    verbose: bool,

    /// Output results in CSV format for benchmarking
    #[arg(long, default_value_t = false)]
    csv: bool,
}

/// Sieve of Eratosthenes - Sequential Implementation
///
/// This function implements the classic Sieve of Eratosthenes algorithm
/// to find all prime numbers up to a given limit.
///
/// # Algorithm Overview
/// 1. Create a boolean array of size (limit + 1), initialized to true
/// 2. Mark 0 and 1 as non-prime
/// 3. For each number p starting from 2:
///    - If p is still marked as prime, mark all multiples of p as non-prime
///    - Only need to check up to sqrt(limit)
/// 4. Collect all indices that are still marked as true
///
/// # Arguments
/// * `limit` - The upper bound (inclusive) to search for primes
///
/// # Returns
/// A vector containing all prime numbers up to the limit
fn sieve_of_eratosthenes(limit: u64) -> Vec<u64> {
    // Handle edge cases
    if limit < 2 {
        return vec![];
    }

    // Create a boolean vector where index represents the number
    // true = potentially prime, false = composite
    let mut is_prime = vec![true; (limit + 1) as usize];

    // 0 and 1 are not prime by definition
    is_prime[0] = false;
    is_prime[1] = false;

    // We only need to check up to sqrt(limit)
    // Any composite number > sqrt(limit) will have a factor <= sqrt(limit)
    let sqrt_limit = (limit as f64).sqrt() as u64;

    // Main sieve loop
    for num in 2..=sqrt_limit {
        // If num is still marked as prime
        if is_prime[num as usize] {
            // Mark all multiples of num as composite
            // Start from num^2 because smaller multiples were already marked
            // by smaller primes
            let mut multiple = num * num;
            while multiple <= limit {
                is_prime[multiple as usize] = false;
                multiple += num;
            }
        }
    }

    // Collect all prime numbers
    is_prime
        .iter()
        .enumerate()
        .filter(|(_, &prime)| prime)
        .map(|(idx, _)| idx as u64)
        .collect()
}

/// Calculate basic statistics about the prime distribution
fn calculate_statistics(primes: &[u64], limit: u64) -> PrimeStatistics {
    let count = primes.len();
    let largest = primes.last().copied().unwrap_or(0);

    // Prime density: ratio of primes to total numbers
    let density = if limit > 0 {
        count as f64 / limit as f64
    } else {
        0.0
    };

    // According to Prime Number Theorem, π(n) ≈ n / ln(n)
    let theoretical_count = if limit > 1 {
        (limit as f64 / (limit as f64).ln()) as usize
    } else {
        0
    };

    PrimeStatistics {
        count,
        largest,
        density,
        theoretical_count,
    }
}

struct PrimeStatistics {
    count: usize,
    largest: u64,
    density: f64,
    theoretical_count: usize,
}

fn main() {
    let args = Args::parse();

    // Print configuration (unless CSV mode)
    if !args.csv {
        println!("═══════════════════════════════════════════════════════════");
        println!("       SEQUENTIAL PRIME NUMBER CALCULATOR");
        println!("═══════════════════════════════════════════════════════════");
        println!("Configuration:");
        println!("  Range: 2 to {}", args.limit);
        println!("  Algorithm: Sieve of Eratosthenes");
        println!("  Mode: Sequential (single-threaded)");
        println!("═══════════════════════════════════════════════════════════");
        println!("\nCalculating primes...\n");
    }

    // Start timing
    let start_time = Instant::now();

    // Run the sieve algorithm
    let primes = sieve_of_eratosthenes(args.limit);

    // Stop timing
    let elapsed = start_time.elapsed();

    // Calculate statistics
    let stats = calculate_statistics(&primes, args.limit);

    // Output results
    if args.csv {
        // CSV format: limit,threads,time_ms,prime_count
        println!(
            "{},{},{:.3},{}",
            args.limit,
            1, // threads = 1 for sequential
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
        println!("  Theoretical count:   {:>12} (π(n) ≈ n/ln(n))", stats.theoretical_count);
        println!("───────────────────────────────────────────────────────────");
        println!("  Execution time:      {:>12.3} ms", elapsed.as_secs_f64() * 1000.0);
        println!("  Execution time:      {:>12.6} s", elapsed.as_secs_f64());
        println!("═══════════════════════════════════════════════════════════");

        // Show primes if verbose mode
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
    fn test_small_primes() {
        let primes = sieve_of_eratosthenes(30);
        assert_eq!(primes, vec![2, 3, 5, 7, 11, 13, 17, 19, 23, 29]);
    }

    #[test]
    fn test_prime_count_100() {
        let primes = sieve_of_eratosthenes(100);
        assert_eq!(primes.len(), 25); // There are 25 primes <= 100
    }

    #[test]
    fn test_prime_count_1000() {
        let primes = sieve_of_eratosthenes(1000);
        assert_eq!(primes.len(), 168); // There are 168 primes <= 1000
    }

    #[test]
    fn test_edge_cases() {
        assert_eq!(sieve_of_eratosthenes(0), vec![]);
        assert_eq!(sieve_of_eratosthenes(1), vec![]);
        assert_eq!(sieve_of_eratosthenes(2), vec![2]);
    }
}
