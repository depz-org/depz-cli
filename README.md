# depz

A CLI dependency manager for Zig projects.

depz wraps `zig fetch` with npm-style ergonomics: short repo specs, version
tags, update checking, and registry selection — so managing `build.zig.zon`
dependencies feels less manual.

> **Early but usable.** The core commands work and are tested. Expect breaking
> changes before 1.0 — the CLI surface and `build.zig.zon` metadata may still shift.

## Requirements

- **Zig `0.17.0-dev.1441+d5181a9c9`** — depz is built against a development build and pins it deliberately.
- **`git`** on your `PATH` — depz shells out to `zig fetch` and `git ls-remote`.

## Install

### Download a binary

Grab the binary for your platform from the [latest release](https://github.com/depz-org/depz-cli/releases/latest):

- `depz-x86_64-linux`, `depz-aarch64-linux`
- `depz-x86_64-macos`, `depz-aarch64-macos`
- `depz-x86_64-windows.exe`

Verify it with the matching `.sha256`, make it executable (`chmod +x`), and put it on your PATH.

### Or build from source

git clone https://github.com/depz-org/depz-cli
cd depz-cli
zig build

```sh
git clone https://github.com/depz-org/depz-cli
cd depz-cli
zig build
```

The binary lands at `zig-out/bin/depz`. Put it on your `PATH`, or run it directly.

## Usage

Run inside a Zig project (one with a `build.zig.zon`).

### Add a dependency

```sh
# a specific tag
depz add depz-org/example@v1.0.0

# latest commit on the default branch
depz add depz-org/example

# from a non-GitHub host
depz add foreverzer0/klack@v1.1.0 --registry=codeberg.org

# rename the dependency (e.g. two deps whose repos share a name would
# otherwise collide — the second silently overwrites the first)
depz add depz-org/example@v1.0.0 --as=depz_org_example
```

depz builds the `git+https://…` URL, runs `zig fetch --save`, and lets Zig
resolve and pin the exact commit into `build.zig.zon`. GitHub is the default
host; `--registry` overrides it per command, and a project-level
`.depz = .{ .registry = "…" }` in `build.zig.zon` sets a default for the project.

### List dependencies

```sh
depz list
```

```
2 dependencies

  example        v1.0.0
  httpz          git (52eb187c)
```

### Check for updates

```sh
depz list --check
```

```
Checking 2 dependencies

  example    v1.0.0  → v2.0.0

1 up to date. Run with --all to show them.
```

By default only outdated dependencies are shown. Options:

- `--all` — also list dependencies that are up to date
- `--target=<latest|minor|patch>` — how far to look for updates
  (`latest` is the default; `minor` stays within the current major; `patch`
  stays within the current minor)

Tag-pinned dependencies are compared by version; dependencies tracking a branch
are compared by commit.

## How it works

depz is a thin layer over Zig's own tooling — it does not host packages or run a
registry. `add` delegates downloading and hashing to `zig fetch --save`; update
checks read the pinned ref from each dependency's URL and query the upstream git
host with `git ls-remote`. Everything lives in your existing `build.zig.zon`.

## License

Dual-licensed under [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your option.

Contributions are welcome and, unless you state otherwise, are understood to be
dual-licensed under the same terms.