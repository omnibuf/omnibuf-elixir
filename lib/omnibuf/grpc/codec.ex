defmodule OmniBuf.GRPC.Codec do
  @moduledoc """
  `GRPC.Codec` implementation for OmniBuf wire payloads (`application/grpc+omnibuf`).

  Supports `OmniBuf.Schema` modules, `protoc-gen-omnibuf-elixir` generated modules,
  and `elixir-protobuf` structs.
  """

  @doc """
  Returns the gRPC codec subtype name (`"omnibuf"`).
  """
  @spec name() :: String.t()
  def name, do: "omnibuf"

  @doc """
  Encodes a struct to OmniBuf binary wire format.
  """
  @spec encode(struct()) :: binary()
  def encode(%mod{} = struct) do
    do_encode(mod, struct, [])
  end

  @doc """
  Decodes an OmniBuf binary payload into a struct of `module`.
  """
  @spec decode(binary(), module()) :: struct()
  def decode(binary, module) when is_binary(binary) and is_atom(module) do
    do_decode(binary, module)
  end

  @doc false
  @spec do_encode(module(), struct(), keyword()) :: binary()
  def do_encode(mod, struct, opts) do
    Code.ensure_loaded(mod)

    cond do
      function_exported?(mod, :__omnibuf_fields__, 0) ->
        mod.encode(struct, opts)

      function_exported?(mod, :__message_props__, 0) ->
        OmniBuf.encode_proto(struct, opts)

      true ->
        raise ArgumentError,
              "#{inspect(mod)} is not an OmniBuf.Schema, generated OmniBuf, or Protobuf module"
    end
  end

  @doc false
  @spec do_decode(binary(), module()) :: struct()
  def do_decode(binary, mod) do
    Code.ensure_loaded(mod)

    cond do
      function_exported?(mod, :__omnibuf_fields__, 0) ->
        OmniBuf.decode!(binary, mod)

      function_exported?(mod, :__message_props__, 0) ->
        OmniBuf.decode_proto!(binary, mod)

      true ->
        raise ArgumentError,
              "#{inspect(mod)} is not an OmniBuf.Schema, generated OmniBuf, or Protobuf module"
    end
  end
end

defmodule OmniBuf.GRPC.SelfDescribingCodec do
  @moduledoc """
  `GRPC.Codec` implementation for self-describing OmniBuf payloads
  (`application/grpc+x-omnibuf`) carrying Field #0 schema metadata.
  """

  alias OmniBuf.GRPC.Codec

  @doc """
  Returns the gRPC codec subtype name (`"x-omnibuf"`).
  """
  @spec name() :: String.t()
  def name, do: "x-omnibuf"

  @doc """
  Encodes a struct to self-describing OmniBuf binary wire format.
  """
  @spec encode(struct()) :: binary()
  def encode(%mod{} = struct) do
    Codec.do_encode(mod, struct, self_describing: true)
  end

  @doc """
  Decodes an OmniBuf binary payload into a struct of `module`.
  """
  @spec decode(binary(), module()) :: struct()
  def decode(binary, module) when is_binary(binary) and is_atom(module) do
    Codec.do_decode(binary, module)
  end
end
