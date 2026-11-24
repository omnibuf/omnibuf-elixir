defmodule OmniBuf.Codec do
  @moduledoc """
  Shared high-performance OmniBuf v1 DRAFT-1 field encoders and decoders used by
  generated plugin code (Tier 1), Protobuf integration (Tier 2), and
  declarative `OmniBuf.Schema` structs (Tier 3).
  """

  alias OmniBuf.{Error, Wire}

  @doc """
  Maps an OmniBuf schema type descriptor to its wire type code (for tags/headers).
  """
  @spec wire_type_for(term()) :: 0..15
  def wire_type_for(:uint32), do: 0
  def wire_type_for(:uint64), do: 0
  def wire_type_for(:int32), do: 1
  def wire_type_for(:int64), do: 1
  def wire_type_for(:sint32), do: 1
  def wire_type_for(:sint64), do: 1
  def wire_type_for(:enum), do: 1
  def wire_type_for({:enum, _}), do: 1
  def wire_type_for(:bool), do: 2
  def wire_type_for(:fixed32), do: 4
  def wire_type_for(:fixed64), do: 5
  def wire_type_for(:sfixed32), do: 6
  def wire_type_for(:sfixed64), do: 7
  def wire_type_for(:float), do: 8
  def wire_type_for(:double), do: 9
  def wire_type_for(:string), do: 10
  def wire_type_for(:bytes), do: 11
  def wire_type_for({:message, _}), do: 12
  def wire_type_for({:array, _}), do: 13
  def wire_type_for({:map, _, _}), do: 14
  def wire_type_for(mod) when is_atom(mod), do: 12

  @doc """
  Default zero value for a schema field type.
  """
  @spec default_value(term()) :: term()
  def default_value(:uint32), do: 0
  def default_value(:uint64), do: 0
  def default_value(:int32), do: 0
  def default_value(:int64), do: 0
  def default_value(:sint32), do: 0
  def default_value(:sint64), do: 0
  def default_value(:enum), do: 0
  def default_value({:enum, _}), do: 0
  def default_value(:bool), do: false
  def default_value(:fixed32), do: 0
  def default_value(:fixed64), do: 0
  def default_value(:sfixed32), do: 0
  def default_value(:sfixed64), do: 0
  def default_value(:float), do: 0.0
  def default_value(:double), do: 0.0
  def default_value(:string), do: ""
  def default_value(:bytes), do: <<>>
  def default_value({:array, _}), do: []
  def default_value({:map, _, _}), do: %{}
  def default_value({:message, _}), do: nil
  def default_value(mod) when is_atom(mod), do: nil

  # ---------------------------------------------------------------------------
  # Encoding: Collection Elements & Full Values
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a value for inclusion inside a `WireArray` or `WireMap` (no field tag).
  """
  @spec encode_element(term(), term()) :: iodata()
  def encode_element(:uint32, v), do: Wire.encode_varint(Wire.narrow_uint32(v))
  def encode_element(:uint64, v), do: Wire.encode_varint(v)
  def encode_element(:int32, v), do: Wire.encode_varint(Wire.encode_zigzag(Wire.narrow_int32(v)))
  def encode_element(:sint32, v), do: Wire.encode_varint(Wire.encode_zigzag(Wire.narrow_int32(v)))
  def encode_element(:enum, v), do: Wire.encode_varint(Wire.encode_zigzag(Wire.narrow_int32(v)))

  def encode_element({:enum, _}, v),
    do: Wire.encode_varint(Wire.encode_zigzag(Wire.narrow_int32(v)))

  def encode_element(:int64, v), do: Wire.encode_varint(Wire.encode_zigzag(v))
  def encode_element(:sint64, v), do: Wire.encode_varint(Wire.encode_zigzag(v))
  def encode_element(:bool, false), do: <<0>>
  def encode_element(:bool, true), do: <<1>>
  def encode_element(:fixed32, v), do: <<v::little-unsigned-32>>
  def encode_element(:fixed64, v), do: <<v::little-unsigned-64>>
  def encode_element(:sfixed32, v), do: <<v::little-signed-32>>
  def encode_element(:sfixed64, v), do: <<v::little-signed-64>>
  def encode_element(:float, v), do: Wire.encode_float32(v)
  def encode_element(:double, v), do: Wire.encode_float64(v)
  def encode_element(:string, v), do: Wire.encode_length_prefixed(v)
  def encode_element(:bytes, v), do: Wire.encode_length_prefixed(v)

  def encode_element({:message, _mod}, nil), do: <<0x01>>

  def encode_element({:message, mod}, v) do
    Wire.encode_length_prefixed(mod.encode_iodata(v))
  end

  def encode_element({:array, elem_type}, list) do
    encode_array_value(elem_type, list)
  end

  def encode_element({:map, key_type, val_type}, map) do
    encode_map_value(key_type, val_type, map)
  end

  def encode_element(mod, nil) when is_atom(mod), do: <<0x01>>

  def encode_element(mod, v) when is_atom(mod) do
    Wire.encode_length_prefixed(mod.encode_iodata(v))
  end

  @doc """
  Encodes a `WireArray` value (`[ByteLen][ElementType: 1B][Count][Elements]`).
  """
  @spec encode_array_value(term(), list()) :: iodata()
  def encode_array_value(elem_type, list) when is_list(list) do
    wt = wire_type_for(elem_type)
    count = length(list)
    elems = encode_array_elements(elem_type, list)
    Wire.encode_length_prefixed([<<wt>>, Wire.encode_varint(count), elems])
  end

  defp encode_array_elements(:string, list),
    do: Enum.map(list, fn s -> Wire.encode_length_prefixed(s) end)

  defp encode_array_elements(:uint32, list),
    do: Enum.map(list, fn v -> Wire.encode_varint(Wire.narrow_uint32(v)) end)

  defp encode_array_elements(:uint64, list),
    do: Enum.map(list, fn v -> Wire.encode_varint(v) end)

  defp encode_array_elements(:bool, list),
    do: Enum.map(list, fn b -> if(b, do: <<1>>, else: <<0>>) end)

  defp encode_array_elements(elem_type, list),
    do: Enum.map(list, fn e -> encode_element(elem_type, e) end)

  @doc """
  Encodes a `WireMap` value (`[ByteLen][KeyType: 1B][ValueType: 1B][Count][Entries]`)
  with deterministic key ordering (unsigned UTF-8 byte order for strings, numeric order
  for integers, `false` before `true` for booleans).
  """
  @spec encode_map_value(term(), term(), map()) :: iodata()
  def encode_map_value(key_type, val_type, map) when is_map(map) do
    kt = wire_type_for(key_type)
    vt = wire_type_for(val_type)

    sorted =
      map
      |> Map.to_list()
      |> sort_map_entries(key_type)

    entries =
      Enum.map(sorted, fn {k, v} ->
        [encode_element(key_type, k), encode_element(val_type, v)]
      end)

    Wire.encode_length_prefixed([<<kt, vt>>, Wire.encode_varint(length(sorted)), entries])
  end

  # Narrow 32-bit integer keys before sorting so map ordering matches wire values.
  defp sort_map_entries(entries, key_type) when key_type in [:uint32, :fixed32] do
    Enum.sort_by(entries, fn {k, _v} -> Wire.narrow_uint32(k) end)
  end

  defp sort_map_entries(entries, key_type) when key_type in [:int32, :sint32, :sfixed32] do
    Enum.sort_by(entries, fn {k, _v} -> Wire.narrow_int32(k) end)
  end

  defp sort_map_entries(entries, _key_type) do
    Enum.sort_by(entries, fn {k, _v} -> k end)
  end

  # ---------------------------------------------------------------------------
  # Decoding: Collection Elements, Arrays, and Maps
  # ---------------------------------------------------------------------------

  @doc """
  Decodes a `WireArray` field, enforcing `ElementType` match against `elem_type`
  (collection header mismatch MUST return a parse error) and max nesting depth.
  """
  @spec decode_array(binary(), term(), non_neg_integer()) ::
          {:ok, list(), binary()} | {:error, Error.t()}
  def decode_array(bin, elem_type, depth) do
    case decode_array(bin, elem_type, depth, Wire.default_budget()) do
      {:ok, items, tail, _budget} -> {:ok, items, tail}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec decode_array(binary(), term(), non_neg_integer(), map()) ::
          {:ok, list(), binary(), map()} | {:error, Error.t()}
  def decode_array(bin, elem_type, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
    else
      expected_wt = wire_type_for(elem_type)

      with {:ok, actual_wt, count, elem_bytes, tail} <-
             Wire.decode_array_header(bin, budget.max_elements) do
        if actual_wt != expected_wt do
          Error.parse(
            :collection_type_mismatch,
            "WireArray ElementType mismatch: expected #{expected_wt}, got #{actual_wt}"
          )
        else
          with {:ok, budget} <- Wire.add_budget_elements(budget, count),
               {:ok, items, new_budget} <-
                 decode_array_elems(elem_type, count, elem_bytes, depth + 1, budget, []) do
            {:ok, items, tail, new_budget}
          end
        end
      end
    end
  end

  defp decode_array_elems(_type, 0, <<>>, _depth, budget, acc),
    do: {:ok, Enum.reverse(acc), budget}

  defp decode_array_elems(_type, 0, _trailing, _depth, _budget, _acc),
    do: Error.parse(:trailing_bytes, "trailing bytes in WireArray")

  defp decode_array_elems(:string, count, bin, depth, budget, acc) do
    case Wire.decode_string(bin) do
      {:ok, s, rest} -> decode_array_elems(:string, count - 1, rest, depth, budget, [s | acc])
      err -> err
    end
  end

  defp decode_array_elems(:uint32, count, bin, depth, budget, acc) do
    case Wire.decode_varint(bin) do
      {:ok, v, rest} ->
        decode_array_elems(:uint32, count - 1, rest, depth, budget, [Wire.narrow_uint32(v) | acc])

      err ->
        err
    end
  end

  defp decode_array_elems(:uint64, count, bin, depth, budget, acc) do
    case Wire.decode_varint(bin) do
      {:ok, v, rest} -> decode_array_elems(:uint64, count - 1, rest, depth, budget, [v | acc])
      err -> err
    end
  end

  defp decode_array_elems(elem_type, count, bin, depth, budget, acc) do
    case decode_element(elem_type, bin, depth, budget) do
      {:ok, val, rest, new_budget} ->
        decode_array_elems(elem_type, count - 1, rest, depth, new_budget, [val | acc])

      err ->
        err
    end
  end

  @doc """
  Decodes a `WireMap` field, merging entries into `existing` (duplicate keys replace
  prior values outright) and enforcing `KeyType`/`ValueType` match and depth limits.
  """
  @spec decode_map(binary(), term(), term(), map(), non_neg_integer()) ::
          {:ok, map(), binary()} | {:error, Error.t()}
  def decode_map(bin, key_type, val_type, existing, depth) do
    case decode_map(bin, key_type, val_type, existing, depth, Wire.default_budget()) do
      {:ok, map, tail, _budget} -> {:ok, map, tail}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec decode_map(binary(), term(), term(), map(), non_neg_integer(), map()) ::
          {:ok, map(), binary(), map()} | {:error, Error.t()}
  def decode_map(bin, key_type, val_type, existing, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
    else
      expected_kt = wire_type_for(key_type)
      expected_vt = wire_type_for(val_type)

      with {:ok, actual_kt, actual_vt, count, entry_bytes, tail} <-
             Wire.decode_map_header(bin, budget.max_elements) do
        if actual_kt != expected_kt or actual_vt != expected_vt do
          Error.parse(
            :collection_type_mismatch,
            "WireMap type mismatch: expected <#{expected_kt}, #{expected_vt}>, got <#{actual_kt}, #{actual_vt}>"
          )
        else
          with {:ok, budget} <- Wire.add_budget_elements(budget, count),
               {:ok, map, new_budget} <-
                 decode_map_pairs(
                   key_type,
                   val_type,
                   count,
                   entry_bytes,
                   depth + 1,
                   budget,
                   existing
                 ) do
            {:ok, map, tail, new_budget}
          end
        end
      end
    end
  end

  defp decode_map_pairs(_kt, _vt, 0, <<>>, _depth, budget, acc), do: {:ok, acc, budget}

  defp decode_map_pairs(_kt, _vt, 0, _trailing, _depth, _budget, _acc),
    do: Error.parse(:trailing_bytes, "trailing bytes in WireMap")

  defp decode_map_pairs(key_type, val_type, count, bin, depth, budget, acc) do
    with {:ok, k, after_k, budget} <- decode_element(key_type, bin, depth, budget),
         {:ok, v, after_v, budget} <- decode_element(val_type, after_k, depth, budget) do
      decode_map_pairs(key_type, val_type, count - 1, after_v, depth, budget, Map.put(acc, k, v))
    end
  end

  @doc """
  Decodes a single collection element or map key/value.
  """
  @spec decode_element(term(), binary(), non_neg_integer()) ::
          {:ok, term(), binary()} | {:error, Error.t()}
  def decode_element(type, bin, depth) do
    case decode_element(type, bin, depth, Wire.default_budget()) do
      {:ok, val, rest, _budget} -> {:ok, val, rest}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec decode_element(term(), binary(), non_neg_integer(), map()) ::
          {:ok, term(), binary(), map()} | {:error, Error.t()}
  def decode_element(:uint32, bin, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_varint(bin),
         do: {:ok, Wire.narrow_uint32(v), rest, budget}
  end

  def decode_element(:uint64, bin, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_varint(bin), do: {:ok, v, rest, budget}
  end

  def decode_element(t, bin, _depth, budget) when t in [:int32, :sint32, :enum] do
    with {:ok, u, rest} <- Wire.decode_varint(bin),
         do: {:ok, Wire.narrow_int32(Wire.decode_zigzag(u)), rest, budget}
  end

  def decode_element({:enum, _}, bin, _depth, budget) do
    with {:ok, u, rest} <- Wire.decode_varint(bin),
         do: {:ok, Wire.narrow_int32(Wire.decode_zigzag(u)), rest, budget}
  end

  def decode_element(t, bin, _depth, budget) when t in [:int64, :sint64] do
    with {:ok, u, rest} <- Wire.decode_varint(bin),
         do: {:ok, Wire.decode_zigzag(u), rest, budget}
  end

  def decode_element(:bool, <<0, rest::binary>>, _depth, budget), do: {:ok, false, rest, budget}
  def decode_element(:bool, <<1, rest::binary>>, _depth, budget), do: {:ok, true, rest, budget}

  def decode_element(:bool, <<b, _::binary>>, _depth, _budget),
    do: Error.parse(:invalid_bool_byte, "invalid boolean byte #{b}")

  def decode_element(:bool, <<>>, _depth, _budget),
    do: Error.parse(:truncated_bool, "truncated boolean")

  def decode_element(:fixed32, <<v::little-unsigned-32, rest::binary>>, _depth, budget),
    do: {:ok, v, rest, budget}

  def decode_element(:fixed32, _, _depth, _budget),
    do: Error.parse(:truncated_fixed32, "truncated fixed32")

  def decode_element(:fixed64, <<v::little-unsigned-64, rest::binary>>, _depth, budget),
    do: {:ok, v, rest, budget}

  def decode_element(:fixed64, _, _depth, _budget),
    do: Error.parse(:truncated_fixed64, "truncated fixed64")

  def decode_element(:sfixed32, <<v::little-signed-32, rest::binary>>, _depth, budget),
    do: {:ok, v, rest, budget}

  def decode_element(:sfixed32, _, _depth, _budget),
    do: Error.parse(:truncated_sfixed32, "truncated sfixed32")

  def decode_element(:sfixed64, <<v::little-signed-64, rest::binary>>, _depth, budget),
    do: {:ok, v, rest, budget}

  def decode_element(:sfixed64, _, _depth, _budget),
    do: Error.parse(:truncated_sfixed64, "truncated sfixed64")

  def decode_element(:float, bin, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_float32(bin), do: {:ok, v, rest, budget}
  end

  def decode_element(:double, bin, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_float64(bin), do: {:ok, v, rest, budget}
  end

  def decode_element(:string, bin, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_string(bin), do: {:ok, v, rest, budget}
  end

  def decode_element(:bytes, bin, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_length_prefixed(bin), do: {:ok, v, rest, budget}
  end

  def decode_element({:array, elem_type}, bin, depth, budget),
    do: decode_array(bin, elem_type, depth, budget)

  def decode_element({:map, kt, vt}, bin, depth, budget),
    do: decode_map(bin, kt, vt, %{}, depth, budget)

  def decode_element({:message, mod}, bin, depth, budget),
    do: decode_submsg(mod, bin, nil, depth, budget)

  def decode_element(mod, bin, depth, budget) when is_atom(mod),
    do: decode_submsg(mod, bin, nil, depth, budget)

  @doc """
  Decodes a length-prefixed `WireSubMsg` into `mod`, merging onto `existing` if non-nil.
  """
  @spec decode_submsg(module(), binary(), struct() | nil, non_neg_integer()) ::
          {:ok, struct(), binary()} | {:error, Error.t()}
  def decode_submsg(mod, bin, existing, depth) do
    case decode_submsg(mod, bin, existing, depth, Wire.default_budget()) do
      {:ok, msg, tail, _budget} -> {:ok, msg, tail}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec decode_submsg(module(), binary(), struct() | nil, non_neg_integer(), map()) ::
          {:ok, struct(), binary(), map()} | {:error, Error.t()}
  def decode_submsg(mod, bin, existing, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
    else
      with {:ok, body, tail} <- Wire.decode_length_prefixed(bin),
           {:ok, msg, new_budget} <-
             mod.decode_into(body, existing || struct(mod), depth + 1, budget) do
        {:ok, msg, tail, new_budget}
      end
    end
  end
end
