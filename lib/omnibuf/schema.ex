defmodule OmniBuf.Schema do
  @moduledoc """
  Tier 3: Declarative Elixir struct DSL for OmniBuf v0.1.

  Define numbered fields directly on an Elixir struct. Compile-time macros generate
  specialized iodata encoders, binary-matching decoders, merge decoders, and
  `SchemaMeta` builders with zero runtime reflection.

  ## Example

      defmodule MyApp.Location do
        use OmniBuf.Schema, name: "Location"

        field 1, :region, :string
        field 2, :datacenter, :string
        field 3, :city, :string
        field 4, :rack, :uint32
        field 5, :latitude, :float
        field 6, :longitude, :float
      end
  """

  alias OmniBuf.{Codec, SchemaMeta, Wire}

  defmacro __using__(opts) do
    schema_name = Keyword.get(opts, :name)

    quote do
      import OmniBuf.Schema, only: [field: 3, field: 4]
      Module.register_attribute(__MODULE__, :omnibuf_fields, accumulate: true)
      @omnibuf_schema_name unquote(schema_name)
      @before_compile OmniBuf.Schema
    end
  end

  defmacro field(number, name, type, opts \\ []) do
    quote do
      @omnibuf_fields {unquote(number), unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    raw_fields = Module.get_attribute(env.module, :omnibuf_fields) |> Enum.reverse()
    validate_raw_fields!(raw_fields, env.module)

    schema_name =
      Module.get_attribute(env.module, :omnibuf_schema_name) || default_name(env.module)

    fields =
      raw_fields
      |> Enum.sort_by(fn {num, _, _, _} -> num end)
      |> Enum.map(fn {num, name, type, opts} ->
        resolved_type = resolve_type(type, env)
        default = Keyword.get(opts, :default, Codec.default_value(resolved_type))
        wire_name = Keyword.get(opts, :wire_name, Atom.to_string(name))
        emit_empty = Keyword.get(opts, :emit_empty, false)

        %{
          number: num,
          name: name,
          type: resolved_type,
          default: default,
          wire_name: wire_name,
          emit_empty: emit_empty
        }
      end)

    struct_fields = Enum.map(fields, fn f -> {f.name, f.default} end)
    encode_exprs = Enum.map(fields, &gen_encode_field/1)
    decode_clauses = Enum.map(fields, &gen_decode_clause/1)
    meta_fields_ast = Enum.map(fields, fn f -> {f.number, f.wire_name} end)
    meta_children_ast = gen_meta_children(fields)

    quote do
      defstruct unquote(Macro.escape(struct_fields))

      @doc false
      def __omnibuf_fields__, do: unquote(Macro.escape(fields))

      @doc false
      def __omnibuf_name__, do: unquote(schema_name)

      @doc """
      Returns the `OmniBuf.SchemaMeta` describing this message and its nested children.
      """
      def schema_meta(visited \\ MapSet.new(), depth \\ 1) do
        visited = MapSet.put(visited, __MODULE__)

        children =
          if depth + 2 > Wire.max_depth() do
            %{}
          else
            unquote(meta_children_ast)
          end

        _ = visited

        %SchemaMeta{
          type_name: unquote(schema_name),
          fields: Map.new(unquote(Macro.escape(meta_fields_ast))),
          children: children
        }
      end

      @doc false
      def schema_meta_for(%__MODULE__{} = msg, depth \\ 1) do
        fields_map = Map.new(unquote(Macro.escape(meta_fields_ast)))

        children =
          if depth + 2 > Wire.max_depth() do
            %{}
          else
            OmniBuf.Schema.build_children_meta_for(msg, __omnibuf_fields__(), depth + 2)
          end

        %SchemaMeta{
          type_name: unquote(schema_name),
          fields: fields_map,
          children: children
        }
      end

      @doc """
      Encodes the struct into an OmniBuf binary.
      Pass `self_describing: true` to prepend Field #0 `SchemaMeta`.
      """
      def encode(%__MODULE__{} = msg, opts \\ []) do
        if OmniBuf.Native.enabled?() do
          body = OmniBuf.Native.encode_struct(__MODULE__, msg)

          if Keyword.get(opts, :self_describing, false) do
            IO.iodata_to_binary([SchemaMeta.encode_field(schema_meta_for(msg, 1)), body])
          else
            body
          end
        else
          IO.iodata_to_binary(encode_iodata(msg, opts))
        end
      end

      @doc """
      Encodes the struct into iodata (single-pass forward encoding).
      """
      def encode_iodata(%__MODULE__{} = msg, opts \\ []) do
        if OmniBuf.Native.enabled?() do
          body = OmniBuf.Native.encode_struct(__MODULE__, msg)

          if Keyword.get(opts, :self_describing, false) do
            [SchemaMeta.encode_field(schema_meta_for(msg, 1)), body]
          else
            body
          end
        else
          body = [unquote_splicing(encode_exprs)]

          if Keyword.get(opts, :self_describing, false) do
            [SchemaMeta.encode_field(schema_meta_for(msg, 1)), body]
          else
            body
          end
        end
      end

      @doc """
      Decodes an OmniBuf binary into a fresh `%#{inspect(__MODULE__)}{}` struct (replace mode).
      """
      def decode(bin) when is_binary(bin) do
        if OmniBuf.Native.enabled?() do
          OmniBuf.Native.decode_struct(__MODULE__, bin)
        else
          decode_into(bin, %__MODULE__{}, 0)
        end
      end

      @doc """
      Merges an OmniBuf binary onto an existing `%#{inspect(__MODULE__)}{}` struct (merge mode).
      """
      def merge(%__MODULE__{} = existing, bin) when is_binary(bin) do
        if OmniBuf.Native.enabled?() do
          OmniBuf.Native.merge_struct(__MODULE__, existing, bin)
        else
          decode_into(bin, existing, 0)
        end
      end

      @doc false
      def decode_into(bin, acc, depth) do
        decode_into_loop(bin, acc, %{}, depth)
      end

      defp decode_into_loop(<<>>, acc, array_chunks, _depth)
           when map_size(array_chunks) == 0 do
        {:ok, acc}
      end

      defp decode_into_loop(<<>>, acc, array_chunks, _depth) do
        acc =
          Enum.reduce(array_chunks, acc, fn {name, rev_chunks}, struct_acc ->
            existing = Map.fetch!(struct_acc, name)

            appended =
              case rev_chunks do
                [single] -> single
                many -> many |> Enum.reverse() |> :lists.append()
              end

            merged = if existing == [], do: appended, else: existing ++ appended
            Map.put(struct_acc, name, merged)
          end)

        {:ok, acc}
      end

      defp decode_into_loop(bin, acc, array_chunks, depth) do
        case Wire.decode_tag(bin) do
          {:ok, 0, 12, rest} ->
            case SchemaMeta.decode_field(rest, depth) do
              {:ok, _meta, tail} -> decode_into_loop(tail, acc, array_chunks, depth)
              {:error, _} = err -> err
            end

          {:ok, field_num, wt, rest} ->
            decode_field(field_num, wt, rest, acc, array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end

      unquote_splicing(decode_clauses)

      defp decode_field(_field_num, wt, rest, acc, array_chunks, depth) do
        case Wire.skip_validated(wt, rest, depth) do
          {:ok, tail} -> decode_into_loop(tail, acc, array_chunks, depth)
          {:error, _} = err -> err
        end
      end
    end
  end

  defp validate_raw_fields!(raw_fields, mod) do
    max_field = Wire.max_field_number()

    Enum.reduce(raw_fields, {MapSet.new(), MapSet.new()}, fn {num, name, _type, _opts},
                                                             {nums, names} ->
      if not is_integer(num) or num < 1 or num > max_field do
        raise ArgumentError,
              "invalid OmniBuf field number #{inspect(num)} in #{inspect(mod)}: must be in 1..#{max_field}"
      end

      if not is_atom(name) or name == :__struct__ do
        raise ArgumentError,
              "invalid OmniBuf field name #{inspect(name)} in #{inspect(mod)}"
      end

      if MapSet.member?(nums, num) do
        raise ArgumentError,
              "duplicate OmniBuf field number #{num} in #{inspect(mod)}"
      end

      if MapSet.member?(names, name) do
        raise ArgumentError,
              "duplicate OmniBuf field name #{inspect(name)} in #{inspect(mod)}"
      end

      {MapSet.put(nums, num), MapSet.put(names, name)}
    end)

    :ok
  end

  defp default_name(mod) do
    mod |> Module.split() |> List.last()
  end

  defp resolve_type({:array, inner}, env), do: {:array, resolve_type(inner, env)}
  defp resolve_type({:map, k, v}, env), do: {:map, resolve_type(k, env), resolve_type(v, env)}
  defp resolve_type({:message, mod}, env), do: {:message, Macro.expand(mod, env)}

  defp resolve_type(type, _env)
       when type in [
              :uint32,
              :uint64,
              :int32,
              :int64,
              :sint32,
              :sint64,
              :enum,
              :bool,
              :fixed32,
              :fixed64,
              :sfixed32,
              :sfixed64,
              :float,
              :double,
              :string,
              :bytes
            ],
       do: type

  defp resolve_type({:enum, mod}, env), do: {:enum, Macro.expand(mod, env)}

  defp resolve_type(mod, env) do
    {:message, Macro.expand(mod, env)}
  end

  # ---------------------------------------------------------------------------
  # Compile-time Encode Code Generation
  # ---------------------------------------------------------------------------

  defp gen_encode_field(%{number: num, name: name, type: :bool}) do
    tag_true = Wire.encode_tag(num, 3)

    quote do
      if Map.fetch!(msg, unquote(name)), do: unquote(tag_true), else: []
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :uint32}) do
    tag = Wire.encode_tag(num, 0)

    quote do
      case Wire.narrow_uint32(Map.fetch!(msg, unquote(name))) do
        0 -> []
        v -> [unquote(tag), Wire.encode_varint(v)]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :uint64}) do
    tag = Wire.encode_tag(num, 0)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        0 -> []
        v -> [unquote(tag), Wire.encode_varint(v)]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: t})
       when t in [:int32, :sint32, :enum] do
    tag = Wire.encode_tag(num, 1)

    quote do
      case Wire.narrow_int32(Map.fetch!(msg, unquote(name))) do
        0 -> []
        v -> [unquote(tag), Wire.encode_varint(Wire.encode_zigzag(v))]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: {:enum, _}}) do
    gen_encode_field(%{number: num, name: name, type: :enum})
  end

  defp gen_encode_field(%{number: num, name: name, type: t}) when t in [:int64, :sint64] do
    tag = Wire.encode_tag(num, 1)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        0 -> []
        v -> [unquote(tag), Wire.encode_varint(Wire.encode_zigzag(v))]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :fixed32}) do
    tag = Wire.encode_tag(num, 4)

    quote do
      case Wire.narrow_uint32(Map.fetch!(msg, unquote(name))) do
        0 -> []
        v -> [unquote(tag), <<v::little-unsigned-32>>]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :fixed64}) do
    tag = Wire.encode_tag(num, 5)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        0 -> []
        v -> [unquote(tag), <<v::little-unsigned-64>>]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :sfixed32}) do
    tag = Wire.encode_tag(num, 6)

    quote do
      case Wire.narrow_int32(Map.fetch!(msg, unquote(name))) do
        0 -> []
        v -> [unquote(tag), <<v::little-signed-32>>]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :sfixed64}) do
    tag = Wire.encode_tag(num, 7)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        0 -> []
        v -> [unquote(tag), <<v::little-signed-64>>]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :float}) do
    tag = Wire.encode_tag(num, 8)

    quote do
      case Wire.encode_float32(Map.fetch!(msg, unquote(name))) do
        <<0, 0, 0, 0>> -> []
        encoded -> [unquote(tag), encoded]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :double}) do
    tag = Wire.encode_tag(num, 9)

    quote do
      case Wire.encode_float64(Map.fetch!(msg, unquote(name))) do
        <<0, 0, 0, 0, 0, 0, 0, 0>> -> []
        encoded -> [unquote(tag), encoded]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :string}) do
    tag = Wire.encode_tag(num, 10)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        "" -> []
        s -> [unquote(tag), Wire.encode_varint(byte_size(s)), s]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: :bytes}) do
    tag = Wire.encode_tag(num, 11)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        <<>> -> []
        b -> [unquote(tag), Wire.encode_varint(byte_size(b)), b]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: {:message, mod}}) do
    tag = Wire.encode_tag(num, 12)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        nil -> []
        sub -> [unquote(tag), Wire.encode_length_prefixed(unquote(mod).encode_iodata(sub))]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: {:array, elem_type}, emit_empty: true}) do
    tag = Wire.encode_tag(num, 13)

    quote do
      [
        unquote(tag),
        Codec.encode_array_value(unquote(Macro.escape(elem_type)), Map.fetch!(msg, unquote(name)))
      ]
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: {:array, elem_type}}) do
    tag = Wire.encode_tag(num, 13)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        [] -> []
        list -> [unquote(tag), Codec.encode_array_value(unquote(Macro.escape(elem_type)), list)]
      end
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: {:map, kt, vt}, emit_empty: true}) do
    tag = Wire.encode_tag(num, 14)

    quote do
      [
        unquote(tag),
        Codec.encode_map_value(
          unquote(Macro.escape(kt)),
          unquote(Macro.escape(vt)),
          Map.fetch!(msg, unquote(name))
        )
      ]
    end
  end

  defp gen_encode_field(%{number: num, name: name, type: {:map, kt, vt}}) do
    tag = Wire.encode_tag(num, 14)

    quote do
      case Map.fetch!(msg, unquote(name)) do
        m when map_size(m) == 0 ->
          []

        m ->
          [
            unquote(tag),
            Codec.encode_map_value(unquote(Macro.escape(kt)), unquote(Macro.escape(vt)), m)
          ]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Compile-time Decode Clause Generation
  # ---------------------------------------------------------------------------

  defp gen_decode_clause(%{number: num, name: name, type: :bool}) do
    quote do
      defp decode_field(unquote(num), 2, rest, acc, array_chunks, depth) do
        decode_into_loop(rest, Map.put(acc, unquote(name), false), array_chunks, depth)
      end

      defp decode_field(unquote(num), 3, rest, acc, array_chunks, depth) do
        decode_into_loop(rest, Map.put(acc, unquote(name), true), array_chunks, depth)
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :uint32}) do
    quote do
      defp decode_field(unquote(num), 0, rest, acc, array_chunks, depth) do
        case Wire.decode_varint(rest) do
          {:ok, v, tail} ->
            decode_into_loop(
              tail,
              Map.put(acc, unquote(name), Wire.narrow_uint32(v)),
              array_chunks,
              depth
            )

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :uint64}) do
    quote do
      defp decode_field(unquote(num), 0, rest, acc, array_chunks, depth) do
        case Wire.decode_varint(rest) do
          {:ok, v, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), v), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: t})
       when t in [:int32, :sint32, :enum] do
    quote do
      defp decode_field(unquote(num), 1, rest, acc, array_chunks, depth) do
        case Wire.decode_varint(rest) do
          {:ok, u, tail} ->
            decode_into_loop(
              tail,
              Map.put(acc, unquote(name), Wire.narrow_int32(Wire.decode_zigzag(u))),
              array_chunks,
              depth
            )

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: {:enum, _}}) do
    gen_decode_clause(%{number: num, name: name, type: :enum})
  end

  defp gen_decode_clause(%{number: num, name: name, type: t}) when t in [:int64, :sint64] do
    quote do
      defp decode_field(unquote(num), 1, rest, acc, array_chunks, depth) do
        case Wire.decode_varint(rest) do
          {:ok, u, tail} ->
            decode_into_loop(
              tail,
              Map.put(acc, unquote(name), Wire.decode_zigzag(u)),
              array_chunks,
              depth
            )

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :fixed32}) do
    quote do
      defp decode_field(
             unquote(num),
             4,
             <<v::little-unsigned-32, tail::binary>>,
             acc,
             array_chunks,
             depth
           ) do
        decode_into_loop(tail, Map.put(acc, unquote(name), v), array_chunks, depth)
      end

      defp decode_field(unquote(num), 4, _rest, _acc, _array_chunks, _depth) do
        OmniBuf.Error.parse(:truncated_fixed32, "truncated fixed32")
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :fixed64}) do
    quote do
      defp decode_field(
             unquote(num),
             5,
             <<v::little-unsigned-64, tail::binary>>,
             acc,
             array_chunks,
             depth
           ) do
        decode_into_loop(tail, Map.put(acc, unquote(name), v), array_chunks, depth)
      end

      defp decode_field(unquote(num), 5, _rest, _acc, _array_chunks, _depth) do
        OmniBuf.Error.parse(:truncated_fixed64, "truncated fixed64")
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :sfixed32}) do
    quote do
      defp decode_field(
             unquote(num),
             6,
             <<v::little-signed-32, tail::binary>>,
             acc,
             array_chunks,
             depth
           ) do
        decode_into_loop(tail, Map.put(acc, unquote(name), v), array_chunks, depth)
      end

      defp decode_field(unquote(num), 6, _rest, _acc, _array_chunks, _depth) do
        OmniBuf.Error.parse(:truncated_sfixed32, "truncated sfixed32")
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :sfixed64}) do
    quote do
      defp decode_field(
             unquote(num),
             7,
             <<v::little-signed-64, tail::binary>>,
             acc,
             array_chunks,
             depth
           ) do
        decode_into_loop(tail, Map.put(acc, unquote(name), v), array_chunks, depth)
      end

      defp decode_field(unquote(num), 7, _rest, _acc, _array_chunks, _depth) do
        OmniBuf.Error.parse(:truncated_sfixed64, "truncated sfixed64")
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :float}) do
    quote do
      defp decode_field(unquote(num), 8, rest, acc, array_chunks, depth) do
        case Wire.decode_float32(rest) do
          {:ok, f, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), f), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :double}) do
    quote do
      defp decode_field(unquote(num), 9, rest, acc, array_chunks, depth) do
        case Wire.decode_float64(rest) do
          {:ok, f, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), f), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :string}) do
    quote do
      defp decode_field(unquote(num), 10, rest, acc, array_chunks, depth) do
        case Wire.decode_string(rest) do
          {:ok, s, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), s), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: :bytes}) do
    quote do
      defp decode_field(unquote(num), 11, rest, acc, array_chunks, depth) do
        case Wire.decode_length_prefixed(rest) do
          {:ok, b, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), b), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: {:message, mod}}) do
    quote do
      defp decode_field(unquote(num), 12, rest, acc, array_chunks, depth) do
        existing = Map.fetch!(acc, unquote(name))

        case Codec.decode_submsg(unquote(mod), rest, existing, depth) do
          {:ok, sub, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), sub), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: {:array, elem_type}}) do
    quote do
      defp decode_field(unquote(num), 13, rest, acc, array_chunks, depth) do
        case Codec.decode_array(rest, unquote(Macro.escape(elem_type)), depth) do
          {:ok, items, tail} ->
            array_chunks = Map.update(array_chunks, unquote(name), [items], &[items | &1])
            decode_into_loop(tail, acc, array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp gen_decode_clause(%{number: num, name: name, type: {:map, kt, vt}}) do
    quote do
      defp decode_field(unquote(num), 14, rest, acc, array_chunks, depth) do
        existing = Map.fetch!(acc, unquote(name))

        case Codec.decode_map(
               rest,
               unquote(Macro.escape(kt)),
               unquote(Macro.escape(vt)),
               existing,
               depth
             ) do
          {:ok, map, tail} ->
            decode_into_loop(tail, Map.put(acc, unquote(name), map), array_chunks, depth)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SchemaMeta Child Resolution (cycle-safe for self-referential schemas like TreeNode)
  # ---------------------------------------------------------------------------

  defp gen_meta_children(fields) do
    child_entries =
      Enum.flat_map(fields, fn f ->
        case extract_child_module(f.type) do
          nil -> []
          mod -> [{f.number, mod}]
        end
      end)

    if child_entries == [] do
      quote do: %{}
    else
      updates =
        Enum.map(child_entries, fn {num, mod} ->
          quote do
            if MapSet.member?(visited, unquote(mod)) do
              acc
            else
              Map.put(acc, unquote(num), unquote(mod).schema_meta(visited, depth + 2))
            end
          end
        end)

      Enum.reduce(updates, quote(do: %{}), fn update, acc_ast ->
        quote do
          acc = unquote(acc_ast)
          unquote(update)
        end
      end)
    end
  end

  defp extract_child_module({:message, mod}), do: mod
  defp extract_child_module({:array, inner}), do: extract_child_module(inner)
  defp extract_child_module({:map, _k, v}), do: extract_child_module(v)
  defp extract_child_module(_), do: nil

  @doc false
  def build_children_meta_for(msg, fields, child_depth) do
    Enum.reduce(fields, %{}, fn %{number: num, name: name, type: type}, acc ->
      case extract_child_module(type) do
        nil ->
          acc

        mod ->
          val = Map.get(msg, name)

          case collect_child_meta(type, val, mod, child_depth) do
            nil -> acc
            meta -> Map.put(acc, num, meta)
          end
      end
    end)
  end

  defp collect_child_meta({:message, mod}, nil, mod, _depth), do: nil

  defp collect_child_meta({:message, mod}, sub, mod, depth) do
    mod.schema_meta_for(sub, depth)
  end

  defp collect_child_meta({:array, inner}, list, mod, depth) when is_list(list) do
    Enum.reduce(list, nil, fn item, acc ->
      case collect_child_meta(inner, item, mod, depth) do
        nil -> acc
        m -> SchemaMeta.merge(acc, m)
      end
    end)
  end

  defp collect_child_meta({:map, _kt, vt}, map, mod, depth) when is_map(map) do
    Enum.reduce(map, nil, fn {_k, v}, acc ->
      case collect_child_meta(vt, v, mod, depth) do
        nil -> acc
        m -> SchemaMeta.merge(acc, m)
      end
    end)
  end

  defp collect_child_meta(_type, _val, _mod, _depth), do: nil
end
