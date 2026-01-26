//! Distributed Prime Number Calculator using MPI
//!
//! This application calculates prime numbers across multiple nodes
//! using the Message Passing Interface (MPI) for communication.
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────────┐
//! │                        MPI Cluster                              │
//! ├─────────────────────────────────────────────────────────────────┤
//! │                                                                 │
//! │   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐      │
//! │   │   Rank 0    │     │   Rank 1    │     │   Rank 2    │      │
//! │   │  (Master)   │     │  (Worker)   │     │  (Worker)   │      │
//! │   │             │     │             │     │             │      │
//! │   │ [2, 3.3M]   │     │ [3.3M, 6.6M]│     │ [6.6M, 10M] │      │
//! │   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘      │
//! │          │                   │                   │              │
//! │          └───────────────────┼───────────────────┘              │
//! │                              │                                  │
//! │                        MPI_Gather                               │
//! │                              │                                  │
//! │                              ▼                                  │
//! │                     ┌─────────────┐                             │
//! │                     │   Results   │                             │
//! │                     └─────────────┘                             │
//! └─────────────────────────────────────────────────────────────────┘
//! ```
//!
//! # Usage
//!
//! ```bash
//! # With MPI (requires mpirun)
//! mpirun -np 4 ./primes-mpi --limit 10000000
//!
//! # Without MPI (single process fallback)
//! ./primes-mpi --limit 10000000
//! ```

use clap::Parser;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Instant;

/// Distributed prime calculator using MPI or TCP fallback
#[derive(Parser, Debug, Clone)]
#[command(name = "primes-mpi")]
#[command(about = "Calculate primes across distributed nodes", long_about = None)]
struct Args {
    /// Upper limit for prime calculation
    #[arg(short, long, default_value_t = 10_000_000)]
    limit: u64,

    /// Output in CSV format
    #[arg(long, default_value_t = false)]
    csv: bool,

    /// Verbose output
    #[arg(short, long, default_value_t = false)]
    verbose: bool,

    /// Use TCP fallback instead of MPI
    #[arg(long, default_value_t = false)]
    tcp: bool,

    /// TCP master address (for TCP mode)
    #[arg(long, default_value = "127.0.0.1:7878")]
    master_addr: String,

    /// Number of workers (for TCP master mode)
    #[arg(long, default_value_t = 2)]
    workers: usize,

    /// Run as TCP worker
    #[arg(long, default_value_t = false)]
    worker: bool,
}

/// Simple sieve to find base primes
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

/// Sieve a segment using base primes
fn sieve_segment(low: u64, high: u64, base_primes: &[u64]) -> Vec<u64> {
    if low > high {
        return vec![];
    }

    let segment_size = (high - low + 1) as usize;
    let mut is_prime = vec![true; segment_size];

    // Handle 0 and 1
    if low == 0 && segment_size > 0 {
        is_prime[0] = false;
    }
    if low <= 1 && high >= 1 {
        is_prime[(1 - low) as usize] = false;
    }

    for &prime in base_primes {
        if prime * prime > high {
            continue;
        }

        let start = if low <= prime * prime {
            prime * prime
        } else {
            let remainder = low % prime;
            if remainder == 0 {
                low
            } else {
                low + (prime - remainder)
            }
        };

        let mut multiple = start;
        while multiple <= high {
            let local_idx = (multiple - low) as usize;
            is_prime[local_idx] = false;
            multiple += prime;
        }
    }

    is_prime
        .iter()
        .enumerate()
        .filter(|(_, &prime)| prime)
        .map(|(idx, _)| low + idx as u64)
        .filter(|&n| n > 1)
        .collect()
}

/// MPI-based distributed calculation
#[cfg(feature = "mpi")]
mod mpi_impl {
    use super::*;
    use mpi::collective::CommunicatorCollectives;
    use mpi::point_to_point::{Destination, Source};
    use mpi::topology::Communicator;
    use mpi::traits::*;

    pub fn run_mpi(args: &Args) -> Result<DistributedResult, String> {
        let universe = mpi::initialize().ok_or("Failed to initialize MPI")?;
        let world = universe.world();
        let rank = world.rank();
        let size = world.size();

        let start_time = Instant::now();

        // Calculate base primes (all ranks need these)
        let sqrt_limit = (args.limit as f64).sqrt() as u64;
        let base_primes = simple_sieve(sqrt_limit);

        // Divide work among ranks
        let range_start = sqrt_limit + 1;
        let range_size = args.limit - sqrt_limit;
        let segment_size = (range_size + size as u64 - 1) / size as u64;

        let my_low = range_start + (rank as u64 * segment_size);
        let my_high = std::cmp::min(my_low + segment_size - 1, args.limit);

        if args.verbose && rank == 0 {
            println!("MPI Configuration:");
            println!("  Total ranks: {}", size);
            println!("  Limit: {}", args.limit);
            println!("  Base primes: {}", base_primes.len());
        }

        // Each rank sieves its segment
        let local_primes = if my_low <= args.limit {
            sieve_segment(my_low, my_high, &base_primes)
        } else {
            vec![]
        };

        let local_count = local_primes.len();

        if args.verbose {
            println!(
                "  Rank {}: [{}, {}] -> {} primes",
                rank, my_low, my_high, local_count
            );
        }

        // Gather counts at root
        let mut all_counts = if rank == 0 {
            vec![0usize; size as usize]
        } else {
            vec![]
        };

        world.gather_into_root(&local_count, &mut all_counts);

        // Calculate total
        let elapsed = start_time.elapsed();

        if rank == 0 {
            let total_from_segments: usize = all_counts.iter().sum();
            let total_primes = base_primes.len() + total_from_segments;

            Ok(DistributedResult {
                total_primes,
                nodes: size as usize,
                time_ms: elapsed.as_secs_f64() * 1000.0,
                node_counts: all_counts,
                base_prime_count: base_primes.len(),
            })
        } else {
            // Workers return empty result
            Ok(DistributedResult::default())
        }
    }
}

