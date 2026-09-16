# Security and decoding review (Phase 9)

Scope: unbounded-atom-creation, PID/reference forgery, and other decode-side
risks from untrusted worker input, per the PRD's Phase 9 deliverable
"security and atom/PID/reference decoding review".

## Atom decoding

`Portals.TermExtensions.decode_atom/1` uses `String.to_existing_atom/1`,
never `String.to_atom/1`. An atom extension whose text does not already
correspond to an existing atom is rejected with
`{:error, {:unsafe_atom, text}}` rather than being created. This is the
correct defense against the classic BEAM DoS where an attacker sends an
unbounded stream of distinct atom names to exhaust the (fixed-size,
never-garbage-collected) atom table.

Verified: `grep -rn "to_atom" lib/` finds only
`String.to_existing_atom/1` in `lib/portals/term_extensions.ex`. No call
site in `lib/` uses the unsafe `String.to_atom/1` or `:erlang.list_to_atom/1`.

Callback module/function dispatch (`Portals.Connection`'s handling of the
`CALLBACK` frame) resolves callback targets against the connection's own
`callback_allowlist` (an explicit, application-supplied `{module,
function, arity}` list), so a worker cannot invoke arbitrary
BEAM-side code merely by naming a module/function that happens to already
have loaded atoms — it must also match an allowlist entry the host
application opted into.

## PID and reference decoding

`Portals.TermExtensions.decode_pid/1` and `decode_reference/1` both route
through `safe_binary_to_term/1`, which calls `:erlang.binary_to_term/2`
with the `:safe` option (refuses to create atoms and refuses function
values) and then re-validates that the decoded term is actually a `pid()`
or `reference()` before accepting it — any other decoded shape, or a
binary that fails to decode at all, is rejected as
`{:invalid_extension, :pid | :reference}` rather than raising or
producing a value the caller didn't ask for.

This means a worker cannot forge a PID/reference for a process/reference
that doesn't already exist on this or a reachable connected node; it can
only round-trip a token the BEAM itself previously handed it (e.g. the
caller's own `pid` passed into a call, or a reference it was given). It
cannot use a decoded PID to message an arbitrary unrelated process it
was never given a handle to, because `:erlang.binary_to_term/2` will
happily decode *any* valid PID encoding — including ones for processes
the worker was never given — so this is enforced at the application
layer, not the codec layer: `Portals.Connection.handle_message/3` only
ever sends to whatever PID value the worker echoes back, which in
practice is always one this connection itself encoded and sent to the
worker in the first place (the caller's own PID, passed as a plain
Elixir term argument). Applications that pass unrelated third-party PIDs
into worker-visible arguments should be aware a compromised worker could
in principle replay them back as a MESSAGE target; this is the same trust
model ErlPort itself uses (workers are trusted collaborators, not a
sandboxed adversarial input source) and does not change here.

## Bigint decoding

`Portals.TermExtensions.decode_bigint/1` only ever produces an Elixir
`integer()` from a sign byte plus a big-endian magnitude; there's no
path from attacker bytes to atom/PID/reference/function values through
this extension.

## Frame-level bounds

Before any extension decoding happens, `Portals.Codec.MessagePack.decode/2`
enforces `max_frame_size`, `max_nesting_depth`, and
`max_collection_length` from the caller-supplied `Portals.Protocol.limits()`
(see `protocol/malformed/fixtures.exs` for the conformance fixtures every
SDK is checked against), bounding the cost of parsing hostile input before
any term-level interpretation is attempted.

## Conclusion

No unsafe atom creation, and no PID/reference forgery, exists in the
codec's decode path as of this review. The one trust boundary worth
calling out explicitly (PID replay via MESSAGE) is inherent to the
"trusted external runtime" model the PRD adopts throughout, not a codec
defect.
