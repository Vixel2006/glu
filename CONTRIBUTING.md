# Contributing to GLU

Welcome! `glu` is a next-generation robotics communication middleware designed with love for developers. It is built to be a zero-dependency, high-performance, and reliable.

We do not follow general "Unix philosophy" dogmas. Instead, we do **just enough things to make it function exceptionally well**, with a beautiful developer API, high performance, and simple, correct concepts.

We value technical excellence, hard design decisions, and taking the time required to build great software. Great things take time, effort, and care.

---

## The GLU Core Philosophy: TigerStyle

We believe that code for next-generation robotics must be written to the highest standards of safety, performance, and correctness. To achieve this, we follow a style inspired by **TigerStyle** (from the TigerBeetle project):

1.  **Correctness First**: We write code that is correct under all conditions. Correctness is not sacrificed for features or fast releases.
2.  **Explicit Control Flow**: No magic hidden under layers of abstractions. Control flow must be clear and direct. Error handling is always explicit; we do not ignore errors or panic unless an invariant is broken.
3.  **Zero-Allocation Hot Path**: Hot paths must not allocate memory dynamically. All buffers and mappings are allocated statically or pre-allocated during initialization.
4.  **Zero Dependencies**: We build a standalone, zero-dependency ecosystem. We link against POSIX libc, but otherwise keep our dependency tree entirely empty.
5.  **Made with Love for Developers**: The developer experience is a primary feature. The API must be intuitive, self-documenting, and robust against common user errors.
6.  **Patience & Quality**: We take our time to make the codebase as good as possible. We prioritize deliberate engineering, thorough testing, and clean design over quick hacks.

---

## Table of Contents

- [Ways to Contribute](#ways-to-contribute)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Style Guide](#style-guide)
- [Testing & Benchmarks](#testing--benchmarks)
- [Pull Request Process](#pull-request-process)

---

## Ways to Contribute

You do not have to write Zig code to help `glu` grow.

| Skill | How to Help |
| :--- | :--- |
| **Coding** | Optimize hot paths, implement features, fix bugs |
| **Robotics & Hardware** | Test `glu` with real-world sensors, actors, and embedded platforms |
| **Documentation** | Improve code docs, write tutorials, provide clear usage guides |
| **Verification & Testing** | Find edge cases, write rigorous unit/integration tests, test memory safety |

---

## Getting Started

### Prerequisites

*   **Zig 0.17.0-dev** (or the version specified in the root `build.zig.zon`)
*   A **POSIX system** (Linux is primary and required for `io_uring` support)
*   **Git**

### Setup

```bash
git clone https://github.com/Vixel2006/glu
cd glu
zig build test
```

If all tests pass, you are ready to begin. If you hit any environment setup errors, please open a GitHub issue.

---

## Development Workflow

### 1. Create a Branch
Work on a separate git branch for your feature or fix:
```bash
git checkout -b feature/your-feature-name
```
Branch prefix conventions:
*   `fix/` — bug fixes
*   `feature/` — new functionality
*   `docs/` — documentation updates
*   `perf/` — performance optimizations
*   `refactor/` — code cleanup

### 2. Make Focused Changes
Keep your commits and pull requests small and focused. Refactors and new features should be submitted in separate PRs to keep code reviews clear and productive.

### 3. Verify Code Locally
Before pushing your branch, ensure all tests and benchmarks run cleanly:
```bash
zig build test
zig build bench
```

---

## Style Guide

We keep our code clean, consistent, and well-structured, matching Zig's standard library conventions.

### Naming Conventions
*   **Types / Structs**: `PascalCase` (e.g. `Publisher`, `Subscriber`, `Channel`)
*   **Functions / Methods**: `snake_case` (e.g. `init()`, `deinit()`, `send_to()`)
*   **Variables / Fields**: `snake_case` (e.g. `allocator`, `write_cursor`, `msg_size`)
*   **Source Files**: `snake_case` (e.g. `channel.zig`, `root.zig`)

### Formatting
Always format your code before committing. The CI system will reject any unformatted contributions.
```bash
zig fmt src/
```

### Code Values (TigerStyle)

| Do | Don't |
| :--- | :--- |
| Write simple, clear, and explicit code | Write overly clever or obfuscated code |
| Handle all errors explicitly | Silently ignore errors or panic on expected path failures |
| Keep functions focused and well-scoped | Write giant functions with excessive responsibilities |
| Choose static/pre-allocated memory | Perform hidden heap allocations in performance loops |
| Maintain self-documenting code with clear doc comments | Leave complex algorithms completely undocumented |
| Take time to refine designs and implement cleanly | Rush implementations with dirty quick-fixes |

---

## Testing & Benchmarks

### Running Unit Tests
All source files containing logic should include unit tests to verify correctness:
```bash
zig build test
```

### Running Benchmarks
If you modify performance-critical segments (like `Channel`, `Publisher`, or transport loops), always check for regressions:
```bash
zig build bench
```

---

## Pull Request Process

1.  **Refine the Design**: Describe your plan or open a design discussion before starting on larger features. Great code requires consensus on architectural choices.
2.  **Run formatting**: Ensure `zig fmt` has been run on all modified files.
3.  **Pass CI Checks**: Confirm all unit tests and builds compile without warnings.
4.  **Squash and Merge**: Once approved, squashed commits should follow clear, descriptive conventional messages (e.g. `feat: implement multicast UDP support`).

---

Robots deserve better, highly engineered software. Let's build it with excellence.
