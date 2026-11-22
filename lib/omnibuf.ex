defmodule OmniBuf do
  @moduledoc """
  OmniBuf v0.1 binary wire format for Elixir.

  Supports all four OmniBuf implementation tiers:
  - **Tier 1 (Plugin):** `protoc-gen-omnibuf-elixir` generated structs, iodata codecs,
    and lazy `Opaque` zero-decode views with in-place iodata wire splicing.
  - **Tier 2 (Protobuf):** `OmniBuf.Protobuf` direct serialization/deserialization of
    standard `elixir-protobuf` (`use Protobuf`) message structs.
  - **Tier 3 (Declarative Schema):** `use OmniBuf.Schema` compile-time struct DSL.
  - **Tier 4 (Blind):** `OmniBuf.Blind.decode/1` and `OmniBuf.Blind.decode_json/1` for
    schema-less inspection with Field #0 `SchemaMeta` name resolution.
  """

  alias OmniBuf.{Blind, Error, Protobuf}

  @doc """
  Encodes an `OmniBuf.Schema` or generated Tier 1 struct to an OmniBuf binary.
  """
  @spec encode(struct(), keyword()) :: binary()
  def encode(%mod{} = msg, opts \\ []) do
    mod.encode(msg, opts)
  end

  @doc """
  Encodes an `OmniBuf.Schema` or generated Tier 1 struct to iodata.
  """
  @spec encode_iodata(struct(), keyword()) :: iodata()
  def encode_iodata(%mod{} = msg, opts \\ []) do
    mod.encode_iodata(msg, opts)
  end

  @doc """
  Decodes an OmniBuf binary into a fresh struct of `mod` (replace mode).
  """
  @spec decode(binary(), module()) :: {:ok, struct()} | {:error, Error.t()}
  def decode(bin, mod) when is_binary(bin) and is_atom(mod) do
    mod.decode(bin)
  end

  @doc """
  Merges an OmniBuf binary onto an existing struct (merge mode).
  """
  @spec merge(struct(), binary()) :: {:ok, struct()} | {:error, Error.t()}
  def merge(%mod{} = existing, bin) when is_binary(bin) do
    mod.merge(existing, bin)
  end

  @doc """
  Decodes an OmniBuf binary without a schema (Tier 4).
  """
  @spec decode_blind(binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def decode_blind(bin, opts \\ []) do
    Blind.decode(bin, opts)
  end

  @doc """
  Decodes an OmniBuf binary without a schema and serializes to JSON (Tier 4).
  """
  @spec decode_blind_json(binary(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def decode_blind_json(bin, opts \\ []) do
    Blind.decode_json(bin, opts)
  end

  @doc """
  Encodes a standard `elixir-protobuf` struct into OmniBuf wire bytes (Tier 2).
  """
  @spec encode_proto(struct(), keyword()) :: binary()
  def encode_proto(msg, opts \\ []) do
    Protobuf.encode(msg, opts)
  end

  @doc """
  Decodes OmniBuf wire bytes into a standard `elixir-protobuf` struct (Tier 2).
  """
  @spec decode_proto(binary(), module()) :: {:ok, struct()} | {:error, Error.t()}
  def decode_proto(bin, mod) do
    Protobuf.decode(bin, mod)
  end
end