/// TCP-based distributed calculation (fallback when MPI not available)
mod tcp_impl {
    use super::*;

    /// Message types for TCP communication
    #[derive(Debug)]
    enum Message {
        Work { low: u64, high: u64, base_primes: Vec<u64> },
        Result { count: usize, node_id: usize },
        Shutdown,
    }

    fn serialize_work(low: u64, high: u64, base_primes: &[u64]) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend(&low.to_le_bytes());
        data.extend(&high.to_le_bytes());
        data.extend(&(base_primes.len() as u64).to_le_bytes());
        for &p in base_primes {
            data.extend(&p.to_le_bytes());
        }
        data
    }

    fn deserialize_work(data: &[u8]) -> (u64, u64, Vec<u64>) {
        let low = u64::from_le_bytes(data[0..8].try_into().unwrap());
        let high = u64::from_le_bytes(data[8..16].try_into().unwrap());
        let count = u64::from_le_bytes(data[16..24].try_into().unwrap()) as usize;

        let mut base_primes = Vec::with_capacity(count);
        for i in 0..count {
            let start = 24 + i * 8;
            let p = u64::from_le_bytes(data[start..start + 8].try_into().unwrap());
            base_primes.push(p);
        }

        (low, high, base_primes)
    }

    /// Run as TCP master
    pub fn run_master(args: &Args) -> Result<DistributedResult, String> {
        let start_time = Instant::now();

        // Calculate base primes
        let sqrt_limit = (args.limit as f64).sqrt() as u64;
        let base_primes = simple_sieve(sqrt_limit);

        if args.verbose {
            println!("TCP Master Configuration:");
            println!("  Workers expected: {}", args.workers);
            println!("  Limit: {}", args.limit);
            println!("  Base primes: {}", base_primes.len());
        }

        // Bind to address
        let listener = TcpListener::bind(&args.master_addr)
            .map_err(|e| format!("Failed to bind: {}", e))?;

        println!("Master listening on {}", args.master_addr);
        println!("Waiting for {} workers to connect...", args.workers);

        // Accept worker connections
        let mut workers: Vec<TcpStream> = Vec::new();
        for i in 0..args.workers {
            let (stream, addr) = listener
                .accept()
                .map_err(|e| format!("Accept failed: {}", e))?;
            println!("  Worker {} connected from {}", i, addr);
            workers.push(stream);
        }

        // Divide work
        let total_nodes = args.workers + 1; // workers + master
        let range_start = sqrt_limit + 1;
        let range_size = args.limit - sqrt_limit;
        let segment_size = (range_size + total_nodes as u64 - 1) / total_nodes as u64;

        // Send work to workers
        for (i, mut worker) in workers.iter_mut().enumerate() {
            let worker_id = i + 1; // Master is 0
            let low = range_start + (worker_id as u64 * segment_size);
            let high = std::cmp::min(low + segment_size - 1, args.limit);

            if args.verbose {
                println!("  Sending work to worker {}: [{}, {}]", worker_id, low, high);
            }

            let data = serialize_work(low, high, &base_primes);
            let len = data.len() as u32;

            worker
                .write_all(&len.to_le_bytes())
                .map_err(|e| format!("Send failed: {}", e))?;
            worker
                .write_all(&data)
                .map_err(|e| format!("Send failed: {}", e))?;
        }

        // Master does its own work
        let master_low = range_start;
        let master_high = std::cmp::min(master_low + segment_size - 1, args.limit);
        let master_primes = sieve_segment(master_low, master_high, &base_primes);
        let master_count = master_primes.len();

        if args.verbose {
            println!("  Master [{}, {}] -> {} primes", master_low, master_high, master_count);
        }

        // Collect results from workers
        let mut node_counts = vec![master_count];

        for (i, mut worker) in workers.iter_mut().enumerate() {
            let mut len_buf = [0u8; 4];
            worker
                .read_exact(&mut len_buf)
                .map_err(|e| format!("Read failed: {}", e))?;
            let count = u32::from_le_bytes(len_buf) as usize;

            if args.verbose {
                println!("  Worker {} returned {} primes", i + 1, count);
            }

            node_counts.push(count);
        }

        let elapsed = start_time.elapsed();
        let total_from_segments: usize = node_counts.iter().sum();
        let total_primes = base_primes.len() + total_from_segments;

        Ok(DistributedResult {
            total_primes,
            nodes: total_nodes,
            time_ms: elapsed.as_secs_f64() * 1000.0,
            node_counts,
            base_prime_count: base_primes.len(),
        })
    }

    /// Run as TCP worker
    pub fn run_worker(args: &Args) -> Result<(), String> {
        println!("Connecting to master at {}...", args.master_addr);

        let mut stream = TcpStream::connect(&args.master_addr)
            .map_err(|e| format!("Connection failed: {}", e))?;

        println!("Connected to master");

        // Receive work
        let mut len_buf = [0u8; 4];
        stream
            .read_exact(&mut len_buf)
            .map_err(|e| format!("Read failed: {}", e))?;
        let len = u32::from_le_bytes(len_buf) as usize;

        let mut data = vec![0u8; len];
        stream
            .read_exact(&mut data)
            .map_err(|e| format!("Read failed: {}", e))?;

        let (low, high, base_primes) = deserialize_work(&data);

        if args.verbose {
            println!("Received work: [{}, {}] with {} base primes", low, high, base_primes.len());
        }

        // Do the work
        let primes = sieve_segment(low, high, &base_primes);
        let count = primes.len();

        if args.verbose {
            println!("Found {} primes", count);
        }

        // Send result
        stream
            .write_all(&(count as u32).to_le_bytes())
            .map_err(|e| format!("Write failed: {}", e))?;

        println!("Result sent to master");

        Ok(())
    }
}

