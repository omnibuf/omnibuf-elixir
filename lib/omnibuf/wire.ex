defmodule OmniBuf.Wire do
  @moduledoc """
  Low-level OmniBuf v0.1 wire primitives: 1/2/4/9-byte Prefix-Varints, 64-bit ZigZag,
  all 16 wire types, IEEE-754 float handling, O(1) sub-binary field skipping, and
  container/depth validation.
  """

  import Bitwise

  alias OmniBuf.Error

  @wire_uint 0
  @wire_sint 1
  @wire_bool_false 2
  @wire_bool_true 3
  @wire_fixed32 4
  @wire_fixed64 5
  @wire_sfixed32 6
  @wire_sfixed64 7
  @wire_float32 8
  @wire_float64 9
  @wire_string 10
  @wire_bytes 11
  @wire_sub_msg 12
  @wire_array 13
  @wire_map 14
  @wire_extended 15

  @max_field_number 536_870_911
  @max_depth 32
  @default_max_elements 4_194_304
  @default_max_message_bytes 64 * 1024 * 1024
  @uint64_max 0xFFFF_FFFF_FFFF_FFFF
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @uint32_mask 0xFFFF_FFFF

  @compile {:inline,
            encode_varint: 1,
            encode_tag: 2,
            encode_zigzag: 1,
            decode_zigzag: 1,
            narrow_int32: 1,
            narrow_uint32: 1,
            valid_key_type?: 1,
            valid_element_type?: 1,
            fixed_width: 1}

  def wire_uint, do: @wire_uint
  def wire_sint, do: @wire_sint
  def wire_bool_false, do: @wire_bool_false
  def wire_bool_true, do: @wire_bool_true
  def wire_fixed32, do: @wire_fixed32
  def wire_fixed64, do: @wire_fixed64
  def wire_sfixed32, do: @wire_sfixed32
  def wire_sfixed64, do: @wire_sfixed64
  def wire_float32, do: @wire_float32
  def wire_float64, do: @wire_float64
  def wire_string, do: @wire_string
  def wire_bytes, do: @wire_bytes
  def wire_sub_msg, do: @wire_sub_msg
  def wire_array, do: @wire_array
  def wire_map, do: @wire_map
  def wire_extended, do: @wire_extended

  def max_field_number, do: @max_field_number
  def max_depth, do: @max_depth
  def default_max_elements, do: @default_max_elements
  def default_max_message_bytes, do: @default_max_message_bytes

  @doc """
  Builds a cumulative decode budget map from keyword options:
  - `:max_depth` (default `32`, capped at `32`, must be `>= 1`)
  - `:max_elements` (default `4_194_304`, must be `>= 0`)
  - `:max_message_bytes` (default `64 MiB`, must be `>= 0`)
  """
  @spec new_budget(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def new_budget(opts \\ []) when is_list(opts) do
    max_depth = Keyword.get(opts, :max_depth, @max_depth)
    max_elements = Keyword.get(opts, :max_elements, @default_max_elements)
    max_message_bytes = Keyword.get(opts, :max_message_bytes, @default_max_message_bytes)

    cond do
      not is_integer(max_depth) or max_depth < 1 ->
        Error.parse(:invalid_option, "max_depth must be an integer >= 1")

      not is_integer(max_elements) or max_elements < 0 ->
        Error.parse(:invalid_option, "max_elements must be an integer >= 0")

      not is_integer(max_message_bytes) or max_message_bytes < 0 ->
        Error.parse(:invalid_option, "max_message_bytes must be an integer >= 0")

      true ->
        {:ok,
         %{
           max_depth: min(max_depth, @max_depth),
           max_elements: max_elements,
           max_message_bytes: max_message_bytes,
           elements: 0
         }}
    end
  end

  @doc false
  @spec default_budget() :: map()
  def default_budget do
    %{
      max_depth: @max_depth,
      max_elements: @default_max_elements,
      max_message_bytes: @default_max_message_bytes,
      elements: 0
    }
  end

  # ---------------------------------------------------------------------------
  # Prefix-Varint Encoding & Decoding (1, 2, 4, or 9 bytes)
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a non-negative 64-bit integer as a minimal Prefix-Varint binary.
  """
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(v) when is_integer(v) and v >= 0 and v < 128 do
    <<bsl(v, 1) ||| 1>>
  end

  def encode_varint(v) when is_integer(v) and v >= 128 and v < 16_384 do
    <<bsl(v, 2) ||| 2::little-unsigned-16>>
  end

  def encode_varint(v) when is_integer(v) and v >= 16_384 and v < 536_870_912 do
    <<bsl(v, 3) ||| 4::little-unsigned-32>>
  end

  def encode_varint(v) when is_integer(v) and v >= 536_870_912 and v <= @uint64_max do
    <<0, v::little-unsigned-64>>
  end

  def encode_varint(v) do
    raise ArgumentError, "varint value #{inspect(v)} out of uint64 range (0..#{@uint64_max})"
  end

  @doc """
  Decodes a Prefix-Varint (accepting non-minimal widths and rejecting reserved prefixes).
  """
  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, Error.t()}
  def decode_varint(<<v::7, 1::1, rest::binary>>) do
    {:ok, v, rest}
  end

  def decode_varint(<<lo::6, 2::2, hi::8, rest::binary>>) do
    {:ok, bsl(hi, 6) ||| lo, rest}
  end

  def decode_varint(<<b0::5, 4::3, b1::8, b2::8, b3::8, rest::binary>>) do
    {:ok, bsl(b3, 21) ||| bsl(b2, 13) ||| bsl(b1, 5) ||| b0, rest}
  end

  def decode_varint(<<0, v::little-unsigned-64, rest::binary>>) do
    {:ok, v, rest}
  end

  def decode_varint(<<hi::5, 0::3, _::binary>>) when hi != 0 do
    Error.parse(:reserved_varint_prefix, "reserved prefix-varint first byte")
  end

  def decode_varint(<<>>) do
    Error.parse(:unexpected_eof, "unexpected EOF reading prefix-varint")
  end

  def decode_varint(_truncated) do
    Error.parse(:truncated_varint, "truncated prefix-varint")
  end

  # ---------------------------------------------------------------------------
  # Field Tags
  # ---------------------------------------------------------------------------

  @doc """
  Encodes `(field_number << 4) | wire_type` as a Prefix-Varint.
  """
  @spec encode_tag(non_neg_integer(), 0..15) :: binary()
  def encode_tag(field_number, wire_type) do
    encode_varint(bsl(field_number, 4) ||| wire_type)
  end

  @doc """
  Decodes a field tag, validating field number bounds and Field #0 wire type (`WireSubMsg`).
  """
  @spec decode_tag(binary()) ::
          {:ok, non_neg_integer(), 0..15, binary()} | {:error, Error.t()}
  def decode_tag(bin) do
    case decode_varint(bin) do
      {:ok, tag, rest} ->
        field_num = bsr(tag, 4)
        wire_type = tag &&& 0x0F

        cond do
          field_num > @max_field_number ->
            Error.parse(:field_number_out_of_range, "field number #{field_num} exceeds max")

          field_num == 0 and wire_type != @wire_sub_msg ->
            Error.parse(
              :invalid_field_zero,
              "field #0 must use WireSubMsg (12), got #{wire_type}"
            )

          true ->
            {:ok, field_num, wire_type, rest}
        end

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Signed Integers (64-bit ZigZag + 32-bit narrowing)
  # ---------------------------------------------------------------------------

  @spec encode_zigzag(integer()) :: non_neg_integer()
  def encode_zigzag(n) when is_integer(n) and n >= 0 and n <= @int64_max do
    bsl(n, 1)
  end

  def encode_zigzag(n) when is_integer(n) and n >= @int64_min and n < 0 do
    bsl(-n, 1) - 1
  end

  def encode_zigzag(n) do
    raise ArgumentError,
          "zigzag value #{inspect(n)} out of int64 range (#{@int64_min}..#{@int64_max})"
  end

  @spec decode_zigzag(non_neg_integer()) :: integer()
  def decode_zigzag(u) when is_integer(u) do
    if (u &&& 1) == 0 do
      bsr(u, 1)
    else
      -(bsr(u, 1) + 1)
    end
  end

  @spec narrow_int32(integer()) :: integer()
  def narrow_int32(n) when is_integer(n) do
    v = n &&& @uint32_mask
    if v >= 0x8000_0000, do: v - 0x1_0000_0000, else: v
  end

  @spec narrow_uint32(non_neg_integer()) :: non_neg_integer()
  def narrow_uint32(n) when is_integer(n) do
    n &&& @uint32_mask
  end

  # ---------------------------------------------------------------------------
  # Fixed-Width & Float Encoding / Decoding
  # ---------------------------------------------------------------------------

  @spec encode_float32(number() | :infinity | :neg_infinity | :nan) :: binary()
  def encode_float32(:infinity), do: <<0x00, 0x00, 0x80, 0x7F>>
  def encode_float32(:neg_infinity), do: <<0x00, 0x00, 0x80, 0xFF>>
  def encode_float32(:nan), do: <<0x00, 0x00, 0xC0, 0x7F>>
  def encode_float32(v) when is_number(v), do: <<v::little-float-32>>

  @spec encode_float64(number() | :infinity | :neg_infinity | :nan) :: binary()
  def encode_float64(:infinity), do: <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x7F>>
  def encode_float64(:neg_infinity), do: <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xFF>>
  def encode_float64(:nan), do: <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F>>
  def encode_float64(v) when is_number(v), do: <<v::little-float-64>>

  @spec decode_float32(binary()) ::
          {:ok, float() | :infinity | :neg_infinity | :nan, binary()} | {:error, Error.t()}
  def decode_float32(<<f::little-float-32, rest::binary>>), do: {:ok, f, rest}

  def decode_float32(<<bits::little-unsigned-32, rest::binary>>) do
    val =
      case bits do
        0x7F80_0000 -> :infinity
        0xFF80_0000 -> :neg_infinity
        _ -> :nan
      end

    {:ok, val, rest}
  end

  def decode_float32(_), do: Error.parse(:truncated_fixed32, "truncated float32")

  @spec decode_float64(binary()) ::
          {:ok, float() | :infinity | :neg_infinity | :nan, binary()} | {:error, Error.t()}
  def decode_float64(<<f::little-float-64, rest::binary>>), do: {:ok, f, rest}

  def decode_float64(<<bits::little-unsigned-64, rest::binary>>) do
    val =
      case bits do
        0x7FF0_0000_0000_0000 -> :infinity
        0xFFF0_0000_0000_0000 -> :neg_infinity
        _ -> :nan
      end

    {:ok, val, rest}
  end

  def decode_float64(_), do: Error.parse(:truncated_fixed64, "truncated float64")

  # ---------------------------------------------------------------------------
  # Length-Prefixed Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Wraps iodata with a Prefix-Varint byte-length prefix.
  """
  @spec encode_length_prefixed(iodata()) :: iodata()
  def encode_length_prefixed(body) do
    size = IO.iodata_length(body)
    [encode_varint(size), body]
  end

  @doc """
  Reads a length-prefixed slice as a zero-copy sub-binary, checking bounds first.
  """
  @spec decode_length_prefixed(binary()) :: {:ok, binary(), binary()} | {:error, Error.t()}
  def decode_length_prefixed(bin) do
    case decode_varint(bin) do
      {:ok, len, rest} ->
        if len <= byte_size(rest) do
          <<slice::binary-size(len), tail::binary>> = rest
          {:ok, slice, tail}
        else
          Error.parse(
            :truncated_length_prefixed,
            "length #{len} exceeds remaining #{byte_size(rest)}"
          )
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Reads a length-prefixed UTF-8 string and strictly validates UTF-8.
  """
  @spec decode_string(binary()) :: {:ok, String.t(), binary()} | {:error, Error.t()}
  def decode_string(bin) do
    case decode_length_prefixed(bin) do
      {:ok, str, rest} ->
        if String.valid?(str) do
          {:ok, str, rest}
        else
          Error.parse(:invalid_utf8, "WireString contains invalid UTF-8")
        end

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Collection Type Validation & Widths
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if `code` is a valid `WireArray` `ElementType` or `WireMap` `ValueType`.
  High 4 bits must be 0 and code 3 (`WireBoolTrue`) is invalid in collections.
  """
  @spec valid_element_type?(integer()) :: boolean()
  def valid_element_type?(code) when code in 0..15 and code != @wire_bool_true, do: true
  def valid_element_type?(_), do: false

  @doc """
  Returns true if `code` is a valid `WireMap` `KeyType`.
  Valid codes: 0, 1, 2, 4, 5, 6, 7, 10.
  """
  @spec valid_key_type?(integer()) :: boolean()
  def valid_key_type?(code) when code in [0, 1, 2, 4, 5, 6, 7, 10], do: true
  def valid_key_type?(_), do: false

  @doc """
  Returns the fixed byte width of a collection element wire type, or `nil` if variable-width.
  """
  @spec fixed_width(0..15) :: pos_integer() | nil
  def fixed_width(@wire_bool_false), do: 1
  def fixed_width(@wire_fixed32), do: 4
  def fixed_width(@wire_sfixed32), do: 4
  def fixed_width(@wire_float32), do: 4
  def fixed_width(@wire_fixed64), do: 8
  def fixed_width(@wire_sfixed64), do: 8
  def fixed_width(@wire_float64), do: 8
  def fixed_width(_), do: nil

  @doc """
  Decodes a `WireArray` header: `[ByteLen][ElementType: 1B][Count]`.
  Validates bounds, element type, `Count = 0` trailing bytes, and count/remaining invariants.
  """
  @spec decode_array_header(binary(), non_neg_integer()) ::
          {:ok, 0..15, non_neg_integer(), binary(), binary()} | {:error, Error.t()}
  def decode_array_header(bin, max_elements \\ @default_max_elements) do
    with {:ok, payload, after_array} <- decode_length_prefixed(bin) do
      case payload do
        <<elem_type::8, rest::binary>> ->
          if not valid_element_type?(elem_type) do
            Error.parse(:invalid_element_type, "invalid WireArray ElementType #{elem_type}")
          else
            case decode_varint(rest) do
              {:ok, count, elem_bytes} ->
                rem_len = byte_size(elem_bytes)

                cond do
                  count > max_elements ->
                    Error.parse(:element_limit_exceeded, "array count #{count} exceeds limit")

                  count == 0 and rem_len != 0 ->
                    Error.parse(:trailing_bytes, "empty WireArray has #{rem_len} trailing bytes")

                  count == 0 ->
                    {:ok, elem_type, 0, <<>>, after_array}

                  true ->
                    case fixed_width(elem_type) do
                      nil ->
                        if count > rem_len do
                          Error.parse(
                            :count_exceeds_bytes,
                            "array count #{count} exceeds remaining #{rem_len} bytes"
                          )
                        else
                          {:ok, elem_type, count, elem_bytes, after_array}
                        end

                      w ->
                        if rem(rem_len, w) != 0 or div(rem_len, w) != count do
                          Error.parse(
                            :fixed_array_size_mismatch,
                            "fixed array count #{count} * #{w} != #{rem_len}"
                          )
                        else
                          {:ok, elem_type, count, elem_bytes, after_array}
                        end
                    end
                end

              {:error, _} = err ->
                err
            end
          end

        <<>> ->
          Error.parse(:truncated_array_header, "empty WireArray body missing ElementType")
      end
    end
  end

  @doc """
  Decodes a `WireMap` header: `[ByteLen][KeyType: 1B][ValueType: 1B][Count]`.
  Validates bounds, key/value types, `Count = 0` trailing bytes, and `count <= remaining / 2`.
  """
  @spec decode_map_header(binary(), non_neg_integer()) ::
          {:ok, 0..15, 0..15, non_neg_integer(), binary(), binary()} | {:error, Error.t()}
  def decode_map_header(bin, max_elements \\ @default_max_elements) do
    with {:ok, payload, after_map} <- decode_length_prefixed(bin) do
      case payload do
        <<key_type::8, val_type::8, rest::binary>> ->
          cond do
            not valid_key_type?(key_type) ->
              Error.parse(:invalid_key_type, "invalid WireMap KeyType #{key_type}")

            not valid_element_type?(val_type) ->
              Error.parse(:invalid_value_type, "invalid WireMap ValueType #{val_type}")

            true ->
              case decode_varint(rest) do
                {:ok, count, entry_bytes} ->
                  rem_len = byte_size(entry_bytes)

                  cond do
                    count > max_elements ->
                      Error.parse(:element_limit_exceeded, "map count #{count} exceeds limit")

                    count == 0 and rem_len != 0 ->
                      Error.parse(:trailing_bytes, "empty WireMap has #{rem_len} trailing bytes")

                    count > div(rem_len, 2) ->
                      Error.parse(
                        :count_exceeds_bytes,
                        "map count #{count} exceeds remaining #{rem_len} / 2"
                      )

                    true ->
                      {:ok, key_type, val_type, count, entry_bytes, after_map}
                  end

                {:error, _} = err ->
                  err
              end
          end

        _ ->
          Error.parse(:truncated_map_header, "truncated WireMap header")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fast O(1) Raw Skip (used by Opaque field lookup & splicing)
  # ---------------------------------------------------------------------------

  @doc """
  Skips a single wire value in O(1) time without inspecting container internals.
  Used by lazy `Opaque` field scanning.
  """
  @spec skip_fast(0..15, binary()) :: {:ok, binary()} | {:error, Error.t()}
  def skip_fast(@wire_uint, bin) do
    case decode_varint(bin) do
      {:ok, _, rest} -> {:ok, rest}
      err -> err
    end
  end

  def skip_fast(@wire_sint, bin), do: skip_fast(@wire_uint, bin)
  def skip_fast(@wire_bool_false, bin), do: {:ok, bin}
  def skip_fast(@wire_bool_true, bin), do: {:ok, bin}

  def skip_fast(wt, <<_::binary-size(4), rest::binary>>)
      when wt in [@wire_fixed32, @wire_sfixed32, @wire_float32],
      do: {:ok, rest}

  def skip_fast(wt, _bin) when wt in [@wire_fixed32, @wire_sfixed32, @wire_float32],
    do: Error.parse(:truncated_fixed32, "truncated 4-byte fixed value")

  def skip_fast(wt, <<_::binary-size(8), rest::binary>>)
      when wt in [@wire_fixed64, @wire_sfixed64, @wire_float64],
      do: {:ok, rest}

  def skip_fast(wt, _bin) when wt in [@wire_fixed64, @wire_sfixed64, @wire_float64],
    do: Error.parse(:truncated_fixed64, "truncated 8-byte fixed value")

  def skip_fast(@wire_extended, bin) do
    case decode_length_prefixed(bin) do
      {:ok, payload, rest} when byte_size(payload) >= 1 -> {:ok, rest}
      {:ok, <<>>, _} -> Error.parse(:invalid_extended, "WireExtended ByteLen must be >= 1")
      err -> err
    end
  end

  def skip_fast(@wire_array, bin) do
    case decode_array_header(bin, byte_size(bin)) do
      {:ok, _elem_type, _count, _elem_bytes, rest} -> {:ok, rest}
      {:error, _} = err -> err
    end
  end

  def skip_fast(@wire_map, bin) do
    case decode_map_header(bin, byte_size(bin)) do
      {:ok, _kt, _vt, _count, _entry_bytes, rest} -> {:ok, rest}
      {:error, _} = err -> err
    end
  end

  def skip_fast(wt, bin)
      when wt in [@wire_string, @wire_bytes, @wire_sub_msg] do
    case decode_length_prefixed(bin) do
      {:ok, _slice, rest} -> {:ok, rest}
      err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Validating Skip (enforces depth, Field #0 rules, container framing on unknown fields)
  # ---------------------------------------------------------------------------

  @doc """
  Skips a wire value while validating container bounds, nesting depth (max 32),
  and Field #0 wire type invariants inside unknown submessages.
  """
  @spec skip_validated(0..15, binary(), non_neg_integer(), keyword() | map()) ::
          {:ok, binary()} | {:error, Error.t()}
  def skip_validated(wt, bin, depth, opts_or_budget \\ [])

  def skip_validated(wt, bin, depth, %{} = budget) do
    case skip_validated_with_budget(wt, bin, depth, budget) do
      {:ok, rest, _budget} -> {:ok, rest}
      {:error, _} = err -> err
    end
  end

  def skip_validated(wt, bin, depth, opts) when is_list(opts) do
    with {:ok, budget} <- new_budget(opts),
         {:ok, rest, _budget} <- skip_validated_with_budget(wt, bin, depth, budget) do
      {:ok, rest}
    end
  end

  @doc false
  @spec skip_validated_with_budget(0..15, binary(), non_neg_integer(), map()) ::
          {:ok, binary(), map()} | {:error, Error.t()}
  def skip_validated_with_budget(@wire_sub_msg, bin, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
    else
      with {:ok, body, rest} <- decode_length_prefixed(bin),
           {:ok, new_budget} <- validate_message_stream_with_budget(body, depth + 1, budget) do
        {:ok, rest, new_budget}
      end
    end
  end

  def skip_validated_with_budget(@wire_array, bin, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
    else
      with {:ok, elem_type, count, elem_bytes, rest} <-
             decode_array_header(bin, budget.max_elements),
           {:ok, budget} <- add_budget_elements(budget, count),
           {:ok, new_budget} <-
             validate_array_elements(elem_type, count, elem_bytes, depth + 1, budget) do
        {:ok, rest, new_budget}
      end
    end
  end

  def skip_validated_with_budget(@wire_map, bin, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
    else
      with {:ok, key_type, val_type, count, entry_bytes, rest} <-
             decode_map_header(bin, budget.max_elements),
           {:ok, budget} <- add_budget_elements(budget, count),
           {:ok, new_budget} <-
             validate_map_entries(key_type, val_type, count, entry_bytes, depth + 1, budget) do
        {:ok, rest, new_budget}
      end
    end
  end

  def skip_validated_with_budget(@wire_string, bin, _depth, budget) do
    case decode_string(bin) do
      {:ok, _str, rest} -> {:ok, rest, budget}
      {:error, _} = err -> err
    end
  end

  def skip_validated_with_budget(wt, bin, _depth, budget) do
    case skip_fast(wt, bin) do
      {:ok, rest} -> {:ok, rest, budget}
      {:error, _} = err -> err
    end
  end

  @doc """
  Validates an entire message field stream (for unknown submessages).
  """
  @spec validate_message_stream(binary(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def validate_message_stream(bin, depth) do
    budget = %{max_depth: @max_depth, max_elements: @default_max_elements, elements: 0}

    case validate_message_stream_with_budget(bin, depth, budget) do
      {:ok, _budget} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec validate_message_stream_with_budget(binary(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def validate_message_stream_with_budget(<<>>, _depth, budget), do: {:ok, budget}

  def validate_message_stream_with_budget(bin, depth, budget) do
    with {:ok, field_num, wt, rest} <- decode_tag(bin) do
      if field_num == 0 do
        case OmniBuf.SchemaMeta.decode_field(rest, depth, budget) do
          {:ok, _meta, tail, new_budget} ->
            validate_message_stream_with_budget(tail, depth, new_budget)

          {:error, _} = err ->
            err
        end
      else
        case skip_validated_with_budget(wt, rest, depth, budget) do
          {:ok, tail, new_budget} ->
            validate_message_stream_with_budget(tail, depth, new_budget)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  @doc false
  @spec add_budget_elements(map(), non_neg_integer()) :: {:ok, map()} | {:error, Error.t()}
  def add_budget_elements(%{elements: el, max_elements: max} = budget, count) do
    next = el + count

    if next > max do
      Error.parse(:element_limit_exceeded, "cumulative element count #{next} exceeds #{max}")
    else
      {:ok, %{budget | elements: next}}
    end
  end

  defp validate_array_elements(_elem_type, 0, <<>>, _depth, budget), do: {:ok, budget}

  defp validate_array_elements(_elem_type, 0, _trailing, _depth, _budget),
    do: Error.parse(:trailing_bytes, "trailing bytes in WireArray")

  defp validate_array_elements(@wire_bool_false, count, bin, _depth, budget) do
    case validate_bool_bytes(bin, count) do
      :ok -> {:ok, budget}
      {:error, _} = err -> err
    end
  end

  defp validate_array_elements(elem_type, _count, _bin, _depth, budget)
       when elem_type in [
              @wire_fixed32,
              @wire_fixed64,
              @wire_sfixed32,
              @wire_sfixed64,
              @wire_float32,
              @wire_float64
            ] do
    # Exact byte length was already verified in decode_array_header.
    {:ok, budget}
  end

  defp validate_array_elements(elem_type, count, bin, depth, budget) do
    case skip_collection_value(elem_type, bin, depth, budget) do
      {:ok, rest, new_budget} ->
        validate_array_elements(elem_type, count - 1, rest, depth, new_budget)

      {:error, _} = err ->
        err
    end
  end

  defp validate_map_entries(_kt, _vt, 0, <<>>, _depth, budget), do: {:ok, budget}

  defp validate_map_entries(_kt, _vt, 0, _trailing, _depth, _budget),
    do: Error.parse(:trailing_bytes, "trailing bytes in WireMap")

  defp validate_map_entries(kt, vt, count, bin, depth, budget) do
    with {:ok, after_key, budget} <- skip_collection_value(kt, bin, depth, budget),
         {:ok, after_val, budget} <- skip_collection_value(vt, after_key, depth, budget) do
      validate_map_entries(kt, vt, count - 1, after_val, depth, budget)
    end
  end

  defp skip_collection_value(@wire_bool_false, <<b, rest::binary>>, _depth, budget)
       when b in [0, 1],
       do: {:ok, rest, budget}

  defp skip_collection_value(@wire_bool_false, <<b, _::binary>>, _depth, _budget),
    do: Error.parse(:invalid_bool_byte, "invalid boolean byte #{b} in collection")

  defp skip_collection_value(@wire_bool_false, <<>>, _depth, _budget),
    do: Error.parse(:truncated_bool, "truncated boolean in collection")

  defp skip_collection_value(wt, bin, depth, budget),
    do: skip_validated_with_budget(wt, bin, depth, budget)

  defp validate_bool_bytes(<<>>, 0), do: :ok

  defp validate_bool_bytes(<<b, rest::binary>>, count) when b in [0, 1],
    do: validate_bool_bytes(rest, count - 1)

  defp validate_bool_bytes(<<b, _::binary>>, _count),
    do: Error.parse(:invalid_bool_byte, "invalid boolean byte #{b} in WireArray")

  defp validate_bool_bytes(<<>>, _count),
    do: Error.parse(:truncated_bool, "truncated boolean array")
end
