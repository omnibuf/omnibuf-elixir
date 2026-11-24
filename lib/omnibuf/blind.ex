defmodule OmniBuf.Blind do
  @moduledoc """
  Tier 4: Schema-less OmniBuf packet decoding (`OmniBuf.Blind.decode/1` and
  `OmniBuf.Blind.decode_json/1`).

  Decodes any OmniBuf v1 DRAFT-1 packet into JSON-ready Elixir maps, resolving Field #0
  (`OmniBuf.SchemaMeta`) names across nested submessages, arrays, and maps, and
  falling back to `"field_<N>"` for unnamed fields.
  """

  alias OmniBuf.{Error, Native, SchemaMeta, Wire}

  @default_max_bytes 64 * 1024 * 1024
  @default_max_elements 4_194_304

  @doc """
  Decodes an OmniBuf binary without a schema into a map keyed by Field #0 names
  or `"field_<N>"`.

  Options:
  - `:inherited_schema` - optional `%OmniBuf.SchemaMeta{}`
  - `:max_depth` - max container depth (default `32`, capped at `32`)
  - `:max_elements` - max cumulative collection elements (default `4_194_304`)
  - `:max_message_bytes` - max packet byte size (default `64 MiB`)
  """
  @spec decode(binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def decode(bin, opts \\ []) when is_binary(bin) do
    if Native.enabled?() and is_nil(Keyword.get(opts, :inherited_schema)) do
      max_bytes = Keyword.get(opts, :max_message_bytes, @default_max_bytes)
      max_depth = min(Keyword.get(opts, :max_depth, Wire.max_depth()), Wire.max_depth())
      max_elements = Keyword.get(opts, :max_elements, @default_max_elements)
      Native.decode_blind(bin, max_depth, max_elements, max_bytes)
    else
      with {:ok, raw_map} <- decode_raw(bin, opts) do
        {:ok, unwrap_public(raw_map)}
      end
    end
  end

  defp decode_raw(bin, opts) do
    max_bytes = Keyword.get(opts, :max_message_bytes, @default_max_bytes)

    if byte_size(bin) > max_bytes do
      Error.parse(:message_too_large, "packet size #{byte_size(bin)} exceeds #{max_bytes}")
    else
      inherited = Keyword.get(opts, :inherited_schema)
      max_depth = min(Keyword.get(opts, :max_depth, Wire.max_depth()), Wire.max_depth())
      max_elements = Keyword.get(opts, :max_elements, @default_max_elements)
      budget = %{max_depth: max_depth, max_elements: max_elements, elements: 0}

      case decode_message(bin, inherited, 0, budget) do
        {:ok, map, _budget} -> {:ok, map}
        {:error, _} = err -> err
      end
    end
  end

  defp unwrap_public({:float32, f}), do: f
  defp unwrap_public({:bytes, b}), do: b
  defp unwrap_public(list) when is_list(list), do: Enum.map(list, &unwrap_public/1)

  defp unwrap_public(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, unwrap_public(v)} end)

  defp unwrap_public(v), do: v

  @doc """
  Decodes an OmniBuf binary without a schema, raising `OmniBuf.Error` on failure.
  """
  @spec decode!(binary(), keyword()) :: map()
  def decode!(bin, opts \\ []) when is_binary(bin) do
    case decode(bin, opts) do
      {:ok, map} -> map
      {:error, err} -> raise err
    end
  end

  @doc """
  Decodes an OmniBuf binary without a schema and encodes the result as a JSON string.
  `WireBytes` values are encoded as standard RFC 4648 Base64 strings.
  """
  @spec decode_json(binary(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def decode_json(bin, opts \\ []) when is_binary(bin) do
    if Native.enabled?() and is_nil(Keyword.get(opts, :inherited_schema)) do
      max_bytes = Keyword.get(opts, :max_message_bytes, @default_max_bytes)
      max_depth = min(Keyword.get(opts, :max_depth, Wire.max_depth()), Wire.max_depth())
      max_elements = Keyword.get(opts, :max_elements, @default_max_elements)
      Native.decode_blind_json(bin, max_depth, max_elements, max_bytes)
    else
      with {:ok, map} <- decode_raw(bin, opts),
           {:ok, json_ready} <- to_json_value(map) do
        case Jason.encode(json_ready) do
          {:ok, json} -> {:ok, json}
          {:error, err} -> {:error, Error.new(:serialize, Exception.message(err))}
        end
      end
    end
  end

  @doc """
  Decodes an OmniBuf binary without a schema and encodes the result as a JSON string,
  raising `OmniBuf.Error` on failure.
  """
  @spec decode_json!(binary(), keyword()) :: String.t()
  def decode_json!(bin, opts \\ []) when is_binary(bin) do
    case decode_json(bin, opts) do
      {:ok, json} -> json
      {:error, err} -> raise err
    end
  end

  # ---------------------------------------------------------------------------
  # JSON Conversion
  # ---------------------------------------------------------------------------

  defp to_json_value({:bytes, bin}), do: {:ok, Base.encode64(bin)}

  defp to_json_value({:float32, v}) when v in [:nan, :infinity, :neg_infinity] do
    {:error,
     Error.new(:serialize, "non-finite float #{inspect(v)} cannot be represented in JSON")}
  end

  defp to_json_value({:float32, f}) when is_float(f) do
    {:ok, Jason.Fragment.new(format_json_float(f, :float32))}
  end

  defp to_json_value(f) when is_float(f) do
    {:ok, Jason.Fragment.new(format_json_float(f, :float64))}
  end

  defp to_json_value(v) when v in [:nan, :infinity, :neg_infinity] do
    {:error,
     Error.new(:serialize, "non-finite float #{inspect(v)} cannot be represented in JSON")}
  end

  defp to_json_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn elem, {:ok, acc} ->
      case to_json_value(elem) do
        {:ok, jv} -> {:cont, {:ok, [jv | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp to_json_value(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case to_json_value(v) do
        {:ok, jv} -> {:cont, {:ok, [{k, jv} | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Jason.OrderedObject.new(Enum.reverse(rev))}
      err -> err
    end
  end

  defp to_json_value(v), do: {:ok, v}

  # Formats IEEE-754 float32/float64 matching ECMAScript / Go encoding/json rules:
  # - shortest round-trip significant digits for the target precision
  # - plain decimal notation inside [1e-6, 1e21), scientific notation outside
  defp format_json_float(f, :float32) do
    target_bits = <<f::little-float-32>>

    cond do
      target_bits == <<0, 0, 0, 0>> ->
        "0"

      target_bits == <<0, 0, 0, 128>> ->
        "-0"

      true ->
        sci = find_shortest_f32_sci(f, target_bits, 0)
        normalize_json_float_str(sci, abs(f))
    end
  end

  defp format_json_float(f, :float64) do
    bits = <<f::little-float-64>>

    cond do
      bits == <<0, 0, 0, 0, 0, 0, 0, 0>> ->
        "0"

      bits == <<0, 0, 0, 0, 0, 0, 0, 128>> ->
        "-0"

      true ->
        short = :erlang.float_to_binary(f, [:short])
        normalize_json_float_str(short, abs(f))
    end
  end

  # :io_lib.format("~.Ne", [f]) uses N fractional digits (so N=0 is 1 sig fig, N=8 is 9 sig figs)
  defp find_shortest_f32_sci(f, target_bits, frac_digits) when frac_digits <= 8 do
    str =
      if frac_digits == 0 do
        # ~.2e gives 2 sig figs (e.g. "1.4e-45"); round mantissa to 1 sig fig
        s = :io_lib.format("~.2e", [f]) |> IO.iodata_to_binary()
        [mant_str, exp_str] = String.split(s, "e")
        {mant, ""} = Float.parse(mant_str)
        rounded = round(mant)

        cond do
          rounded == 10 ->
            "1e#{String.to_integer(exp_str) + 1}"

          rounded == -10 ->
            "-1e#{String.to_integer(exp_str) + 1}"

          true ->
            "#{rounded}e#{exp_str}"
        end
      else
        :io_lib.format("~.*e", [frac_digits + 1, f]) |> IO.iodata_to_binary()
      end

    case parse_float_loose(str) do
      {:ok, parsed} ->
        if <<parsed::little-float-32>> == target_bits do
          str
        else
          find_shortest_f32_sci(f, target_bits, frac_digits + 1)
        end

      :error ->
        find_shortest_f32_sci(f, target_bits, frac_digits + 1)
    end
  end

  defp find_shortest_f32_sci(f, _target_bits, _frac_digits) do
    :erlang.float_to_binary(f, [:short])
  end

  defp parse_float_loose(str) do
    case Float.parse(str) do
      {v, ""} ->
        {:ok, v}

      _ ->
        # Handle "1e-45" which Elixir's Float.parse accepts, or fallback
        :error
    end
  end

  defp normalize_json_float_str(str, abs_val) do
    {sign, unsigned} =
      case str do
        "-" <> rest -> {"-", rest}
        rest -> {"", rest}
      end

    {digits, exp} = parse_decimal_components(unsigned)
    # Trim trailing zeros from significant digits
    digits = String.trim_trailing(digits, "0")
    digits = if digits == "", do: "0", else: digits

    if abs_val >= 1.0e-6 and abs_val < 1.0e21 do
      sign <> format_plain_decimal(digits, exp)
    else
      sign <> format_sci_decimal(digits, exp)
    end
  end

  # Returns {all_digits, exponent_of_first_digit}
  # e.g. "1.25e-4" -> {"125", -4}, "50.1109" -> {"501109", 1}, "0.005" -> {"5", -3}
  defp parse_decimal_components(str) do
    {mant, exp_part} =
      case String.split(str, ["e", "E"]) do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {int_part, frac_part} =
      case String.split(mant, ".") do
        [i, f] -> {i, f}
        [i] -> {i, ""}
      end

    raw = int_part <> frac_part
    leading_zeros = count_leading_zeros(raw)
    trimmed = String.slice(raw, leading_zeros, byte_size(raw) - leading_zeros)

    if trimmed == "" do
      {"0", 0}
    else
      exp = byte_size(int_part) - 1 - leading_zeros + exp_part
      {trimmed, exp}
    end
  end

  defp count_leading_zeros(<<?0, rest::binary>>), do: 1 + count_leading_zeros(rest)
  defp count_leading_zeros(_), do: 0

  defp format_plain_decimal(digits, exp) do
    len = byte_size(digits)

    cond do
      exp >= len - 1 ->
        digits <> String.duplicate("0", exp - (len - 1))

      exp >= 0 ->
        {int_p, frac_p} = String.split_at(digits, exp + 1)
        int_p <> "." <> frac_p

      true ->
        "0." <> String.duplicate("0", -exp - 1) <> digits
    end
  end

  defp format_sci_decimal(digits, exp) do
    mant =
      if byte_size(digits) == 1 do
        digits
      else
        {first, rest} = String.split_at(digits, 1)
        first <> "." <> rest
      end

    exp_sign = if exp >= 0, do: "+", else: ""
    "#{mant}e#{exp_sign}#{exp}"
  end

  # ---------------------------------------------------------------------------
  # Message Decoding
  # ---------------------------------------------------------------------------

  defp decode_message(_bin, _inherited, depth, %{max_depth: max_depth}) when depth > max_depth do
    Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
  end

  defp decode_message(<<>>, _inherited, _depth, budget), do: {:ok, %{}, budget}

  defp decode_message(bin, inherited, depth, budget) do
    with {:ok, local_meta, budget} <- prescan_field_zero(bin, depth, nil, budget) do
      active_meta = SchemaMeta.merge(inherited, local_meta)

      state = %{
        out: %{},
        array_chunks: %{},
        sub_packets: %{},
        shapes: %{},
        owners: %{},
        budget: budget
      }

      with {:ok, state} <- decode_fields_loop(bin, active_meta, depth, state) do
        out = finalize_array_chunks(state.array_chunks, state.out)
        resolve_sub_packets(state.sub_packets, active_meta, depth, out, state.budget)
      end
    end
  end

  defp finalize_array_chunks(array_chunks, out) when map_size(array_chunks) == 0, do: out

  defp finalize_array_chunks(array_chunks, out) do
    Enum.reduce(array_chunks, out, fn {name, rev_chunks}, acc_out ->
      list =
        case rev_chunks do
          [single] -> single
          many -> many |> Enum.reverse() |> :lists.append()
        end

      Map.put(acc_out, name, list)
    end)
  end

  # Pass 1: Pre-scan all Field #0 blocks so trailing metadata renames earlier fields consistently.
  defp prescan_field_zero(<<>>, _depth, acc, budget), do: {:ok, acc, budget}

  defp prescan_field_zero(bin, depth, acc, budget) do
    with {:ok, field_num, wt, rest} <- Wire.decode_tag(bin) do
      if field_num == 0 do
        with {:ok, meta, tail, new_budget} <- SchemaMeta.decode_field(rest, depth, budget) do
          prescan_field_zero(tail, depth, SchemaMeta.merge(acc, meta), new_budget)
        end
      else
        with {:ok, tail} <- Wire.skip_fast(wt, rest) do
          prescan_field_zero(tail, depth, acc, budget)
        end
      end
    end
  end

  defp decode_fields_loop(<<>>, _meta, _depth, state), do: {:ok, state}

  defp decode_fields_loop(bin, meta, depth, state) do
    with {:ok, field_num, wt, rest} <- Wire.decode_tag(bin) do
      if field_num == 0 do
        with {:ok, _body, tail} <- Wire.decode_length_prefixed(rest) do
          decode_fields_loop(tail, meta, depth, state)
        end
      else
        name = SchemaMeta.resolve_field_name(meta, field_num)

        with :ok <- check_owner(state.owners, name, field_num),
             {:ok, shape} <- parse_field_shape(rest, wt, depth, state.budget),
             {:ok, unified_shape} <- unify_field_shape(Map.get(state.shapes, field_num), shape) do
          owners = Map.put(state.owners, name, field_num)
          shapes = Map.put(state.shapes, field_num, unified_shape)
          state = %{state | owners: owners, shapes: shapes}

          case decode_field_value(wt, rest, field_num, name, meta, depth, state) do
            {:ok, tail, new_state} -> decode_fields_loop(tail, meta, depth, new_state)
            {:error, _} = err -> err
          end
        end
      end
    end
  end

  defp check_owner(owners, name, field_num) do
    case Map.get(owners, name) do
      nil ->
        :ok

      ^field_num ->
        :ok

      other ->
        Error.parse(
          :field_name_collision,
          "fields ##{other} and ##{field_num} collide on name #{inspect(name)}"
        )
    end
  end

  defp decode_field_value(0, rest, _fnum, name, _meta, _depth, state) do
    with {:ok, v, tail} <- Wire.decode_varint(rest) do
      {:ok, tail, %{state | out: Map.put(state.out, name, v)}}
    end
  end

  defp decode_field_value(1, rest, _fnum, name, _meta, _depth, state) do
    with {:ok, u, tail} <- Wire.decode_varint(rest) do
      {:ok, tail, %{state | out: Map.put(state.out, name, Wire.decode_zigzag(u))}}
    end
  end

  defp decode_field_value(2, rest, _fnum, name, _meta, _depth, state) do
    {:ok, rest, %{state | out: Map.put(state.out, name, false)}}
  end

  defp decode_field_value(3, rest, _fnum, name, _meta, _depth, state) do
    {:ok, rest, %{state | out: Map.put(state.out, name, true)}}
  end

  defp decode_field_value(
         4,
         <<v::little-unsigned-32, tail::binary>>,
         _fnum,
         name,
         _meta,
         _depth,
         state
       ) do
    {:ok, tail, %{state | out: Map.put(state.out, name, v)}}
  end

  defp decode_field_value(4, _, _fnum, _name, _meta, _depth, _state),
    do: Error.parse(:truncated_fixed32, "truncated fixed32")

  defp decode_field_value(
         5,
         <<v::little-unsigned-64, tail::binary>>,
         _fnum,
         name,
         _meta,
         _depth,
         state
       ) do
    {:ok, tail, %{state | out: Map.put(state.out, name, v)}}
  end

  defp decode_field_value(5, _, _fnum, _name, _meta, _depth, _state),
    do: Error.parse(:truncated_fixed64, "truncated fixed64")

  defp decode_field_value(
         6,
         <<v::little-signed-32, tail::binary>>,
         _fnum,
         name,
         _meta,
         _depth,
         state
       ) do
    {:ok, tail, %{state | out: Map.put(state.out, name, v)}}
  end

  defp decode_field_value(6, _, _fnum, _name, _meta, _depth, _state),
    do: Error.parse(:truncated_sfixed32, "truncated sfixed32")

  defp decode_field_value(
         7,
         <<v::little-signed-64, tail::binary>>,
         _fnum,
         name,
         _meta,
         _depth,
         state
       ) do
    {:ok, tail, %{state | out: Map.put(state.out, name, v)}}
  end

  defp decode_field_value(7, _, _fnum, _name, _meta, _depth, _state),
    do: Error.parse(:truncated_sfixed64, "truncated sfixed64")

  defp decode_field_value(8, rest, _fnum, name, _meta, _depth, state) do
    with {:ok, f, tail} <- Wire.decode_float32(rest) do
      {:ok, tail, %{state | out: Map.put(state.out, name, {:float32, f})}}
    end
  end

  defp decode_field_value(9, rest, _fnum, name, _meta, _depth, state) do
    with {:ok, f, tail} <- Wire.decode_float64(rest) do
      {:ok, tail, %{state | out: Map.put(state.out, name, f)}}
    end
  end

  defp decode_field_value(10, rest, _fnum, name, _meta, _depth, state) do
    with {:ok, str, tail} <- Wire.decode_string(rest) do
      {:ok, tail, %{state | out: Map.put(state.out, name, str)}}
    end
  end

  defp decode_field_value(11, rest, _fnum, name, _meta, _depth, state) do
    with {:ok, bytes, tail} <- Wire.decode_length_prefixed(rest) do
      {:ok, tail, %{state | out: Map.put(state.out, name, {:bytes, bytes})}}
    end
  end

  defp decode_field_value(12, rest, fnum, name, _meta, depth, state) do
    if depth + 1 > state.budget.max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{state.budget.max_depth} exceeded")
    else
      with {:ok, sub_bytes, tail} <- Wire.decode_length_prefixed(rest) do
        case Map.get(state.sub_packets, fnum) do
          nil ->
            sub_packets = Map.put(state.sub_packets, fnum, {name, [sub_bytes]})
            {:ok, tail, %{state | sub_packets: sub_packets}}

          {^name, existing_chunks} ->
            # Validate both prior (if first concat) and incoming chunks individually so a
            # truncated submessage cannot borrow bytes across chunk boundaries.
            with :ok <-
                   validate_chunks_for_concat(existing_chunks, sub_bytes, depth + 1, state.budget) do
              sub_packets =
                Map.put(state.sub_packets, fnum, {name, [sub_bytes | existing_chunks]})

              {:ok, tail, %{state | sub_packets: sub_packets}}
            end
        end
      end
    end
  end

  defp decode_field_value(13, rest, fnum, name, meta, depth, state) do
    if depth + 1 > state.budget.max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{state.budget.max_depth} exceeded")
    else
      child_meta = SchemaMeta.child_meta(meta, fnum)

      with {:ok, elem_type, count, elem_bytes, tail} <-
             Wire.decode_array_header(rest, state.budget.max_elements),
           {:ok, budget} <- add_elements(state.budget, count),
           {:ok, items, budget} <-
             decode_array_items(elem_type, count, elem_bytes, child_meta, depth + 1, budget, []) do
        array_chunks = Map.update(state.array_chunks, name, [items], &[items | &1])
        {:ok, tail, %{state | array_chunks: array_chunks, budget: budget}}
      end
    end
  end

  defp decode_field_value(14, rest, fnum, name, meta, depth, state) do
    if depth + 1 > state.budget.max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{state.budget.max_depth} exceeded")
    else
      child_meta = SchemaMeta.child_meta(meta, fnum)
      existing = Map.get(state.out, name, %{})

      with {:ok, key_type, val_type, count, entry_bytes, tail} <-
             Wire.decode_map_header(rest, state.budget.max_elements),
           {:ok, budget} <- add_elements(state.budget, count),
           {:ok, merged_map, budget} <-
             decode_map_entries(
               key_type,
               val_type,
               count,
               entry_bytes,
               child_meta,
               depth + 1,
               budget,
               existing
             ) do
        {:ok, tail, %{state | out: Map.put(state.out, name, merged_map), budget: budget}}
      end
    end
  end

  defp decode_field_value(15, rest, _fnum, _name, _meta, _depth, _state) do
    case Wire.decode_length_prefixed(rest) do
      {:ok, payload, _tail} when byte_size(payload) >= 1 ->
        Error.parse(:unsupported_extension, "unknown WireExtended type")

      {:ok, <<>>, _tail} ->
        Error.parse(:invalid_extended, "WireExtended ByteLen must be >= 1")

      {:error, _} = err ->
        err
    end
  end

  defp validate_chunks_for_concat([single], incoming, depth, budget) do
    with {:ok, budget} <- Wire.validate_message_stream_with_budget(single, depth, budget),
         {:ok, _budget} <- Wire.validate_message_stream_with_budget(incoming, depth, budget) do
      :ok
    end
  end

  defp validate_chunks_for_concat(_already_validated_list, incoming, depth, budget) do
    case Wire.validate_message_stream_with_budget(incoming, depth, budget) do
      {:ok, _budget} -> :ok
      {:error, _} = err -> err
    end
  end

  defp resolve_sub_packets(sub_packets, meta, depth, out, budget) do
    Enum.reduce_while(sub_packets, {:ok, out, budget}, fn {fnum, {name, rev_chunks}},
                                                          {:ok, acc_out, acc_budget} ->
      packet =
        case rev_chunks do
          [single] -> single
          many -> IO.iodata_to_binary(Enum.reverse(many))
        end

      child_meta = SchemaMeta.child_meta(meta, fnum)

      case decode_message(packet, child_meta, depth + 1, acc_budget) do
        {:ok, child_obj, new_budget} ->
          {:cont, {:ok, Map.put(acc_out, name, child_obj), new_budget}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Collection Element Decoding
  # ---------------------------------------------------------------------------

  defp decode_array_items(_wt, 0, <<>>, _child_meta, _depth, budget, acc) do
    {:ok, Enum.reverse(acc), budget}
  end

  defp decode_array_items(_wt, 0, _trailing, _child_meta, _depth, _budget, _acc) do
    Error.parse(:trailing_bytes, "trailing bytes in WireArray")
  end

  defp decode_array_items(wt, count, bin, child_meta, depth, budget, acc) do
    case decode_collection_value(wt, bin, child_meta, depth, budget) do
      {:ok, val, rest, new_budget} ->
        decode_array_items(wt, count - 1, rest, child_meta, depth, new_budget, [val | acc])

      {:error, _} = err ->
        err
    end
  end

  defp decode_map_entries(_kt, _vt, 0, <<>>, _child_meta, _depth, budget, acc) do
    {:ok, acc, budget}
  end

  defp decode_map_entries(_kt, _vt, 0, _trailing, _child_meta, _depth, _budget, _acc) do
    Error.parse(:trailing_bytes, "trailing bytes in WireMap")
  end

  defp decode_map_entries(kt, vt, count, bin, child_meta, depth, budget, acc) do
    with {:ok, key, after_k} <- decode_map_key(kt, bin),
         {:ok, val, after_v, new_budget} <-
           decode_collection_value(vt, after_k, child_meta, depth, budget) do
      decode_map_entries(
        kt,
        vt,
        count - 1,
        after_v,
        child_meta,
        depth,
        new_budget,
        Map.put(acc, key, val)
      )
    end
  end

  defp decode_map_key(0, bin) do
    with {:ok, v, rest} <- Wire.decode_varint(bin), do: {:ok, Integer.to_string(v), rest}
  end

  defp decode_map_key(1, bin) do
    with {:ok, u, rest} <- Wire.decode_varint(bin),
         do: {:ok, Integer.to_string(Wire.decode_zigzag(u)), rest}
  end

  defp decode_map_key(2, <<0, rest::binary>>), do: {:ok, "false", rest}
  defp decode_map_key(2, <<1, rest::binary>>), do: {:ok, "true", rest}

  defp decode_map_key(2, <<b, _::binary>>),
    do: Error.parse(:invalid_bool_byte, "invalid map bool key #{b}")

  defp decode_map_key(2, <<>>), do: Error.parse(:truncated_bool, "truncated map bool key")

  defp decode_map_key(4, <<v::little-unsigned-32, rest::binary>>),
    do: {:ok, Integer.to_string(v), rest}

  defp decode_map_key(4, _), do: Error.parse(:truncated_fixed32, "truncated fixed32 map key")

  defp decode_map_key(5, <<v::little-unsigned-64, rest::binary>>),
    do: {:ok, Integer.to_string(v), rest}

  defp decode_map_key(5, _), do: Error.parse(:truncated_fixed64, "truncated fixed64 map key")

  defp decode_map_key(6, <<v::little-signed-32, rest::binary>>),
    do: {:ok, Integer.to_string(v), rest}

  defp decode_map_key(6, _), do: Error.parse(:truncated_sfixed32, "truncated sfixed32 map key")

  defp decode_map_key(7, <<v::little-signed-64, rest::binary>>),
    do: {:ok, Integer.to_string(v), rest}

  defp decode_map_key(7, _), do: Error.parse(:truncated_sfixed64, "truncated sfixed64 map key")

  defp decode_map_key(10, bin), do: Wire.decode_string(bin)

  defp decode_collection_value(0, bin, _meta, _depth, budget) do
    with {:ok, v, rest} <- Wire.decode_varint(bin), do: {:ok, v, rest, budget}
  end

  defp decode_collection_value(1, bin, _meta, _depth, budget) do
    with {:ok, u, rest} <- Wire.decode_varint(bin),
         do: {:ok, Wire.decode_zigzag(u), rest, budget}
  end

  defp decode_collection_value(2, <<0, rest::binary>>, _meta, _depth, budget),
    do: {:ok, false, rest, budget}

  defp decode_collection_value(2, <<1, rest::binary>>, _meta, _depth, budget),
    do: {:ok, true, rest, budget}

  defp decode_collection_value(2, <<b, _::binary>>, _meta, _depth, _budget),
    do: Error.parse(:invalid_bool_byte, "invalid boolean byte #{b} in collection")

  defp decode_collection_value(2, <<>>, _meta, _depth, _budget),
    do: Error.parse(:truncated_bool, "truncated boolean in collection")

  defp decode_collection_value(4, <<v::little-unsigned-32, rest::binary>>, _meta, _depth, budget),
    do: {:ok, v, rest, budget}

  defp decode_collection_value(4, _, _meta, _depth, _budget),
    do: Error.parse(:truncated_fixed32, "truncated fixed32")

  defp decode_collection_value(5, <<v::little-unsigned-64, rest::binary>>, _meta, _depth, budget),
    do: {:ok, v, rest, budget}

  defp decode_collection_value(5, _, _meta, _depth, _budget),
    do: Error.parse(:truncated_fixed64, "truncated fixed64")

  defp decode_collection_value(6, <<v::little-signed-32, rest::binary>>, _meta, _depth, budget),
    do: {:ok, v, rest, budget}

  defp decode_collection_value(6, _, _meta, _depth, _budget),
    do: Error.parse(:truncated_sfixed32, "truncated sfixed32")

  defp decode_collection_value(7, <<v::little-signed-64, rest::binary>>, _meta, _depth, budget),
    do: {:ok, v, rest, budget}

  defp decode_collection_value(7, _, _meta, _depth, _budget),
    do: Error.parse(:truncated_sfixed64, "truncated sfixed64")

  defp decode_collection_value(8, bin, _meta, _depth, budget) do
    with {:ok, f, rest} <- Wire.decode_float32(bin), do: {:ok, {:float32, f}, rest, budget}
  end

  defp decode_collection_value(9, bin, _meta, _depth, budget) do
    with {:ok, f, rest} <- Wire.decode_float64(bin), do: {:ok, f, rest, budget}
  end

  defp decode_collection_value(10, bin, _meta, _depth, budget) do
    with {:ok, s, rest} <- Wire.decode_string(bin), do: {:ok, s, rest, budget}
  end

  defp decode_collection_value(11, bin, _meta, _depth, budget) do
    with {:ok, b, rest} <- Wire.decode_length_prefixed(bin), do: {:ok, {:bytes, b}, rest, budget}
  end

  defp decode_collection_value(12, bin, child_meta, depth, budget) do
    if depth + 1 > budget.max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{budget.max_depth} exceeded")
    else
      with {:ok, body, rest} <- Wire.decode_length_prefixed(bin),
           {:ok, obj, new_budget} <- decode_message(body, child_meta, depth + 1, budget) do
        {:ok, obj, rest, new_budget}
      end
    end
  end

  defp decode_collection_value(13, bin, child_meta, depth, budget) do
    if depth + 1 > budget.max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{budget.max_depth} exceeded")
    else
      with {:ok, elem_type, count, elem_bytes, rest} <-
             Wire.decode_array_header(bin, budget.max_elements),
           {:ok, budget} <- add_elements(budget, count),
           {:ok, items, new_budget} <-
             decode_array_items(elem_type, count, elem_bytes, child_meta, depth + 1, budget, []) do
        {:ok, items, rest, new_budget}
      end
    end
  end

  defp decode_collection_value(14, bin, child_meta, depth, budget) do
    if depth + 1 > budget.max_depth do
      Error.parse(:max_depth_exceeded, "max container depth #{budget.max_depth} exceeded")
    else
      with {:ok, kt, vt, count, entry_bytes, rest} <-
             Wire.decode_map_header(bin, budget.max_elements),
           {:ok, budget} <- add_elements(budget, count),
           {:ok, map, new_budget} <-
             decode_map_entries(kt, vt, count, entry_bytes, child_meta, depth + 1, budget, %{}) do
        {:ok, map, rest, new_budget}
      end
    end
  end

  defp decode_collection_value(15, bin, _child_meta, _depth, _budget) do
    case Wire.decode_length_prefixed(bin) do
      {:ok, payload, _rest} when byte_size(payload) >= 1 ->
        Error.parse(:unsupported_extension, "unknown WireExtended type")

      {:ok, <<>>, _rest} ->
        Error.parse(:invalid_extended, "WireExtended ByteLen must be >= 1")

      {:error, _} = err ->
        err
    end
  end

  defp add_elements(%{elements: el, max_elements: max} = budget, count) do
    next = el + count

    if next > max do
      Error.parse(:element_limit_exceeded, "cumulative element count #{next} exceeds #{max}")
    else
      {:ok, %{budget | elements: next}}
    end
  end

  # ---------------------------------------------------------------------------
  # Blind Field Shape Consistency
  # ---------------------------------------------------------------------------

  defp parse_field_shape(_rest, 3, _depth, _budget), do: {:ok, {:scalar, 2}}

  defp parse_field_shape(_rest, wt, _depth, _budget) when wt not in [13, 14],
    do: {:ok, {:scalar, wt}}

  defp parse_field_shape(rest, wt, depth, budget) do
    case parse_container_shape(rest, wt, depth, budget) do
      {:ok, shape, _tail, _shape_budget} -> {:ok, shape}
      {:error, _} = err -> err
    end
  end

  defp parse_container_shape(_bin, _wt, depth, %{max_depth: max_depth})
       when depth + 1 > max_depth do
    Error.parse(:max_depth_exceeded, "max container depth #{max_depth} exceeded")
  end

  defp parse_container_shape(bin, 13, depth, budget) do
    with {:ok, elem_type, count, elem_bytes, tail} <-
           Wire.decode_array_header(bin, budget.max_elements),
         {:ok, budget} <- add_elements(budget, count) do
      cond do
        elem_type not in [13, 14] ->
          {:ok, {:array, {:scalar, elem_type}}, tail, budget}

        count == 0 ->
          inner = if elem_type == 13, do: {:array, :any}, else: {:map, :any, :any}
          {:ok, {:array, inner}, tail, budget}

        true ->
          with {:ok, unified_elem, budget} <-
                 parse_nested_array_shapes(
                   elem_bytes,
                   elem_type,
                   count,
                   depth + 1,
                   budget,
                   nil
                 ) do
            {:ok, {:array, unified_elem}, tail, budget}
          end
      end
    end
  end

  defp parse_container_shape(bin, 14, depth, budget) do
    with {:ok, kt, vt, count, entry_bytes, tail} <-
           Wire.decode_map_header(bin, budget.max_elements),
         {:ok, budget} <- add_elements(budget, count) do
      cond do
        vt not in [13, 14] ->
          {:ok, {:map, kt, {:scalar, vt}}, tail, budget}

        count == 0 ->
          inner = if vt == 13, do: {:array, :any}, else: {:map, :any, :any}
          {:ok, {:map, kt, inner}, tail, budget}

        true ->
          with {:ok, unified_val, budget} <-
                 parse_nested_map_shapes(entry_bytes, kt, vt, count, depth + 1, budget, nil) do
            {:ok, {:map, kt, unified_val}, tail, budget}
          end
      end
    end
  end

  defp parse_nested_array_shapes(<<>>, _elem_type, 0, _depth, budget, acc), do: {:ok, acc, budget}

  defp parse_nested_array_shapes(_trailing, _elem_type, 0, _depth, _budget, _acc),
    do: Error.parse(:trailing_bytes, "trailing bytes in nested WireArray")

  defp parse_nested_array_shapes(bin, elem_type, count, depth, budget, acc) do
    with {:ok, shape, rest, budget} <- parse_container_shape(bin, elem_type, depth, budget),
         {:ok, unified} <- unify_field_shape(acc, shape) do
      parse_nested_array_shapes(rest, elem_type, count - 1, depth, budget, unified)
    end
  end

  defp parse_nested_map_shapes(<<>>, _kt, _vt, 0, _depth, budget, acc), do: {:ok, acc, budget}

  defp parse_nested_map_shapes(_trailing, _kt, _vt, 0, _depth, _budget, _acc),
    do: Error.parse(:trailing_bytes, "trailing bytes in nested WireMap")

  defp parse_nested_map_shapes(bin, kt, vt, count, depth, budget, acc) do
    with {:ok, _k, after_k} <- decode_map_key(kt, bin),
         {:ok, shape, rest, budget} <- parse_container_shape(after_k, vt, depth, budget),
         {:ok, unified} <- unify_field_shape(acc, shape) do
      parse_nested_map_shapes(rest, kt, vt, count - 1, depth, budget, unified)
    end
  end

  defp unify_field_shape(nil, b), do: {:ok, b}
  defp unify_field_shape(:any, b), do: {:ok, b}
  defp unify_field_shape(a, :any), do: {:ok, a}
  defp unify_field_shape(a, a), do: {:ok, a}

  defp unify_field_shape({:array, a}, {:array, b}) do
    with {:ok, inner} <- unify_field_shape(a, b), do: {:ok, {:array, inner}}
  end

  defp unify_field_shape({:map, :any, _}, {:map, kt, b}), do: {:ok, {:map, kt, b}}
  defp unify_field_shape({:map, kt, a}, {:map, :any, _}), do: {:ok, {:map, kt, a}}

  defp unify_field_shape({:map, kt, a}, {:map, kt, b}) do
    with {:ok, inner} <- unify_field_shape(a, b), do: {:ok, {:map, kt, inner}}
  end

  defp unify_field_shape(a, b) do
    Error.parse(:wire_shape_mismatch, "incompatible wire shapes #{inspect(a)} vs #{inspect(b)}")
  end
end
