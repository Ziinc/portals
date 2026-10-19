# Releasing

Core `portals` and every `portals_<language>` package are released
together, at one version, from one commit tagged `vX.Y.Z`. The wire
protocol requires an exact version match, so an SDK and the BEAM side must
never drift apart. Everything is published to Hex only; no SDK goes to a
language registry.

## Versions

`scripts/version.exs` knows every place a version lives: each `mix.exs`
plus the constant each SDK reports in its handshake (`portals.__version__`,
`Portals::VERSION`, `package.json`, `composer.json`, `Portals.VERSION`,
`portals.Version`).

```sh
elixir scripts/version.exs check        # also runs as part of core's mix test
elixir scripts/version.exs bump 0.2.0   # rewrite all of them
```

Patch releases must not change the wire protocol: language packages depend
on `portals ~> X.Y.Z`, which accepts newer patch releases of core.

## Steps

1. `elixir scripts/version.exs bump X.Y.Z`, update the changelog, and
   merge that to `main` through a pull request. Its CI already runs the
   release dry run below.
2. On an up-to-date `main`, `scripts/release.sh`: it checks the tree is
   clean, every version location agrees and the tag doesn't exist yet,
   runs `scripts/test_all.sh`, then `scripts/hex_dry_run.sh`.
3. `scripts/release.sh --tag` does the same, then tags `vX.Y.Z` and
   pushes the tag. (Pushing a tag yourself does the same thing.)

The tag starts `.github/workflows/release.yml`:

1. **Check the tag**: it must equal `v` + the version in `mix.exs`, and be
   on `main`.
2. **CI**: all of `ci.yml`, including the *Release dry run* job.
3. **Publish to Hex**: `scripts/publish_hex.sh`, in the `hex` environment.
   It publishes `portals` first, then each language package with
   `PORTALS_PUBLISH=1` (which swaps the path dependency on core for
   `{:portals, "~> X.Y.Z"}` from Hex), waiting for the new core to reach
   the registry if needed. `mix hex.publish` also publishes each package's
   docs to hexdocs.

Nothing is published unless every earlier job passed.

## The dry run

`scripts/hex_dry_run.sh` runs on every pull request and before every
release. It builds exactly what would be published, uploads nothing, and
leaves the tarballs in `_build/release/` (CI keeps them as the
`hex-packages` artifact):

- every package's docs, with warnings as errors;
- core with `mix hex.publish --dry-run`;
- each language package with `mix hex.build` in publish mode, so its
  tarball carries the Hex requirement on core. `hex.publish --dry-run`
  can't be used for these: it fetches dependencies, and that version of
  core isn't on Hex until the release publishes it.

## Setup (once)

- Create a Hex API key with *API write* permission at
  <https://hex.pm/dashboard/keys>, as a user who owns (or, before the
  first release, will own) all seven packages.
- In the GitHub repository settings, create an environment named `hex`
  with a `HEX_API_KEY` secret holding that key. Add required reviewers to
  the environment to make each publish wait for a manual approval, and
  restrict which tags can be pushed with a tag ruleset for `v*`.

## When a release fails

- **Before publishing** (tag check, CI): fix it on `main`, then move the
  tag: `git tag -d vX.Y.Z && git push origin :vX.Y.Z`, and tag again.
- **During publishing**: re-run the failed *Publish to Hex* job.
  `scripts/publish_hex.sh` skips every package whose version is already
  on Hex, so it picks up where it stopped. With credentials it can also be
  run locally: `HEX_API_KEY=... scripts/publish_hex.sh`.
- **A bad release**: Hex lets you revert a version within an hour of
  publishing it (24 hours for a package's first version) with
  `mix hex.publish --revert X.Y.Z`, per package. After that, fix it with a
  new version and retire the broken one with `mix hex.retire` for every
  package.

Running `scripts/release.sh` needs Elixir 1.15+ (for ExDoc) and the toolchains
`scripts/test_all.sh` uses.

## Notes

- `priv/java/portals.jar` is a build artifact (gitignored) that ships
  prebuilt in `portals_java`. `mix portals_java.jar` builds it with
  `javac --release 17`; the dry run and publish scripts build it before
  packaging.
- The Go SDK is published only inside `portals_go`. Applications reach it
  through a `replace` directive into `deps/`, so there are no Go module
  tags.
