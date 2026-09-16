# Malformed-input fixtures for the Portals v1 codec.
#
# Each entry is `{name, binary, expected_error_shape}`. A conforming
# decoder must reject every fixture without raising, terminating only the
# connection that produced it (per FR-4 / non-functional reliability
# requirements). `expected_error_shape` is matched loosely: only the
# leading atom of the `{:error, reason}` tuple's `reason` (or the reason
# itself when it's a bare atom) is checked, since exact byte counts are
# codec-internal detail.

[
  {"truncated_fixarray", <<0b1001::4, 3::4, 0x01>>, :truncated},
  {"truncated_str8_header", <<0xD9>>, :truncated},
  {"truncated_str8_body", <<0xD9, 10, "short">>, :truncated},
  {"unknown_leading_byte", <<0xC1>>, :invalid_encoding},
  {"oversized_array_length", <<0xDD, 0xFF, 0xFF, 0xFF, 0xFF>>, :max_length_exceeded},
  {"unsafe_atom_extension", <<0xC7, 20, 1, "not_a_real_atom_xyzq">>, :unsafe_atom},
  {"invalid_extension_type", <<0xD4, 99, 0>>, :invalid_extension},
  {"bad_tuple_ext_trailing_bytes", <<0xC7, 2, 0, 0x90, 0x01>>, :trailing_bytes},
  {"empty_binary", <<>>, :truncated},
  # Streaming frames (protocol/v1.md section 9). These are codec-level
  # rejections; frame-arity rejection (e.g. a CREDIT with four fields) is
  # checked by `Portals.Protocol.validate_envelope/1` after decoding.
  {"truncated_stream_data_chunk",
   <<0b1001::4, 3::4, 11, 7, 0xC4, 16, "short">>, :truncated},
  {"truncated_credit_frame", <<0b1001::4, 3::4, 11, 7>>, :truncated}
]
