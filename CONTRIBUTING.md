# Contributing

This is a small project with a specific temperament, and most of what follows is
about that rather than about process. There is no CLA, no template to fill in
and no review board. There is an expectation that a change arrives explained.

Before anything else: [`README.md`](README.md) has how to build both halves, and
[`SECURITY.md`](SECURITY.md) has what the project already promises about
transport, secrets and outgoing data. A change that quietly breaks one of those
promises is the one kind of change that will simply be reverted.

## AI is used here, and that is fine

Much of this codebase was written with AI assistance, and a contributor using it
is welcome to. There is nothing to declare and no separate standard to meet.

What is not welcome is **unread output**. Whoever opens the pull request is the
person answering for what is in it — every line, including the ones they did not
type. If a reviewer asks why something is the way it is, "the model wrote it" is
not an answer; it is the point at which the change stops.

The practical test is simple: can you explain what each hunk does, and what
would break if it were removed? If not, that hunk is not ready, whatever
produced it.

## Run the tests before opening anything

```bash
make test
```

That covers the Rust workspace and the Dart side, and it is hermetic — no
network, no Docker, no local server. There is no reason not to run it.

```bash
make fix
```

Formats and auto-fixes both halves, then re-lints, so a fix that breaks
something is caught in the same command. Run it last, before committing.

CI runs lint and test as separate workflows so a formatting slip and a broken
test report as two different failures. It is the **second** check, not the
first: a red CI on a pull request that was never run locally wastes a reviewer's
attention on something the author could have seen in thirty seconds.

The end-to-end tests need a real IRC server and are `#[ignore]`d for that reason.
If a change touches the connection path, run them:

```bash
make dev-server
make test-integration
```

## Be careful, and say what you changed

Much of this codebase is load-bearing in ways that are not local. The parts
where a small change reaches furthest:

- **`irc-core/ddirc-core/src/conn/`** — the connection actor and its `select!`
  loop. Ordering, cancellation and timeouts here decide whether a client hangs
  or recovers, and none of it is visible from the call site.
- **The FFI boundary** (`irc-core/ddirc-bridge/`, and the generated Dart under
  `lib/src/rust/`). Generated code is committed so CI needs no codegen
  toolchain; regenerate with `make codegen` and commit the result in the same
  change that caused it, never separately.
- **Anything touching credentials** — SASL, the profile store, what is held in
  memory and for how long. `SECURITY.md` says what is promised; the promise is
  the specification.
- **The proxy path.** The interesting failure is not that a connection breaks,
  it is that it succeeds by a route the user did not choose. Any change that
  can cause a name to be resolved or a socket to be opened outside the
  configured proxy is a security change, whatever else it is.

A change in those places wants its reasoning in the **commit message**, not only
in the diff. `git log` is where this project keeps the "why" — the file itself
carries the "what" — so the message should say what was wrong, what was done
about it, and what was considered and rejected. Read a few before writing one:
they are prose, lower-case subject lines scoped like `conn:` or `ui:`, and they
are long where the decision was hard.

Comments follow the same rule. Explain what the code cannot say for itself —
the constraint, the failure that motivated it, the option that looks better and
is not. Do not narrate the line below.

## Prose

British spelling, in documentation and in code (`licence`, `recognises`). Not a
matter of principle, just consistency with what is already here.

## Licence

Contributions are under **GPL-3.0-or-later**, the same as the rest. There is
nothing to sign; opening a pull request is the agreement. See the licence
section of the README for what that rules out — app store distribution, among
other things — because it is a decision the project has already made rather than
an oversight.

## Security

Do not open a pull request for a vulnerability. `SECURITY.md` says how to report
one.
