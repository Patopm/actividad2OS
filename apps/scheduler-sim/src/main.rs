//! Process Scheduling Simulator
//!
//! This application demonstrates different CPU scheduling algorithms
//! available in Linux. It runs prime calculation tasks under various
//! scheduling policies and measures performance metrics.
//!
//! # Supported Scheduling Policies
//!
//! - SCHED_OTHER: Default Linux time-sharing scheduler (CFS)
//! - SCHED_FIFO: Real-time First-In-First-Out scheduler
//! - SCHED_RR: Real-time Round-Robin scheduler
//!
//! # Requirements
//!
//! Real-time policies (SCHED_FIFO, SCHED_RR) require either:
//! - Root privileges (sudo)
//! - CAP_SYS_NICE capability
//! - Proper limits in /etc/security/limits.conf

use clap::{Parser, ValueEnum};
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Scheduling policy options
#[derive(Debug, Clone, Copy, ValueEnum, PartialEq)]
enum SchedulingPolicy {
    /// Default Linux CFS scheduler (SCHED_OTHER)
    Other,
    /// Real-time FIFO scheduler (SCHED_FIFO)
    Fifo,
    /// Real-time Round-Robin scheduler (SCHED_RR)
    Rr,
    /// Run all policies for comparison
    All,
}

impl std::fmt::Display for SchedulingPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SchedulingPolicy::Other => write!(f, "SCHED_OTHER"),
            SchedulingPolicy::Fifo => write!(f, "SCHED_FIFO"),
            SchedulingPolicy::Rr => write!(f, "SCHED_RR"),
            SchedulingPolicy::All => write!(f, "ALL"),
        }
    }
}

/// Scheduler simulation for prime calculation
#[derive(Parser, Debug)]
#[command(name = "scheduler-sim")]
#[command(about = "Demonstrate CPU scheduling algorithms", long_about = None)]
struct Args {
    /// Scheduling policy to use
    #[arg(short, long, value_enum, default_value_t = SchedulingPolicy::Other)]
    policy: SchedulingPolicy,

    /// Number of worker threads
    #[arg(short, long, default_value_t = 4)]
    threads: usize,

    /// Priority level (1-99 for RT policies, -20 to 19 for SCHED_OTHER nice)
    #[arg(short = 'P', long, default_value_t = 50)]
    priority: i32,

    /// Upper limit for prime calculation
    #[arg(short, long, default_value_t = 5_000_000)]
    limit: u64,

    /// Number of iterations per thread
    #[arg(short, long, default_value_t = 3)]
    iterations: u32,

    /// Output in CSV format
    #[arg(long, default_value_t = false)]
    csv: bool,

    /// Verbose output with per-thread details
    #[arg(short, long, default_value_t = false)]
    verbose: bool,
}

/// Metrics collected for each thread
#[derive(Debug, Clone)]
struct ThreadMetrics {
    thread_id: usize,
    policy: String,
    priority: i32,
    /// Time from thread creation to first execution
    wait_time: Duration,
    /// Time to complete all work
    execution_time: Duration,
    /// Total time from creation to completion
    turnaround_time: Duration,
    /// Number of primes found
    primes_found: usize,
    /// Number of context switches (estimated)
    work_iterations: u32,
}

/// Aggregated metrics for a scheduling policy run
#[derive(Debug)]
struct PolicyMetrics {
    policy: String,
    total_threads: usize,
    avg_wait_time_ms: f64,
    avg_execution_time_ms: f64,
    avg_turnaround_time_ms: f64,
    total_primes: usize,
    throughput: f64, // primes per second
    wall_clock_time_ms: f64,
}

