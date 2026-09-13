# Golden round-trip vectors for the Portals v1 protocol value model.
#
# Loaded by `test/conformance/protocol_conformance_test.exs` and by any
# third-party SDK's conformance suite. Each entry is `{name, term}`; a
# conforming codec must encode `term` to a frame envelope and decode that
# encoding back to a term that is `===` to the original (or, for floats,
# numerically equal).
#
# `term` is always a complete frame envelope: `[tag | fields]`.

alias Portals.Protocol
alias Portals.Codec.Bin

[
  {"hello_minimal", [Protocol.frame_tag(:hello), 1, "python3.11", 16, 4, []]},
  {"ready_minimal",
   [
     Protocol.frame_tag(:ready),
     1,
     Map.new(Protocol.default_limits(), fn {k, v} -> {Atom.to_string(k), v} end)
   ]},
  {"call_no_kwargs",
   [Protocol.frame_tag(:call), 1, "embedding", "encode", [%{"text" => "hello"}]]},
  {"call_with_timeout",
   [Protocol.frame_tag(:call), 2, "bench_worker", "echo", [%Bin{data: <<0, 1, 2, 3>>}], 5_000]},
  {"return_null", [Protocol.frame_tag(:return), 1, nil]},
  {"return_nested",
   [
     Protocol.frame_tag(:return),
     1,
     %{
       "ok" => true,
       "count" => 42,
       "items" => [1, 2, 3, -1],
       "ratio" => 0.5,
       "tag" => :ok,
       "big" => 123_456_789_012_345_678_901_234_567_890,
       "improper" => [1, 2 | :tail]
     }
   ]},
  {"error_struct",
   [
     Protocol.frame_tag(:error),
     1,
     %{"kind" => "remote", "message" => "boom", "details" => %{}}
   ]},
  {"cancel", [Protocol.frame_tag(:cancel), 1]},
  {"callback", [Protocol.frame_tag(:callback), 100, "MyApp.Handler", "on_progress", [0.5]]},
  {"callback_return", [Protocol.frame_tag(:callback_return), 100, "ok"]},
  {"message_to_pid", [Protocol.frame_tag(:message), self(), %{"hello" => "world"}]},
  {"stream_data", [Protocol.frame_tag(:stream_data), 1, %Bin{data: <<1, 2, 3>>}]},
  {"credit", [Protocol.frame_tag(:credit), 1, 65_536]},
  {"half_close", [Protocol.frame_tag(:half_close), 1]},
  {"ping", [Protocol.frame_tag(:ping), 1]},
  {"pong", [Protocol.frame_tag(:pong), 1]},
  {"shutdown", [Protocol.frame_tag(:shutdown)]},
  {"tuple_value", [Protocol.frame_tag(:return), 1, {:ok, "value", 3}]},
  {"empty_array", [Protocol.frame_tag(:return), 1, []]},
  {"empty_map", [Protocol.frame_tag(:return), 1, %{}]},
  {"negative_ints",
   [Protocol.frame_tag(:return), 1, [-1, -32, -33, -128, -129, -32768, -32769]]},
  {"large_binary", [Protocol.frame_tag(:return), 1, %Bin{data: :binary.copy(<<0>>, 70_000)}]}
]
