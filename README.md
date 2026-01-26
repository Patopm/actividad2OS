# OS Parallel Project (RHEL)

Monorepo demonstrating:
- Part 1: sequential vs multithreaded computation
- Part 2: scheduling policies (CFS / FIFO / RR)
- Part 3: distributed execution using real MPI (OpenMPI) + Docker cluster simulation
- Part 4: I/O device identification and OS I/O management analysis

## Requirements (RHEL)

- RHEL 9.x (or compatible like Rocky/Alma for local)
- Rust (via rustup)
- Node.js + pnpm
- OpenMPI (for real MPI runs)
- Docker + Docker Compose plugin (for simulated cluster)

The repository includes:
- `./scripts/setup-rhel.sh` to install dependencies (OpenMPI, Docker, tools)

## Repository Layout

```text
apps/
  primes-sequential/     # Part 1 baseline
  primes-multithread/    # Part 1 parallel version
  scheduler-sim/         # Part 2 scheduling policies + metrics
  primes-mpi/            # Part 3 distributed version (MPI feature gated)
scripts/
  setup-rhel.sh
  benchmark.sh
  scheduler-test.sh
  cluster-setup.sh
  cluster-run.sh
  io-analysis.sh
  run-all.sh
docs/
results/
docker/
```

## Install (RHEL)

```bash
sudo ./scripts/setup-rhel.sh
source ~/.bashrc
pnpm install
```

## Build

```bash
pnpm turbo run build
```

## Run Part 1 (Benchmarks)

```bash
pnpm turbo run bench:all
```

Outputs:
- `results/benchmark-sequential.csv`
- `results/benchmark-multithread.csv`
- `results/comparison-report.txt`

## Run Part 2 (Scheduling)

Basic tests (no sudo):

```bash
pnpm turbo run scheduler:test -- basic
```

Real-time tests (usually requires sudo):

```bash
sudo pnpm turbo run scheduler:test -- realtime
```

Outputs:
- `results/scheduler-basic.csv`
- `results/scheduler-realtime.csv` (if permitted)
- `results/scheduler-analysis-report.md`

## Run Part 3 (Distributed / MPI Cluster)

### Build primes-mpi with MPI support

The `primes-mpi` app is feature-gated. Build it with:

```bash
cargo build --release -p primes-mpi --features mpi
```

### Start Docker cluster and run MPI

```bash
pnpm turbo run cluster:setup
pnpm turbo run cluster:run
```

Or benchmark distributed modes:

```bash
./scripts/cluster-run.sh benchmark
```

Outputs:
- `results/benchmark-mpi.csv`
- `results/cluster-comparison-report.md`

## Run Part 4 (I/O Analysis)

```bash
pnpm turbo run io:analyze
```

Outputs:
- `results/io-analysis-report.md`
- `results/io-raw/*.txt`

## Full End-to-End Run

Default (no realtime, no mpi):

```bash
pnpm turbo run all
```

With realtime scheduling + mpi cluster + distributed benchmark:

```bash
sudo ./scripts/run-all.sh --with-realtime --with-mpi --with-mpi-bench
```

## Documentation

- `docs/part1-multithreading.md`
- `docs/part2-scheduling.md`
- `docs/part3-cluster.md`
- `docs/part4-io-management.md`
