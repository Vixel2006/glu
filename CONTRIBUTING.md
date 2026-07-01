# contributing

glu is built on the Unix philosophy: **do one thing and do it fucking well.**

glu is middleware. not a framework, not an operating system, not a build system. it publishes messages and subscribes to them. that's it. everything else is a separate tool that composes with glu.

we can't build this alone. whether you're a zig veteran, a robotics engineer tired of DDS, or just someone who wants to learn — you're welcome here.

no bureaucracy, no corporate gatekeeping. just code under the MIT license.

---

## the unix philosophy

glu is not ROS2. we don't build a monolithic stack that does everything poorly. we build small, sharp tools that compose:

- **glu is middleware** — it moves bytes between processes. no GUI, no scheduler, no sensor drivers, no navigation stack.
- **glu the CLI is a toolbox** — `glu launch` launches, `glu list` lists, `glu info` inspects. each command does exactly one thing and does it well.
- **if it can be a separate program, it should be** — viz, nav, drivers, and everything else live in their own repos and communicate via glu's protocol. keep the core razor-thin.
- **composition over monolith** — pipe glu with other Unix tools. write a sensor node in any language. swap out components without rewriting the world.

before contributing, ask: *"does this belong in the core, or can it be a separate tool that uses glu?"* if the answer is the latter, build it as a separate tool.

---

## table of contents

- [ways to contribute](#ways-to-contribute)
- [getting started](#getting-started)
- [development workflow](#development-workflow)
- [style guide](#style-guide)
- [testing & benchmarks](#testing--benchmarks)
- [pull request process](#pull-request-process)
- [good first issues](#good-first-issues)

---

## ways to contribute

you don't have to write zig code to help glu grow.

| skill | how to help |
| :--- | :--- |
| **zig** | implement features, fix bugs, optimize hot paths |
| **robotics** | write sensor drivers, test glu with real hardware, port to embedded targets |
| **documentation** | improve docs, fix typos, write tutorials, translate |
| **testing** | run glu on your hardware/OS, report bugs, write regression tests |
| **community** | answer questions on discord/github, write blog posts, make videos |
| **design** | improve the website, create diagrams, design the glu logo/branding |

---

## getting started

### prerequisites

- **zig 0.16.0** or later (install via [ziglang.org/download](https://ziglang.org/download) or your package manager)
- a **POSIX system** (linux is primary; macOS/BSDs should work but aren't battle-tested yet)
- **git**

### setup

```bash
git clone https://github.com/Vixel2006/glu
cd glu
zig build test
```

if all tests pass, you're good. if they don't, open an issue.

---

## development workflow

### 1. find something to work on

check the [issue tracker](https://github.com/Vixel2006/glu/issues) for open bugs or feature requests. look for the `good first issue` label if you're new.

### 2. create a branch

```bash
git checkout -b feature/your-feature-name
```

branch naming:
- `fix/` — bug fixes
- `feature/` — new functionality
- `docs/` — documentation changes
- `perf/` — performance optimizations
- `refactor/` — code restructuring

### 3. make your changes

keep changes focused. one feature or fix per PR. if you're refactoring, do it in a separate PR from feature work so diffs stay readable.

### 4. test your changes

```bash
zig build test
zig build bench   # check for performance regressions
```

---

## style guide

we keep it simple. glu's code style matches what zig's standard library uses.

### naming

- **types**: `PascalCase` — `Publisher`, `Subscriber`, `ChannelHeader`
- **functions**: `camelCase` — `init()`, `deinit()`, `publish()`, `receive()`
- **variables**: `snake_case` — `allocator`, `write_cursor`, `msg_size`
- **files**: `snake_case` — `channel.zig`, `codegen.zig`, `launch.toml`

### formatting

zig has a built-in formatter. run it before committing:

```bash
zig fmt src/
```

this is not optional — CI will reject unformatted code.

### what we value

| do | don't |
| :--- | :--- |
| write tools that do one thing well | add kitchen sinks and configuration flags for everything |
| compose with other programs | build monolithic frameworks that do it all |
| keep the core small and fast | pull in features that belong in userland |
| write clear, self-documenting code | add comments explaining what the code does (the code should say that) |
| use descriptive variable names | abbreviate everything until it's unreadable |
| keep functions small | write 300-line functions |
| handle errors explicitly | panic or silently ignore failures |
| test edge cases | assume everything works |

---

## testing & benchmarks

### running tests

```bash
zig build test
```

this runs all unit tests embedded in the source files. add `test` blocks to any file you modify.

### running benchmarks

```bash
zig build bench
```

benchmarks use [zBench](https://github.com/hendriknielaender/zbench) and results are tracked in `.benchmarks/`. if your change affects a hot path, compare before-and-after:

```bash
# before your change
git stash && zig build bench && git stash pop

# after your change
zig build bench
```

we don't have strict performance budgets yet, but don't make things slower without a good reason.

### manual testing with examples

```bash
zig build
glu launch -f examples/telemetry/launch.toml
```

run the provided examples to verify your changes work end-to-end. if you add a feature, consider adding an example for it.

---

## pull request process

1. **open an issue first** (optional but recommended) — describe what you're fixing or adding so we can agree on the approach before you write code.
2. **create a PR** with a clear title and description. link to any relevant issues.
3. **CI must pass** — tests, formatting, and benchmarks.
4. **review** — expect questions and feedback. this is not personal; we're all trying to make glu better.
5. **merge** — once approved, squash and merge. your commit message should follow conventional commits format: `type: brief description`.

### pr checklist

before submitting, make sure:

- [ ] `zig fmt src/` has been run
- [ ] `zig build test` passes
- [ ] `zig build` succeeds with no warnings
- [ ] new functions have doc comments
- [ ] changes don't break existing examples
- [ ] commit messages are clear and descriptive

---

## questions?

open a [discussion](https://github.com/Vixel2006/glu/discussions) or ping the maintainer on [twitter](https://x.com/this_vixel). we're friendly, we promise.

robots deserve better. let's build it together.