/// Result from distributed calculation
#[derive(Debug, Default)]
struct DistributedResult {
    total_primes: usize,
    nodes: usize,
    time_ms: f64,
    node_counts: Vec<usize>,
    base_prime_count: usize,
}

/// Single-node fallback
fn run_single_node(args: &Args) -> DistributedResult {
    let start_time = Instant::now();

    let primes = simple_sieve(args.limit);
    let count = primes.len();

    let elapsed = start_time.elapsed();

    DistributedResult {
        total_primes: count,
        nodes: 1,
        time_ms: elapsed.as_secs_f64() * 1000.0,
        node_counts: vec![count],
        base_prime_count: 0,
    }
}

fn print_results(result: &DistributedResult, args: &Args) {
    if args.csv {
        println!(
            "{},{},{:.3},{}",
            args.limit, result.nodes, result.time_ms, result.total_primes
        );
    } else {
        println!("═══════════════════════════════════════════════════════════");
        println!("           DISTRIBUTED PRIME CALCULATION RESULTS");
        println!("═══════════════════════════════════════════════════════════");
        println!("Configuration:");
        println!("  Limit: {}", args.limit);
        println!("  Nodes: {}", result.nodes);
        println!("───────────────────────────────────────────────────────────");
        println!("Results:");
        println!("  Total primes found: {}", result.total_primes);
        println!("  Base primes: {}", result.base_prime_count);
        println!("  Execution time: {:.3} ms", result.time_ms);
        println!("───────────────────────────────────────────────────────────");
        println!("Per-node breakdown:");

        for (i, count) in result.node_counts.iter().enumerate() {
            let label = if i == 0 { "Master" } else { "Worker" };
            println!("  {} {}: {} primes", label, i, count);
        }

        println!("═══════════════════════════════════════════════════════════");
    }
}

fn main() {
    let args = Args::parse();

    // Determine mode
    if args.worker {
        // TCP worker mode
        match tcp_impl::run_worker(&args) {
            Ok(()) => {}
            Err(e) => {
                eprintln!("Worker error: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }

    if args.tcp {
        // TCP master mode
        match tcp_impl::run_master(&args) {
            Ok(result) => print_results(&result, &args),
            Err(e) => {
                eprintln!("Master error: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }

    // Try MPI first
    #[cfg(feature = "mpi")]
    {
        match mpi_impl::run_mpi(&args) {
            Ok(result) => {
                // Only rank 0 prints results
                if result.nodes > 0 {
                    print_results(&result, &args);
                }
                return;
            }
            Err(e) => {
                eprintln!("MPI error: {}, falling back to single node", e);
            }
        }
    }

    // Fallback to single node
    if !args.csv {
        println!("Running in single-node mode (MPI not available)");
        println!("Use --tcp flag for TCP-based distribution");
        println!("");
    }

    let result = run_single_node(&args);
    print_results(&result, &args);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_sieve() {
        let primes = simple_sieve(100);
        assert_eq!(primes.len(), 25);
    }

    #[test]
    fn test_segment_sieve() {
        let base_primes = simple_sieve(10);
        let segment = sieve_segment(10, 30, &base_primes);
        assert_eq!(segment, vec![11, 13, 17, 19, 23, 29]);
    }

    #[test]
    fn test_single_node() {
        let args = Args {
            limit: 1000,
            csv: false,
            verbose: false,
            tcp: false,
            master_addr: "127.0.0.1:7878".to_string(),
            workers: 2,
            worker: false,
        };

        let result = run_single_node(&args);
        assert_eq!(result.total_primes, 168); // π(1000) = 168
    }
}
