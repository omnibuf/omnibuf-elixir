defmodule OmniBuf.Protobuf do
  @moduledoc """
  Tier 2: Direct OmniBuf v0.1 serialization and deserialization for standard
  `elixir-protobuf` (`use Protobuf`) message structs using `__message_props__/0`.
  """

  alias OmniBuf.{Codec, Error, SchemaMeta, Wire}

  @doc """
  Encodes a standard `elixir-protobuf` struct into OmniBuf wire bytes.
  Pass `self_describing: true` to prepend Field #0 `SchemaMeta`.
  """
  @spec encode(struct(), keyword()) :: binary()
  def encode(%mod{} = msg, opts \\ []) do
    IO.iodata_to_binary(encode_iodata(msg, mod, opts))
  end

  @doc """
  Encodes a standard `elixir-protobuf` struct into OmniBuf iodata.
  """
  @spec encode_iodata(struct(), module(), keyword()) :: iodata()
  def encode_iodata(msg, mod, opts \\ []) do
    props = mod.__message_props__()
    body = encode_fields(msg, props)

    if Keyword.get(opts, :self_describing, false) do
      [SchemaMeta.encode_field(schema_meta(mod)), body]
    else
      body
    end
  end

  @doc """
  Decodes OmniBuf wire bytes into a fresh `elixir-protobuf` struct of `mod` (replace mode).
  """
  @spec decode(binary(), module()) :: {:ok, struct()} | {:error, Error.t()}
  def decode(bin, mod) when is_binary(bin) and is_atom(mod) do
    decode_into(bin, struct(mod), mod, 0)
  end

  @doc """
  Merges OmniBuf wire bytes onto an existing `elixir-protobuf` struct (merge mode).
  """
  @spec merge(struct(), binary()) :: {:ok, struct()} | {:error, Error.t()}
  def merge(%mod{} = existing, bin) when is_binary(bin) do
    decode_into(bin, existing, mod, 0)
  end

  @doc """
  Builds an `OmniBuf.SchemaMeta` from an `elixir-protobuf` module's `__message_props__/0`.
  """
  @spec schema_meta(module(), MapSet.t()) :: SchemaMeta.t()
  def schema_meta(mod, visited \\ MapSet.new()) do
    visited = MapSet.put(visited, mod)
    props = mod.__message_props__()

    {fields, children} =
      Enum.reduce(props.field_props, {%{}, %{}}, fn {fnum, fp}, {f_acc, c_acc} ->
        f_acc = Map.put(f_acc, fnum, fp.name)

        c_acc =
          cond do
            fp.map? ->
              entry_props = fp.type.__message_props__()
              val_fp = Map.fetch!(entry_props.field_props, 2)

              if val_fp.embedded? and not MapSet.member?(visited, val_fp.type) do
                Map.put(c_acc, fnum, schema_meta(val_fp.type, visited))
              else
                c_acc
              end

            fp.embedded? and not MapSet.member?(visited, fp.type) ->
              Map.put(c_acc, fnum, schema_meta(fp.type, visited))

            true ->
              c_acc
          end

        {f_acc, c_acc}
      end)

    type_name = mod |> Module.split() |> List.last()
    %SchemaMeta{type_name: type_name, fields: fields, children: children}
  end

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  defp encode_fields(msg, props) do
    oneof_names = Map.new(props.oneof, fn {name, idx} -> {idx, name} end)

    Enum.map(props.ordered_tags, fn fnum ->
      fp = Map.fetch!(props.field_props, fnum)

      case fp.oneof do
        nil ->
          val = Map.get(msg, fp.name_atom)
          encode_field(fp, val, false)

        idx ->
          oneof_key = Map.fetch!(oneof_names, idx)

          case Map.get(msg, oneof_key) do
            {fname, val} when fname == fp.name_atom -> encode_field(fp, val, true)
            _ -> []
          end
      end
    end)
  end

  defp encode_field(%{map?: true} = fp, val, _explicit?) do
    case val do
      m when is_map(m) and map_size(m) > 0 ->
        entry_props = fp.type.__message_props__()
        key_fp = Map.fetch!(entry_props.field_props, 1)
        val_fp = Map.fetch!(entry_props.field_props, 2)
        kt = pb_wire_type(key_fp)
        vt = pb_wire_type(val_fp)

        sorted = Enum.sort_by(Map.to_list(m), fn {k, _v} -> k end)

        entries =
          Enum.map(sorted, fn {k, v} ->
            [encode_pb_element(key_fp, k), encode_pb_element(val_fp, v)]
          end)

        [
          Wire.encode_tag(fp.fnum, 14),
          Wire.encode_length_prefixed([<<kt, vt>>, Wire.encode_varint(length(sorted)), entries])
        ]

      _ ->
        []
    end
  end

  defp encode_field(%{repeated?: true} = fp, val, _explicit?) do
    case val do
      list when is_list(list) and list != [] ->
        wt = pb_wire_type(fp)
        elems = Enum.map(list, fn e -> encode_pb_element(fp, e) end)

        [
          Wire.encode_tag(fp.fnum, 13),
          Wire.encode_length_prefixed([<<wt>>, Wire.encode_varint(length(list)), elems])
        ]

      _ ->
        []
    end
  end

  defp encode_field(%{embedded?: true} = fp, val, _explicit?) do
    case val do
      nil ->
        []

      sub ->
        [Wire.encode_tag(fp.fnum, 12), Wire.encode_length_prefixed(encode_iodata(sub, fp.type))]
    end
  end

  defp encode_field(%{type: :bool} = fp, val, explicit?) do
    cond do
      val == true -> Wire.encode_tag(fp.fnum, 3)
      val == false and explicit? -> Wire.encode_tag(fp.fnum, 2)
      true -> []
    end
  end

  defp encode_field(fp, val, explicit?) do
    cond do
      is_nil(val) ->
        []

      not explicit? and default_pb_value?(fp, val) ->
        []

      true ->
        wt = pb_wire_type(fp)
        [Wire.encode_tag(fp.fnum, wt), encode_pb_element(fp, val)]
    end
  end

  defp default_pb_value?(%{enum?: true, type: {:enum, enum_mod}}, val) do
    enum_to_int(enum_mod, val) == 0
  end

  defp default_pb_value?(%{type: :float}, v) when is_number(v) and v == 0.0 do
    <<v::little-float-32>> == <<0, 0, 0, 0>>
  end

  defp default_pb_value?(%{type: :double}, v) when is_number(v) and v == 0.0 do
    <<v::little-float-64>> == <<0, 0, 0, 0, 0, 0, 0, 0>>
  end

  defp default_pb_value?(%{type: :string}, ""), do: true
  defp default_pb_value?(%{type: :bytes}, <<>>), do: true

  defp default_pb_value?(%{type: t}, 0)
       when t in [
              :uint32,
              :uint64,
              :int32,
              :int64,
              :sint32,
              :sint64,
              :fixed32,
              :fixed64,
              :sfixed32,
              :sfixed64
            ],
       do: true

  defp default_pb_value?(_, _), do: false

  defp encode_pb_element(%{embedded?: true}, nil), do: <<0x01>>

  defp encode_pb_element(%{embedded?: true, type: mod}, sub),
    do: Wire.encode_length_prefixed(encode_iodata(sub, mod))

  defp encode_pb_element(%{enum?: true, type: {:enum, enum_mod}}, val) do
    Wire.encode_varint(Wire.encode_zigzag(Wire.narrow_int32(enum_to_int(enum_mod, val))))
  end

  defp encode_pb_element(%{type: t}, val), do: Codec.encode_element(t, val)

  defp enum_to_int(_mod, n) when is_integer(n), do: n
  defp enum_to_int(mod, atom) when is_atom(atom), do: mod.value(atom)

  defp pb_wire_type(%{embedded?: true}), do: 12
  defp pb_wire_type(%{enum?: true}), do: 1
  defp pb_wire_type(%{type: t}), do: Codec.wire_type_for(t)

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  defp decode_into(<<>>, acc, _mod, _depth), do: {:ok, acc}

  defp decode_into(bin, acc, mod, depth) do
    props = mod.__message_props__()
    oneof_names = Map.new(props.oneof, fn {name, idx} -> {idx, name} end)
    decode_loop(bin, acc, props, oneof_names, depth)
  end

  defp decode_loop(<<>>, acc, _props, _oneof_names, _depth), do: {:ok, acc}

  defp decode_loop(bin, acc, props, oneof_names, depth) do
    case Wire.decode_tag(bin) do
      {:ok, 0, 12, rest} ->
        case SchemaMeta.decode_field(rest, depth) do
          {:ok, _meta, tail} -> decode_loop(tail, acc, props, oneof_names, depth)
          {:error, _} = err -> err
        end

      {:ok, field_num, wt, rest} ->
        case Map.get(props.field_props, field_num) do
          nil ->
            case Wire.skip_validated(wt, rest, depth) do
              {:ok, tail} -> decode_loop(tail, acc, props, oneof_names, depth)
              {:error, _} = err -> err
            end

          fp ->
            case decode_known_field(fp, wt, rest, acc, oneof_names, depth) do
              {:ok, new_acc, tail} -> decode_loop(tail, new_acc, props, oneof_names, depth)
              {:error, _} = err -> err
            end
        end

      {:error, _} = err ->
        err
    end
  end

  defp decode_known_field(%{map?: true} = fp, 14, rest, acc, _oneof_names, depth) do
    if depth + 1 > Wire.max_depth() do
      Error.parse(:max_depth_exceeded, "max container depth #{Wire.max_depth()} exceeded")
    else
      entry_props = fp.type.__message_props__()
      key_fp = Map.fetch!(entry_props.field_props, 1)
      val_fp = Map.fetch!(entry_props.field_props, 2)
      expected_kt = pb_wire_type(key_fp)
      expected_vt = pb_wire_type(val_fp)

      with {:ok, kt, vt, count, entry_bytes, tail} <- Wire.decode_map_header(rest) do
        if kt != expected_kt or vt != expected_vt do
          Error.parse(
            :collection_type_mismatch,
            "WireMap type mismatch: expected <#{expected_kt}, #{expected_vt}>, got <#{kt}, #{vt}>"
          )
        else
          existing = Map.get(acc, fp.name_atom) || %{}

          with {:ok, merged} <-
                 decode_pb_map_pairs(key_fp, val_fp, count, entry_bytes, depth + 1, existing) do
            {:ok, Map.put(acc, fp.name_atom, merged), tail}
          end
        end
      end
    end
  end

  defp decode_known_field(
         %{repeated?: true, map?: false} = fp,
         13,
         rest,
         acc,
         _oneof_names,
         depth
       ) do
    if depth + 1 > Wire.max_depth() do
      Error.parse(:max_depth_exceeded, "max container depth #{Wire.max_depth()} exceeded")
    else
      expected_wt = pb_wire_type(fp)

      with {:ok, actual_wt, count, elem_bytes, tail} <- Wire.decode_array_header(rest) do
        if actual_wt != expected_wt do
          Error.parse(
            :collection_type_mismatch,
            "WireArray ElementType mismatch: expected #{expected_wt}, got #{actual_wt}"
          )
        else
          with {:ok, items} <- decode_pb_array_elems(fp, count, elem_bytes, depth + 1, []) do
            existing = Map.get(acc, fp.name_atom) || []
            merged = if existing == [], do: items, else: existing ++ items
            {:ok, Map.put(acc, fp.name_atom, merged), tail}
          end
        end
      end
    end
  end

  defp decode_known_field(
         %{embedded?: true, repeated?: false, map?: false} = fp,
         12,
         rest,
         acc,
         oneof_names,
         depth
       ) do
    if depth + 1 > Wire.max_depth() do
      Error.parse(:max_depth_exceeded, "max container depth #{Wire.max_depth()} exceeded")
    else
      existing =
        case fp.oneof do
          nil ->
            Map.get(acc, fp.name_atom)

          idx ->
            oneof_key = Map.fetch!(oneof_names, idx)

            case Map.get(acc, oneof_key) do
              {fname, sub} when fname == fp.name_atom -> sub
              _ -> nil
            end
        end

      with {:ok, body, tail} <- Wire.decode_length_prefixed(rest),
           {:ok, sub} <- decode_into(body, existing || struct(fp.type), fp.type, depth + 1) do
        {:ok, put_pb_field(acc, fp, sub, oneof_names), tail}
      end
    end
  end

  defp decode_known_field(
         %{type: :bool, repeated?: false} = fp,
         wt,
         rest,
         acc,
         oneof_names,
         _depth
       )
       when wt in [2, 3] do
    {:ok, put_pb_field(acc, fp, wt == 3, oneof_names), rest}
  end

  defp decode_known_field(
         %{repeated?: false, embedded?: false, map?: false} = fp,
         wt,
         rest,
         acc,
         oneof_names,
         depth
       ) do
    expected_wt = pb_wire_type(fp)

    if wt == expected_wt do
      case decode_pb_element(fp, rest, depth) do
        {:ok, val, tail} -> {:ok, put_pb_field(acc, fp, val, oneof_names), tail}
        {:error, _} = err -> err
      end
    else
      case Wire.skip_validated(wt, rest, depth) do
        {:ok, tail} -> {:ok, acc, tail}
        {:error, _} = err -> err
      end
    end
  end

  defp decode_known_field(_fp, wt, rest, acc, _oneof_names, depth) do
    case Wire.skip_validated(wt, rest, depth) do
      {:ok, tail} -> {:ok, acc, tail}
      {:error, _} = err -> err
    end
  end

  defp put_pb_field(acc, %{oneof: nil, name_atom: name}, val, _oneof_names) do
    Map.put(acc, name, val)
  end

  defp put_pb_field(acc, %{oneof: idx, name_atom: name}, val, oneof_names) do
    oneof_key = Map.fetch!(oneof_names, idx)
    Map.put(acc, oneof_key, {name, val})
  end

  defp decode_pb_array_elems(_fp, 0, <<>>, _depth, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_pb_array_elems(_fp, 0, _trailing, _depth, _acc),
    do: Error.parse(:trailing_bytes, "trailing bytes in WireArray")

  defp decode_pb_array_elems(fp, count, bin, depth, acc) do
    case decode_pb_element(fp, bin, depth) do
      {:ok, val, rest} -> decode_pb_array_elems(fp, count - 1, rest, depth, [val | acc])
      {:error, _} = err -> err
    end
  end

  defp decode_pb_map_pairs(_kfp, _vfp, 0, <<>>, _depth, acc), do: {:ok, acc}

  defp decode_pb_map_pairs(_kfp, _vfp, 0, _trailing, _depth, _acc),
    do: Error.parse(:trailing_bytes, "trailing bytes in WireMap")

  defp decode_pb_map_pairs(key_fp, val_fp, count, bin, depth, acc) do
    with {:ok, k, after_k} <- decode_pb_element(key_fp, bin, depth),
         {:ok, v, after_v} <- decode_pb_element(val_fp, after_k, depth) do
      decode_pb_map_pairs(key_fp, val_fp, count - 1, after_v, depth, Map.put(acc, k, v))
    end
  end

  defp decode_pb_element(%{embedded?: true, type: mod}, bin, depth) do
    if depth + 1 > Wire.max_depth() do
      Error.parse(:max_depth_exceeded, "max container depth #{Wire.max_depth()} exceeded")
    else
      with {:ok, body, tail} <- Wire.decode_length_prefixed(bin),
           {:ok, sub} <- decode_into(body, struct(mod), mod, depth + 1) do
        {:ok, sub, tail}
      end
    end
  end

  defp decode_pb_element(%{enum?: true, type: {:enum, enum_mod}}, bin, _depth) do
    with {:ok, u, tail} <- Wire.decode_varint(bin) do
      int_val = Wire.narrow_int32(Wire.decode_zigzag(u))
      val = enum_mod.key(int_val)
      {:ok, val, tail}
    end
  end

  defp decode_pb_element(%{type: t}, bin, depth) do
    Codec.decode_element(t, bin, depth)
  end
end
