# apk-forge

The shared half of an "unofficial Android build" repo: ranking upstream refs, refusing to build
what's already published, restoring a signing keystore, **gating on the signing certificate**,
publishing a release for [Obtainium](https://github.com/ImranR98/Obtainium), and noticing when
upstream starts shipping APKs itself so the repo can be retired.

It exists because that scaffold is now written twice — [`fredabood/buzz`](https://github.com/fredabood/buzz)
and [`fredabood/omnigent`](https://github.com/fredabood/omnigent) — and the parts worth not
diverging are the parts that fail quietly when they drift.

## What it does *not* do

It does not build your app. Toolchains have nothing in common: Buzz is Flutter under a Hermit-pinned
JDK, Omnigent is Gradle under temurin 17. Each caller supplies its own build as a local composite
action, and that boundary is deliberate — see below.

## Why composite actions, not one `workflow_call` workflow

The obvious design is a single reusable workflow that takes "the build" as an input. It cannot work:
**GitHub Actions does not allow expressions in a step's `uses:`**, so a reusable workflow cannot
invoke an action named by its caller. The two ways around that are both worse:

- pass the build as a **shell string** input and `run:` it — which turns the scaffold into a
  snippet-passing machine, unlintable and unreviewable;
- vendor every toolchain into this repo — which makes a shared component grow a branch per app.

So the caller owns its workflow and its build step, and calls this repo for the four generic
phases. Same separation, one that composes.

## The four actions

| Action | Does |
|---|---|
| `resolve-ref` | Picks the newest upstream ref, dedupes against published releases, applies an optional path filter. Outputs `ref`, `version`, `version-code`, `should-build`, `reason`. |
| `restore-keystore` | Decodes a base64 keystore secret to an absolute path in `RUNNER_TEMP`, failing loudly on an empty decode. |
| `verify-and-publish` | Reads the built APK's certificate, **refuses to publish on any deviation**, then cuts the release. |
| `sunset-watch` | Opens one discontinue notice when upstream ships an official Android channel. |

Reference them as `fredabood/apk-forge/.github/actions/<name>@main`.

## Three traps this encodes

Each of these cost someone a debugging session; they are the reason the logic is shared rather
than copied.

**Refs sort lexically.** `git/matching-refs` and `git tag` return `0.10.0` *before* `0.4.0`, so
`sort | tail -1` silently picks an older release. `scripts/rank-refs.sh` ranks on a parsed
`maj*1000000 + min*10000 + pat*100 + rc` key, with `rc = 99` for a plain release so `1.2.3`
outranks all of its own candidates. It exits non-zero and prints nothing when no ref matches —
a ranker that returns a "winner" from an empty set just makes the caller build garbage.

**The compare API lies about paths.** `repos/{}/compare/{a}...{b}` truncates its file list, so a
multi-release range reports *zero* changes to a path that demonstrably changed. Measured on
`omnigent-ai/omnigent`: `v0.7.0...v0.12.0` reports 0 files under `web/android/`, while the last
commit touching that path differs at every single release in between. `resolve-ref`'s path filter
therefore compares **the last commit touching the path at each ref**, never a compare diff.

**An unsigned build is a green build.** Gradle and Flutter both skip release signing *silently*
when credentials are absent — no warning, exit 0, an unsigned APK. And an APK signed with a
different key can never update an installed one. So `verify-and-publish` treats the certificate
check as a publish gate, not a report, and `restore-keystore` fails on an empty decode rather than
letting a truncated secret reach the build.

## Using it

Copy `templates/caller-workflow.yml` into your app repo, fill in the eight values at the top, and
add a `.github/actions/build/action.yml` that knows your toolchain. Your build action receives
`keystore-path`, `keystore-password`, `key-alias`, `key-password`, `version-name` and
`version-code`, and is expected to output `apk-path`. Mapping those to whatever environment
variables your build system wants is your action's job — Buzz maps them to `BUZZ_ANDROID_UPLOAD_*`,
Omnigent to `OMNIGENT_KEYSTORE_*`, both of which are the upstream projects' own contracts, so
neither repo patches upstream source to build.

Secrets live in the caller repo. This repo holds none.

## A fourth trap: `required:` is not enforced

**GitHub does not enforce `required: true` on composite-action inputs.** A missing one arrives as an
empty string, and the failure surfaces later somewhere unrelated — an empty keystore secret becomes
an *unsigned APK*, not a missing-input error. Every action here therefore guards its own inputs and
fails naming the one that is absent. Treat the `required:` field in the schemas below as
documentation, not as a gate; the guards are the gate.

## Tests

```sh
bash scripts/rank-refs.test.sh
bash scripts/skip-decision.test.sh
```

Every assertion is paired with a **red proof**: the suite re-runs it against a deliberately broken
copy of the ranker and fails if the broken copy still passes. One of those proofs is itself
instructive — swapping `sort -n` for `sort` does *not* break the ranking, because the sort key is
zero-padded, so that defect proves nothing and is documented as a non-proof rather than shipped as
a reassuring green tick.

## Not affiliated with the upstream projects

Repos built on this scaffold redistribute other people's software. They are responsible for their
own licence compliance, attribution and disclaimers; this repo only moves bytes.