/// Simple sieve for calculating primes
fn calculate_primes(limit: u64) -> Vec<u64> {
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

/// Set the scheduling policy for the current thread
///
/// # Safety
///
/// This function uses unsafe libc calls to modify thread scheduling.
/// It requires appropriate privileges for real-time policies.
fn set_thread_scheduling(policy: SchedulingPolicy, priority: i32) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        use libc::{
            sched_param, sched_setscheduler, SCHED_FIFO, SCHED_OTHER, SCHED_RR,
        };

        let linux_policy = match policy {
            SchedulingPolicy::Other => SCHED_OTHER,
            SchedulingPolicy::Fifo => SCHED_FIFO,
            SchedulingPolicy::Rr => SCHED_RR,
            SchedulingPolicy::All => return Ok(()), // No-op for "all"
        };

        // For SCHED_OTHER, priority must be 0
        // For RT policies, priority must be 1-99
        let sched_priority = match policy {
            SchedulingPolicy::Other => 0,
            SchedulingPolicy::Fifo | SchedulingPolicy::Rr => priority.clamp(1, 99),
            SchedulingPolicy::All => 0,
        };

        let param = sched_param {
            sched_priority: sched_priority,
        };

        // 0 means current process/thread
        let result = unsafe { sched_setscheduler(0, linux_policy, &param) };

        if result == -1 {
            let errno = std::io::Error::last_os_error();
            return Err(format!(
                "Failed to set scheduling policy: {} (try running with sudo)",
                errno
            ));
        }

        Ok(())
    }

    #[cfg(not(target_os = "linux"))]
    {
        let _ = (policy, priority);
        Err("Scheduling policies are only supported on Linux".to_string())
    }
}

