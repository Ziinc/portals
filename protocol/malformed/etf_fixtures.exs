# Malformed-input fixtures for the ETF codec (protocol/v1.md section 5.4).
#
# Each entry is `{name, binary, expected_beam_reason}`. The BEAM decodes
# with `:erlang.binary_to_term/2`, which reports every malformed term as
# `:invalid_encoding`; `:ok` marks bytes the BEAM accepts (a valid Erlang
# term) that SDKs must still reject. How each SDK must classify every
# fixture is `Portals.Conformance.SDKSuite.expected_reasons(:etf)`.

[
  {"etf_empty_binary", <<>>, :invalid_encoding},
  {"etf_missing_version_byte", <<108, 0, 0, 0, 1, 97, 1, 106>>, :invalid_encoding},
  {"etf_truncated_list", <<131, 108, 0, 0, 0, 3, 97, 1>>, :invalid_encoding},
  {"etf_truncated_binary", <<131, 109, 0, 0, 0, 10, "short">>, :invalid_encoding},
  {"etf_unknown_tag", <<131, 200>>, :invalid_encoding},
  {"etf_oversized_list_length", <<131, 108, 0xFF, 0xFF, 0xFF, 0xFF>>, :invalid_encoding},
  {"etf_unknown_atom", <<131, 119, 20, "not_a_real_atom_xyzq">>, :invalid_encoding},
  {"etf_trailing_bytes", <<131, 97, 1, 0>>, :ok},
  {"etf_binary_not_utf8", <<131, 109, 0, 0, 0, 2, 0xC3, 0x28>>, :ok},
  {"etf_bit_binary", <<131, 77, 0, 0, 0, 1, 3, 0xE0>>, :ok},
  {"etf_nesting_too_deep", <<131>> <> :binary.copy(<<108, 0, 0, 0, 1>>, 40) <> <<97, 1>> <> :binary.copy(<<106>>, 40), :ok},
  # Streaming frames (protocol/v1.md section 9).
  {"etf_truncated_stream_data_chunk",
   <<131, 108, 0, 0, 0, 3, 97, 11, 97, 7, 109, 0, 0, 0, 16, "short">>, :invalid_encoding}
]
