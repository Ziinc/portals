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
   commit.
2. `scripts/release.sh`, a dry run. It checks the tree is clean, verifies
   every version location, runs `scripts/test_all.sh`, builds the Java
   SDK's `portals.jar`, and builds every Hex tarball into `_build/release/`.
3. `scripts/release.sh --publish`. This publishes `portals` first, then
   each language package with `PORTALS_PUBLISH=1` (which swaps the path
   dependency on core for `{:portals, "~> X.Y.Z"}` from Hex), then tags and
   pushes `vX.Y.Z`. `mix hex.publish` also publishes each package's docs to
   hexdocs.

Releases need Elixir 1.15+ (for ExDoc) and Hex credentials for every
package.

## Notes

- `priv/java/portals.jar` is a build artifact (gitignored) that ships
  prebuilt in `portals_java`. `mix portals_java.jar` builds it with
  `javac --release 17`; the release script runs it before building
  tarballs.
- The Go SDK is published only inside `portals_go`. Applications reach it
  through a `replace` directive into `deps/`, so there are no Go module
  tags.
- A bad release is fixed with a new version. Retire the broken one with
  `mix hex.retire` for every package at once.