/// Set nice value for SCHED_OTHER policy
#[cfg(target_os = "linux")]
fn set_nice_value(nice: i32) -> Result<(), String> {
    use libc::{setpriority, PRIO_PROCESS};

    let nice_value = nice.clamp(-20, 19);

    let result = unsafe { setpriority(PRIO_PROCESS, 0, nice_value) };

    if result == -1 {
        let errno = std::io::Error::last_os_error();
        // Nice values above 0 don't require privileges
        if nice_value < 0 {
            return Err(format!(
                "Failed to set nice value: {} (negative nice requires sudo)",
                errno
            ));
        }
    }

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn set_nice_value(_nice: i32) -> Result<(), String> {
    Ok(())
}

/// Get current scheduling policy as string
#[cfg(target_os = "linux")]
fn get_current_policy() -> String {
    use libc::{sched_getscheduler, SCHED_FIFO, SCHED_OTHER, SCHED_RR};

    let policy = unsafe { sched_getscheduler(0) };

    match policy {
        x if x == SCHED_OTHER => "SCHED_OTHER".to_string(),
        x if x == SCHED_FIFO => "SCHED_FIFO".to_string(),
        x if x == SCHED_RR => "SCHED_RR".to_string(),
        _ => format!("UNKNOWN({})", policy),
    }
}

#[cfg(not(target_os = "linux"))]
fn get_current_policy() -> String {
    "N/A".to_string()
}

/// Run workers with a specific scheduling policy
fn run_with_policy(
    policy: SchedulingPolicy,
    num_threads: usize,
    priority: i32,
    limit: u64,
    iterations: u32,
    verbose: bool,
) -> Result<PolicyMetrics, String> {
    let creation_time = Instant::now();

    // Barrier to synchronize thread start
    let barrier = Arc::new(Barrier::new(num_threads + 1)); // +1 for main thread

    // Shared storage for metrics
    let metrics: Arc<Mutex<Vec<ThreadMetrics>>> = Arc::new(Mutex::new(Vec::new()));

    let mut handles = vec![];

    // Spawn worker threads
    for thread_id in 0..num_threads {
        let barrier = Arc::clone(&barrier);
        let metrics = Arc::clone(&metrics);
        let thread_creation = Instant::now();

        let handle = thread::spawn(move || {
            // Record time waiting for barrier
            let wait_start = thread_creation;

            // Try to set scheduling policy
            let policy_result = set_thread_scheduling(policy, priority);
            let actual_policy = get_current_policy();

            // For SCHED_OTHER, also try to set nice value
            if policy == SchedulingPolicy::Other && priority != 0 {
                // Map priority 1-99 to nice -20 to 19
                let nice = ((priority as f64 / 99.0) * 39.0 - 20.0) as i32;
                let _ = set_nice_value(nice);
            }

            // Wait for all threads to be ready
            barrier.wait();

            let wait_time = wait_start.elapsed();
            let exec_start = Instant::now();

            // Do the actual work
            let mut total_primes = 0;
            for _ in 0..iterations {
                let primes = calculate_primes(limit);
                total_primes = primes.len();

                // Small yield to allow context switches
                thread::yield_now();
            }

            let execution_time = exec_start.elapsed();
            let turnaround_time = thread_creation.elapsed();

            // Store metrics
            let thread_metrics = ThreadMetrics {
                thread_id,
                policy: actual_policy,
                priority,
                wait_time,
                execution_time,
                turnaround_time,
                primes_found: total_primes,
                work_iterations: iterations,
            };

            let mut guard = metrics.lock().unwrap();
            guard.push(thread_metrics);

            policy_result
        });

        handles.push(handle);
    }

    // Release all threads simultaneously
    barrier.wait();
    let parallel_start = Instant::now();

    // Wait for all threads and collect any errors
    let mut errors = vec![];
    for handle in handles {
        match handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => errors.push(e),
            Err(_) => errors.push("Thread panicked".to_string()),
        }
    }

    let wall_clock_time = parallel_start.elapsed();

    // Report errors but continue
    if !errors.is_empty() && verbose {
        eprintln!("Warning: {}", errors[0]);
    }

    // Calculate aggregate metrics
    let metrics_guard = metrics.lock().unwrap();

    if metrics_guard.is_empty() {
        return Err("No metrics collected".to_string());
    }

    let total_threads = metrics_guard.len();

    let avg_wait_time_ms: f64 = metrics_guard
        .iter()
        .map(|m| m.wait_time.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / total_threads as f64;

    let avg_execution_time_ms: f64 = metrics_guard
        .iter()
        .map(|m| m.execution_time.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / total_threads as f64;

    let avg_turnaround_time_ms: f64 = metrics_guard
        .iter()
        .map(|m| m.turnaround_time.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / total_threads as f64;

    let total_primes: usize = metrics_guard.iter().map(|m| m.primes_found).sum();

    let wall_clock_secs = wall_clock_time.as_secs_f64();
    let throughput = if wall_clock_secs > 0.0 {
        (total_primes as f64 * iterations as f64) / wall_clock_secs
    } else {
        0.0
    };

    // Print per-thread details if verbose
    if verbose {
        println!("\n  Per-thread metrics:");
        println!(
            "  {:>4} {:>14} {:>10} {:>12} {:>12} {:>12}",
            "ID", "Policy", "Priority", "Wait(ms)", "Exec(ms)", "Turnaround(ms)"
        );
        println!("  {}", "─".repeat(70));

        for m in metrics_guard.iter() {
            println!(
                "  {:>4} {:>14} {:>10} {:>12.3} {:>12.3} {:>12.3}",
                m.thread_id,
                m.policy,
                m.priority,
                m.wait_time.as_secs_f64() * 1000.0,
                m.execution_time.as_secs_f64() * 1000.0,
                m.turnaround_time.as_secs_f64() * 1000.0,
            );
        }
    }

    Ok(PolicyMetrics {
        policy: policy.to_string(),
        total_threads,
        avg_wait_time_ms,
        avg_execution_time_ms,
        avg_turnaround_time_ms,
        total_primes: metrics_guard[0].primes_found, // Same for all threads
        throughput,
        wall_clock_time_ms: wall_clock_time.as_secs_f64() * 1000.0,
    })
}

/// Print results in human-readable format
fn print_results(metrics: &PolicyMetrics) {
    println!("\n  ┌─────────────────────────────────────────────────────────┐");
    println!("  │ Policy: {:^47} │", metrics.policy);
    println!("  ├─────────────────────────────────────────────────────────┤");
    println!(
        "  │ Threads:              {:>32} │",
        metrics.total_threads
    );
    println!(
        "  │ Avg Wait Time:        {:>29.3} ms │",
        metrics.avg_wait_time_ms
    );
    println!(
        "  │ Avg Execution Time:   {:>29.3} ms │",
        metrics.avg_execution_time_ms
    );
    println!(
        "  │ Avg Turnaround Time:  {:>29.3} ms │",
        metrics.avg_turnaround_time_ms
    );
    println!(
        "  │ Wall Clock Time:      {:>29.3} ms │",
        metrics.wall_clock_time_ms
    );
    println!(
        "  │ Throughput:           {:>25.0} primes/s │",
        metrics.throughput
    );
    println!("  └─────────────────────────────────────────────────────────┘");
}

/// Print CSV header
fn print_csv_header() {
    println!(
        "policy,threads,priority,avg_wait_ms,avg_exec_ms,avg_turnaround_ms,wall_clock_ms,throughput"
    );
}

/// Print results in CSV format
fn print_csv_results(metrics: &PolicyMetrics, priority: i32) {
    println!(
        "{},{},{},{:.3},{:.3},{:.3},{:.3},{:.0}",
        metrics.policy,
        metrics.total_threads,
        priority,
        metrics.avg_wait_time_ms,
        metrics.avg_execution_time_ms,
        metrics.avg_turnaround_time_ms,
        metrics.wall_clock_time_ms,
        metrics.throughput
    );
}

fn main() {
    let args = Args::parse();

    if !args.csv {
        println!("═══════════════════════════════════════════════════════════");
        println!("           CPU SCHEDULING POLICY SIMULATOR");
        println!("═══════════════════════════════════════════════════════════");
        println!("\nConfiguration:");
        println!("  Threads: {}", args.threads);
        println!("  Priority: {}", args.priority);
        println!("  Prime limit: {}", args.limit);
        println!("  Iterations per thread: {}", args.iterations);
        println!("  Policy: {}", args.policy);
        println!("\n───────────────────────────────────────────────────────────");
    }

    let policies = if args.policy == SchedulingPolicy::All {
        vec![
            SchedulingPolicy::Other,
            SchedulingPolicy::Fifo,
            SchedulingPolicy::Rr,
        ]
    } else {
        vec![args.policy]
    };

    if args.csv {
        print_csv_header();
    }

    let mut all_metrics = vec![];

    for policy in policies {
        if !args.csv {
            println!("\n▶ Running with policy: {}", policy);
        }

        match run_with_policy(
            policy,
            args.threads,
            args.priority,
            args.limit,
            args.iterations,
            args.verbose,
        ) {
            Ok(metrics) => {
                if args.csv {
                    print_csv_results(&metrics, args.priority);
                } else {
                    print_results(&metrics);
                }
                all_metrics.push(metrics);
            }
            Err(e) => {
                if args.csv {
                    eprintln!("# Error for {}: {}", policy, e);
                } else {
                    eprintln!("  Error: {}", e);
                }
            }
        }
    }

    // Print comparison if running all policies
    if args.policy == SchedulingPolicy::All && !args.csv && all_metrics.len() > 1 {
        println!("\n═══════════════════════════════════════════════════════════");
        println!("                    COMPARISON SUMMARY");
        println!("═══════════════════════════════════════════════════════════");
        println!(
            "\n{:>14} {:>12} {:>12} {:>12} {:>12}",
            "Policy", "Wait(ms)", "Exec(ms)", "Turn.(ms)", "Throughput"
        );
        println!("{}", "─".repeat(64));

        for m in &all_metrics {
            println!(
                "{:>14} {:>12.3} {:>12.3} {:>12.3} {:>12.0}",
                m.policy,
                m.avg_wait_time_ms,
                m.avg_execution_time_ms,
                m.avg_turnaround_time_ms,
                m.throughput
            );
        }

        // Find best in each category
        if let Some(best_wait) = all_metrics.iter().min_by(|a, b| {
            a.avg_wait_time_ms
                .partial_cmp(&b.avg_wait_time_ms)
                .unwrap()
        }) {
            println!(
                "\n✓ Lowest wait time: {} ({:.3} ms)",
                best_wait.policy, best_wait.avg_wait_time_ms
            );
        }

        if let Some(best_throughput) = all_metrics
            .iter()
            .max_by(|a, b| a.throughput.partial_cmp(&b.throughput).unwrap())
        {
            println!(
                "✓ Highest throughput: {} ({:.0} primes/s)",
                best_throughput.policy, best_throughput.throughput
            );
        }
    }

    if !args.csv {
        println!("\n═══════════════════════════════════════════════════════════");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_primes() {
        let primes = calculate_primes(100);
        assert_eq!(primes.len(), 25);
    }

    #[test]
    fn test_scheduling_policy_display() {
        assert_eq!(format!("{}", SchedulingPolicy::Other), "SCHED_OTHER");
        assert_eq!(format!("{}", SchedulingPolicy::Fifo), "SCHED_FIFO");
        assert_eq!(format!("{}", SchedulingPolicy::Rr), "SCHED_RR");
    }

    #[test]
    fn test_run_with_default_policy() {
        // This should always work without privileges
        let result = run_with_policy(SchedulingPolicy::Other, 2, 0, 10000, 1, false);
        assert!(result.is_ok());
    }
}
