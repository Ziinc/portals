defmodule Portals.TermExtensions do
  @moduledoc """
  Erlang-specific value extensions layered on top of core MessagePack.

  Each extension is a MessagePack `ext` payload tagged with one of the type
  codes below. Encoding is always safe. Decoding never creates atoms and
  never fabricates PIDs/references from arbitrary bytes: it delegates to
  `:erlang.binary_to_term/2` with the `:safe` option (which refuses to
  create new atoms and refuses function values) and then re-validates the
  resulting term's shape before accepting it.
  """

  @tuple_ext 0
  @atom_ext 1
  @pid_ext 2
  @reference_ext 3
  @bigint_ext 4
  @improper_list_ext 5

  @type ext_type :: :tuple | :atom | :pid | :reference | :bigint | :improper_list

  @spec ext_type_code(ext_type) :: non_neg_integer
  def ext_type_code(:tuple), do: @tuple_ext
  def ext_type_code(:atom), do: @atom_ext
  def ext_type_code(:pid), do: @pid_ext
  def ext_type_code(:reference), do: @reference_ext
  def ext_type_code(:bigint), do: @bigint_ext
  def ext_type_code(:improper_list), do: @improper_list_ext

  @spec ext_type_name(non_neg_integer) :: {:ok, ext_type} | :error
  def ext_type_name(@tuple_ext), do: {:ok, :tuple}
  def ext_type_name(@atom_ext), do: {:ok, :atom}
  def ext_type_name(@pid_ext), do: {:ok, :pid}
  def ext_type_name(@reference_ext), do: {:ok, :reference}
  def ext_type_name(@bigint_ext), do: {:ok, :bigint}
  def ext_type_name(@improper_list_ext), do: {:ok, :improper_list}
  def ext_type_name(_), do: :error

  @doc "Encode an atom as its UTF-8 text. Any atom, including unicode atoms, is representable."
  @spec encode_atom(atom) :: binary
  def encode_atom(atom) when is_atom(atom), do: Atom.to_string(atom)

  @doc """
  Decode atom bytes to an existing atom only. Never creates a new atom.
  Returns `{:error, {:unsafe_atom, text}}` if the atom does not already exist.
  """
  @spec decode_atom(binary) :: {:ok, atom} | {:error, {:unsafe_atom, binary}}
  def decode_atom(bytes) when is_binary(bytes) do
    {:ok, String.to_existing_atom(bytes)}
  rescue
    ArgumentError -> {:error, {:unsafe_atom, bytes}}
  end

  @doc "Encode a local or distributed PID using `:erlang.term_to_binary/1`."
  @spec encode_pid(pid) :: binary
  def encode_pid(pid) when is_pid(pid), do: :erlang.term_to_binary(pid)

  @doc """
  Decode PID bytes safely: only ever accepts input that `:erlang.binary_to_term/2`
  with `:safe` decodes to an actual `pid()`. Any other shape is rejected without
  raising and without creating atoms.
  """
  @spec decode_pid(binary) :: {:ok, pid} | {:error, {:invalid_extension, :pid}}
  def decode_pid(bytes) when is_binary(bytes) do
    case safe_binary_to_term(bytes) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _ -> {:error, {:invalid_extension, :pid}}
    end
  end

  @spec encode_reference(reference) :: binary
  def encode_reference(ref) when is_reference(ref), do: :erlang.term_to_binary(ref)

  @spec decode_reference(binary) :: {:ok, reference} | {:error, {:invalid_extension, :reference}}
  def decode_reference(bytes) when is_binary(bytes) do
    case safe_binary_to_term(bytes) do
      {:ok, ref} when is_reference(ref) -> {:ok, ref}
      _ -> {:error, {:invalid_extension, :reference}}
    end
  end

  @doc "Encode an arbitrary-size integer as its big-endian two's complement representation."
  @spec encode_bigint(integer) :: binary
  def encode_bigint(int) when is_integer(int) do
    sign = if int < 0, do: 1, else: 0
    mag = abs(int)
    bytes = :binary.encode_unsigned(mag)
    <<sign, bytes::binary>>
  end

  @spec decode_bigint(binary) :: {:ok, integer} | {:error, {:invalid_extension, :bigint}}
  def decode_bigint(<<sign, bytes::binary>>) when sign in [0, 1] do
    mag = :binary.decode_unsigned(bytes)
    value = if sign == 1, do: -mag, else: mag
    {:ok, value}
  end

  def decode_bigint(_), do: {:error, {:invalid_extension, :bigint}}

  defp safe_binary_to_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_binary}
  end
end
