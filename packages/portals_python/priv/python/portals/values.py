"""Host-language representations of the Erlang-specific value extensions
(`protocol/v1.md` section 5.1). Python has no persistent atom table, no
cons-cell lists, and cannot construct or interpret PIDs/references, so
these are opaque wrapper types rather than native Python values.
"""

from dataclasses import dataclass
from typing import Any, List


@dataclass(frozen=True)
class Atom:
    """A decoded Erlang atom. Python has no atom table, so this is just a
    named wrapper around the atom's text; equality/hash are by name."""

    name: str

    def __eq__(self, other):
        return isinstance(other, Atom) and self.name == other.name

    def __hash__(self):
        return hash(("portals.Atom", self.name))


@dataclass(frozen=True)
class Pid:
    """An opaque local or distributed Erlang PID. Trusted workers may
    store and echo this value (e.g. as a `MESSAGE` target) but must never
    attempt to construct or interpret its bytes."""

    raw: bytes


@dataclass(frozen=True)
class Reference:
    """An opaque Erlang reference. See `Pid` — same opacity rules apply."""

    raw: bytes


@dataclass(frozen=True)
class ImproperList:
    """An Erlang improper list `[items | tail]`, which Python's native
    list cannot represent."""

    items: List[Any]
    tail: Any
