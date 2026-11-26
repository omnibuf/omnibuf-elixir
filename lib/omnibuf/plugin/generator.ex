defmodule OmniBuf.Plugin.Generator do
  @moduledoc """
  Code generator for `protoc-gen-omnibuf-elixir` (Tier 1).

  Generates idiomatic Elixir modules from Protobuf `FileDescriptorProto` definitions
  (proto2, proto3, and Editions 2023/2024/2026):
  - Struct modules with single-pass iodata encoders, binary-matching decoders,
    replace/merge decoding, explicit presence, `oneof` support, and `SchemaMeta` builders.
  - Lazy zero-decode `<Message>.Opaque` view modules with O(fields) field getters
    and in-place iodata wire splicing.
  """

  alias Google.Protobuf.Compiler.{CodeGeneratorRequest, CodeGeneratorResponse}
  alias Google.Protobuf.{DescriptorProto, FieldDescriptorProto, FileDescriptorProto}
  alias OmniBuf.Plugin.Editions

  @doc """
  Processes a `CodeGeneratorRequest` and returns a `CodeGeneratorResponse`.
  """
  @spec generate(CodeGeneratorRequest.t()) :: CodeGeneratorResponse.t()
  def generate(%CodeGeneratorRequest{} = req) do
    params = parse_params(req.parameter || "")
    prefix = Map.get(params, "module_prefix", "")

    # Build lookup tables across all proto_files (including imported dependencies)
    type_map = build_type_map(req.proto_file, prefix)
    map_entries = build_map_entries(req.proto_file)
    enum_info = Editions.build_enum_info(req.proto_file)
    targets = MapSet.new(req.file_to_generate)

    target_files = Enum.filter(req.proto_file, fn f -> MapSet.member?(targets, f.name) end)

    case validate_target_files(target_files, enum_info, map_entries) do
      {:ok, resolved_pairs} ->
        files =
          Enum.map(resolved_pairs, fn {file, file_ctx} ->
            generate_file(file, prefix, type_map, map_entries, file_ctx)
          end)

        %CodeGeneratorResponse{
          supported_features: Editions.supported_features(),
          minimum_edition: Editions.minimum_edition(),
          maximum_edition: Editions.maximum_edition(),
          file: files
        }

      {:error, err_msg} ->
        %CodeGeneratorResponse{
          error: err_msg,
          supported_features: Editions.supported_features(),
          minimum_edition: Editions.minimum_edition(),
          maximum_edition: Editions.maximum_edition()
        }
    end
  end

  defp validate_target_files(target_files, enum_info, map_entries) do
    Enum.reduce_while(target_files, {:ok, []}, fn file, {:ok, acc} ->
      case Editions.validate_and_resolve_file(file, enum_info, map_entries) do
        {:ok, file_ctx} -> {:cont, {:ok, [{file, file_ctx} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _} = err -> err
    end
  end

  defp parse_params(""), do: %{}

  defp parse_params(param_str) do
    param_str
    |> String.split(",", trim: true)
    |> Enum.into(%{}, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {String.trim(k), String.trim(v)}
        [k] -> {String.trim(k), "true"}
      end
    end)
  end

  defp build_type_map(files, prefix) do
    Enum.reduce(files, %{}, fn %FileDescriptorProto{
                                 package: pkg,
                                 message_type: msgs,
                                 enum_type: enums
                               },
                               acc ->
      pkg_prefix = if pkg in [nil, ""], do: "", else: ".#{pkg}"
      mod_prefix = package_to_module(pkg || "", prefix)

      acc =
        Enum.reduce(enums, acc, fn e, m ->
          full_name = "#{pkg_prefix}.#{e.name}"
          Map.put(m, full_name, {:enum, join_mod(mod_prefix, camelize(e.name))})
        end)

      Enum.reduce(msgs, acc, fn msg, m ->
        collect_msg_types(msg, pkg_prefix, mod_prefix, m)
      end)
    end)
  end

  defp collect_msg_types(%DescriptorProto{} = msg, pkg_prefix, mod_prefix, acc) do
    full_name = "#{pkg_prefix}.#{msg.name}"
    mod_name = join_mod(mod_prefix, camelize(msg.name))
    acc = Map.put(acc, full_name, {:message, mod_name})

    acc =
      Enum.reduce(msg.enum_type, acc, fn e, m ->
        Map.put(m, "#{full_name}.#{e.name}", {:enum, join_mod(mod_name, camelize(e.name))})
      end)

    Enum.reduce(msg.nested_type, acc, fn nested, m ->
      collect_msg_types(nested, full_name, mod_name, m)
    end)
  end

  defp build_map_entries(files) do
    Enum.reduce(files, %{}, fn %FileDescriptorProto{package: pkg, message_type: msgs}, acc ->
      pkg_prefix = if pkg in [nil, ""], do: "", else: ".#{pkg}"

      Enum.reduce(msgs, acc, fn msg, m ->
        collect_map_entries(msg, pkg_prefix, m)
      end)
    end)
  end

  defp collect_map_entries(%DescriptorProto{} = msg, pkg_prefix, acc) do
    full_name = "#{pkg_prefix}.#{msg.name}"

    acc =
      if msg.options && msg.options.map_entry do
        key_f = Enum.find(msg.field, &(&1.number == 1))
        val_f = Enum.find(msg.field, &(&1.number == 2))
        Map.put(acc, full_name, {msg, key_f, val_f})
      else
        acc
      end

    Enum.reduce(msg.nested_type, acc, fn nested, m ->
      collect_map_entries(nested, full_name, m)
    end)
  end

  defp generate_file(%FileDescriptorProto{} = file, prefix, type_map, map_entries, file_ctx) do
    out_name =
      file.name
      |> String.replace_suffix(".proto", "_omnibuf.ex")

    pkg_prefix = if file.package in [nil, ""], do: "", else: ".#{file.package}"
    mod_prefix = package_to_module(file.package || "", prefix)

    enum_blocks =
      Enum.map(file.enum_type, fn e ->
        gen_enum(e, join_mod(mod_prefix, camelize(e.name)))
      end)

    msg_blocks =
      Enum.flat_map(file.message_type, fn msg ->
        gen_message(msg, pkg_prefix, mod_prefix, type_map, map_entries, file_ctx)
      end)

    header = """
    # Code generated by protoc-gen-omnibuf-elixir. DO NOT EDIT.
    # source: #{file.name}
    """

    content =
      [header | enum_blocks ++ msg_blocks]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    formatted = IO.iodata_to_binary([Code.format_string!(content), "\n"])

    %CodeGeneratorResponse.File{
      name: out_name,
      content: formatted
    }
  end

  @elixir_reserved_keywords MapSet.new(~w(
    end do fn true false nil and or not in after else catch rescue when
  ))

  defp gen_enum(enum_desc, mod_name) do
    entries =
      Enum.map_join(enum_desc.value, "\n", fn v ->
        fn_name = escape_enum_fn_name(v.name)
        "  def #{fn_name}, do: #{v.number}"
      end)

    """
    defmodule #{mod_name} do
      @moduledoc false
    #{entries}
    end
    """
  end

  defp escape_enum_fn_name(name) do
    down = String.downcase(name)

    if MapSet.member?(@elixir_reserved_keywords, down) do
      "#{down}_"
    else
      down
    end
  end

  defp gen_message(%DescriptorProto{options: %{map_entry: true}}, _pkg, _mod, _tm, _me, _ctx),
    do: []

  defp gen_message(%DescriptorProto{} = msg, pkg_prefix, mod_prefix, type_map, map_entries, ctx) do
    full_name = "#{pkg_prefix}.#{msg.name}"
    mod_name = join_mod(mod_prefix, camelize(msg.name))

    nested_enums =
      Enum.map(msg.enum_type, fn e ->
        gen_enum(e, join_mod(mod_name, camelize(e.name)))
      end)

    nested_msgs =
      Enum.flat_map(msg.nested_type, fn nested ->
        gen_message(nested, full_name, mod_name, type_map, map_entries, ctx)
      end)

    {oneof_raw_fields, regular_raw_fields} =
      Enum.split_with(msg.field, fn f ->
        f.oneof_index != nil and not (f.proto3_optional == true)
      end)

    fields =
      regular_raw_fields
      |> Enum.sort_by(& &1.number)
      |> Enum.map(fn f -> analyze_field(f, full_name, type_map, map_entries, ctx) end)

    grouped_oneof_fields = Enum.group_by(oneof_raw_fields, & &1.oneof_index)

    oneofs =
      msg.oneof_decl
      |> Enum.with_index()
      |> Enum.flat_map(fn {oneof_decl, idx} ->
        case Map.get(grouped_oneof_fields, idx) do
          nil ->
            []

          [] ->
            []

          raw_branches ->
            branches =
              raw_branches
              |> Enum.sort_by(& &1.number)
              |> Enum.map(fn f ->
                analyze_oneof_branch(f, type_map, ctx)
              end)

            [%{name: oneof_decl.name, branches: branches}]
        end
      end)

    field_lines =
      Enum.map(fields, fn f ->
        if f.kind == :scalar and f.optional do
          "  field #{f.number}, :#{f.name}, #{f.schema_type_code}, optional: true"
        else
          "  field #{f.number}, :#{f.name}, #{f.schema_type_code}"
        end
      end)

    oneof_lines =
      Enum.map(oneofs, fn o ->
        branch_items =
          Enum.map_join(o.branches, ",\n", fn b ->
            "    {#{b.number}, :#{b.name}, #{b.schema_type_code}}"
          end)

        """
          oneof :#{o.name}, [
        #{branch_items}
          ]
        """
      end)

    schema_body = Enum.join(field_lines ++ oneof_lines, "\n")

    main_mod = """
    defmodule #{mod_name} do
      @moduledoc false
      use OmniBuf.Schema, name: #{inspect(msg.name)}

    #{schema_body}
    end
    """

    opaque_mod = gen_opaque_module(mod_name, fields, oneofs)

    [main_mod, opaque_mod] ++ nested_enums ++ nested_msgs
  end

  defp gen_opaque_module(mod_name, fields, oneofs) do
    field_getters = Enum.map_join(fields, "\n", &gen_opaque_getter/1)
    oneof_getters = Enum.map_join(oneofs, "\n", &gen_opaque_oneof_getter/1)
    field_setters = Enum.map_join(fields, "\n", &gen_opaque_setter/1)
    oneof_setters = Enum.map_join(oneofs, "\n", &gen_opaque_oneof_setter/1)

    body =
      [field_getters, oneof_getters, field_setters, oneof_setters]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    alias_line =
      if String.contains?(body, "Codec.") do
        "  alias OmniBuf.{Codec, Error, Opaque}"
      else
        "  alias OmniBuf.{Error, Opaque}"
      end

    """
    defmodule #{mod_name}.Opaque do
      @moduledoc false
    #{alias_line}

      defstruct data: <<>>, dirty_values: %{}, dirty_wire: %{}

      @type t :: %__MODULE__{
              data: binary(),
              dirty_values: map(),
              dirty_wire: map()
            }

      @spec new(binary()) :: t()
      def new(bin) when is_binary(bin), do: %__MODULE__{data: bin}

      @spec marshal(t()) :: {:ok, binary()} | {:error, Error.t()}
      def marshal(%__MODULE__{data: data, dirty_wire: dirty_wire}) do
        Opaque.splice(data, dirty_wire)
      end

      @spec marshal!(t()) :: binary()
      def marshal!(%__MODULE__{} = op) do
        case marshal(op) do
          {:ok, bin} -> bin
          {:error, err} -> raise err
        end
      end

    #{body}
    end
    """
  end

  # ---------------------------------------------------------------------------
  # Opaque Getters
  # ---------------------------------------------------------------------------

  defp gen_opaque_getter(%{
         kind: :scalar,
         number: num,
         name: name,
         scalar_type: :bool,
         optional: true
       }) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_last(data, #{num}, :bool) do
              {:ok, {:found, wt, _rest}} -> wt == 3
              _ -> nil
            end
        end
      end

      def has_#{name}?(%__MODULE__{} = op), do: get_#{name}(op) != nil
    """
  end

  defp gen_opaque_getter(%{kind: :scalar, number: num, name: name, scalar_type: :bool}) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_last(data, #{num}, :bool) do
              {:ok, {:found, wt, _rest}} -> wt == 3
              _ -> false
            end
        end
      end
    """
  end

  defp gen_opaque_getter(%{
         kind: :scalar,
         number: num,
         name: name,
         scalar_type: st,
         wire_type: wt,
         optional: true
       }) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_last(data, #{num}, #{wt}) do
              {:ok, {:found, #{wt}, rest}} ->
                case Codec.decode_element(#{inspect(st)}, rest, 0) do
                  {:ok, v, _tail} -> v
                  _ -> nil
                end

              _ ->
                nil
            end
        end
      end

      def has_#{name}?(%__MODULE__{} = op), do: get_#{name}(op) != nil
    """
  end

  defp gen_opaque_getter(%{
         kind: :scalar,
         number: num,
         name: name,
         scalar_type: st,
         wire_type: wt,
         default_code: def_code
       }) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_last(data, #{num}, #{wt}) do
              {:ok, {:found, #{wt}, rest}} ->
                case Codec.decode_element(#{inspect(st)}, rest, 0) do
                  {:ok, v, _tail} -> v
                  _ -> #{def_code}
                end

              _ ->
                #{def_code}
            end
        end
      end
    """
  end

  defp gen_opaque_getter(%{kind: :message, number: num, name: name, target_mod: target_mod}) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, nil} ->
            #{target_mod}.Opaque.new(<<>>)

          {:ok, %{__struct__: #{target_mod}} = sub} ->
            #{target_mod}.Opaque.new(#{target_mod}.encode(sub))

          {:ok, %{__struct__: #{target_mod}.Opaque} = sub_op} ->
            sub_op

          :error ->
            case Opaque.extract_submsg(data, #{num}) do
              {:ok, nil} -> #{target_mod}.Opaque.new(<<>>)
              {:ok, body} -> #{target_mod}.Opaque.new(body)
              _ -> #{target_mod}.Opaque.new(<<>>)
            end
        end
      end

      def has_#{name}?(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, nil} -> false
          {:ok, _} -> true
          :error ->
            case Opaque.find_last(data, #{num}, 12) do
              {:ok, {:found, 12, _}} -> true
              _ -> false
            end
        end
      end

      def decode_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.extract_submsg(data, #{num}) do
              {:ok, nil} ->
                nil

              {:ok, body} ->
                case #{target_mod}.decode(body) do
                  {:ok, sub} -> sub
                  _ -> nil
                end

              _ ->
                nil
            end
        end
      end
    """
  end

  defp gen_opaque_getter(%{kind: :array, number: num, name: name, elem_type_code: elem_code}) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_all(data, #{num}, 13) do
              {:ok, occs} ->
                Enum.flat_map(occs, fn {13, rest} ->
                  case Codec.decode_array(rest, #{elem_code}, 0) do
                    {:ok, items, _} -> items
                    _ -> []
                  end
                end)

              _ ->
                []
            end
        end
      end
    """
  end

  defp gen_opaque_getter(%{
         kind: :map,
         number: num,
         name: name,
         key_type_code: kt_code,
         val_type_code: vt_code
       }) do
    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, #{num}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_all(data, #{num}, 14) do
              {:ok, occs} ->
                Enum.reduce(occs, %{}, fn {14, rest}, acc ->
                  case Codec.decode_map(rest, #{kt_code}, #{vt_code}, acc, 0) do
                    {:ok, m, _} -> m
                    _ -> acc
                  end
                end)

              _ ->
                %{}
            end
        end
      end
    """
  end

  defp gen_opaque_oneof_getter(%{name: name, branches: branches}) do
    spec_entries =
      Enum.map_join(branches, ", ", fn
        %{kind: :scalar, scalar_type: :bool, number: num} -> "#{num} => :bool"
        %{kind: :scalar, wire_type: wt, number: num} -> "#{num} => #{wt}"
        %{kind: :message, number: num} -> "#{num} => 12"
      end)

    match_clauses =
      Enum.map_join(branches, "\n", fn
        %{kind: :scalar, scalar_type: :bool, number: num, name: bname} ->
          """
                  {:ok, {:found, #{num}, wt, _rest}} ->
                    {:#{bname}, wt == 3}
          """

        %{kind: :scalar, scalar_type: st, wire_type: wt, number: num, name: bname} ->
          """
                  {:ok, {:found, #{num}, #{wt}, rest}} ->
                    case Codec.decode_element(#{inspect(st)}, rest, 0) do
                      {:ok, v, _tail} -> {:#{bname}, v}
                      _ -> nil
                    end
          """

        %{kind: :message, target_mod: target_mod, number: num, name: bname} ->
          """
                  {:ok, {:found, #{num}, 12, body}} ->
                    case #{target_mod}.decode(body) do
                      {:ok, sub} -> {:#{bname}, sub}
                      _ -> nil
                    end
          """
      end)

    """
      def get_#{name}(%__MODULE__{dirty_values: dv, data: data}) do
        case Map.fetch(dv, {:oneof, :#{name}}) do
          {:ok, v} ->
            v

          :error ->
            case Opaque.find_last_oneof(data, %{#{spec_entries}}) do
    #{match_clauses}
              _ ->
                nil
            end
        end
      end
    """
  end

  # ---------------------------------------------------------------------------
  # Opaque Setters
  # ---------------------------------------------------------------------------

  defp gen_opaque_setter(%{
         kind: :scalar,
         number: num,
         name: name,
         scalar_type: :bool,
         optional: true
       }) do
    tag_false = OmniBuf.Wire.encode_tag(num, 2)
    tag_true = OmniBuf.Wire.encode_tag(num, 3)

    """
      def set_#{name}(%__MODULE__{} = op, nil) do
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, nil), dirty_wire: Map.put(op.dirty_wire, #{num}, [])}
      end

      def set_#{name}(%__MODULE__{} = op, val) when is_boolean(val) do
        wire = if val, do: #{inspect(tag_true)}, else: #{inspect(tag_false)}
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, val), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_setter(%{kind: :scalar, number: num, name: name, scalar_type: :bool}) do
    tag_true = OmniBuf.Wire.encode_tag(num, 3)

    """
      def set_#{name}(%__MODULE__{} = op, val) when is_boolean(val) do
        wire = if val, do: #{inspect(tag_true)}, else: []
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, val), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_setter(%{
         kind: :scalar,
         number: num,
         name: name,
         scalar_type: st,
         wire_type: wt,
         optional: true
       }) do
    tag = OmniBuf.Wire.encode_tag(num, wt)

    """
      def set_#{name}(%__MODULE__{} = op, nil) do
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, nil), dirty_wire: Map.put(op.dirty_wire, #{num}, [])}
      end

      def set_#{name}(%__MODULE__{} = op, val) do
        wire = [#{inspect(tag)}, Codec.encode_element(#{inspect(st)}, val)]
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, val), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_setter(%{
         kind: :scalar,
         number: num,
         name: name,
         scalar_type: st,
         wire_type: wt
       }) do
    tag = OmniBuf.Wire.encode_tag(num, wt)

    zero_check =
      case st do
        :string ->
          "val == \"\""

        :bytes ->
          "val == <<>>"

        :float ->
          "is_number(val) and val == 0.0 and <<val::little-float-32>> == <<0, 0, 0, 0>>"

        :double ->
          "is_number(val) and val == 0.0 and <<val::little-float-64>> == <<0, 0, 0, 0, 0, 0, 0, 0>>"

        _ ->
          "val == 0"
      end

    """
      def set_#{name}(%__MODULE__{} = op, val) do
        wire =
          if #{zero_check} do
            []
          else
            [#{inspect(tag)}, Codec.encode_element(#{inspect(st)}, val)]
          end

        %{op | dirty_values: Map.put(op.dirty_values, #{num}, val), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_setter(%{kind: :message, number: num, name: name, target_mod: target_mod}) do
    tag = OmniBuf.Wire.encode_tag(num, 12)

    """
      def set_#{name}(%__MODULE__{} = op, nil) do
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, nil), dirty_wire: Map.put(op.dirty_wire, #{num}, [])}
      end

      def set_#{name}(%__MODULE__{} = op, %{__struct__: #{target_mod}} = val) do
        wire = [#{inspect(tag)}, OmniBuf.Wire.encode_length_prefixed(#{target_mod}.encode_iodata(val))]
        %{op | dirty_values: Map.put(op.dirty_values, #{num}, val), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_setter(%{kind: :array, number: num, name: name, elem_type_code: elem_code}) do
    tag = OmniBuf.Wire.encode_tag(num, 13)

    """
      def set_#{name}(%__MODULE__{} = op, list) when is_list(list) do
        wire =
          case list do
            [] -> []
            _ -> [#{inspect(tag)}, Codec.encode_array_value(#{elem_code}, list)]
          end

        %{op | dirty_values: Map.put(op.dirty_values, #{num}, list), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_setter(%{
         kind: :map,
         number: num,
         name: name,
         key_type_code: kt_code,
         val_type_code: vt_code
       }) do
    tag = OmniBuf.Wire.encode_tag(num, 14)

    """
      def set_#{name}(%__MODULE__{} = op, map) when is_map(map) do
        wire =
          if map_size(map) == 0 do
            []
          else
            [#{inspect(tag)}, Codec.encode_map_value(#{kt_code}, #{vt_code}, map)]
          end

        %{op | dirty_values: Map.put(op.dirty_values, #{num}, map), dirty_wire: Map.put(op.dirty_wire, #{num}, wire)}
      end
    """
  end

  defp gen_opaque_oneof_setter(%{name: name, branches: branches}) do
    all_nums = Enum.map(branches, & &1.number)

    clear_all_pipe =
      Enum.map_join(all_nums, "\n", fn num -> "        |> Map.put(#{num}, [])" end)

    branch_clauses =
      Enum.map_join(branches, "\n", fn branch ->
        other_nums = Enum.reject(all_nums, &(&1 == branch.number))

        clear_others_pipe =
          Enum.map_join(other_nums, "\n", fn num -> "        |> Map.put(#{num}, [])" end)

        {pattern_and_guard, wire_expr} =
          case branch do
            %{kind: :scalar, scalar_type: :bool, number: num, name: bname} ->
              tag_false = OmniBuf.Wire.encode_tag(num, 2)
              tag_true = OmniBuf.Wire.encode_tag(num, 3)

              {
                "{:#{bname}, val}) when is_boolean(val)",
                "if val, do: #{inspect(tag_true)}, else: #{inspect(tag_false)}"
              }

            %{kind: :scalar, scalar_type: st, wire_type: wt, number: num, name: bname} ->
              tag = OmniBuf.Wire.encode_tag(num, wt)

              {
                "{:#{bname}, val})",
                "[#{inspect(tag)}, Codec.encode_element(#{inspect(st)}, val)]"
              }

            %{kind: :message, target_mod: target_mod, number: num, name: bname} ->
              tag = OmniBuf.Wire.encode_tag(num, 12)

              {
                "{:#{bname}, %{__struct__: #{target_mod}} = val})",
                "[#{inspect(tag)}, OmniBuf.Wire.encode_length_prefixed(#{target_mod}.encode_iodata(val))]"
              }
          end

        """
          def set_#{name}(%__MODULE__{} = op, #{pattern_and_guard} do
            wire = #{wire_expr}

            dirty_wire =
              op.dirty_wire
        #{clear_others_pipe}
              |> Map.put(#{branch.number}, wire)

            %{op | dirty_values: Map.put(op.dirty_values, {:oneof, :#{name}}, {:#{branch.name}, val}), dirty_wire: dirty_wire}
          end
        """
      end)

    """
      def set_#{name}(%__MODULE__{} = op, nil) do
        dirty_wire =
          op.dirty_wire
    #{clear_all_pipe}

        %{op | dirty_values: Map.put(op.dirty_values, {:oneof, :#{name}}, nil), dirty_wire: dirty_wire}
      end

      def set_#{name}(%__MODULE__{} = op, {_branch, nil}), do: set_#{name}(op, nil)

    #{branch_clauses}
    """
  end

  # ---------------------------------------------------------------------------
  # Field Descriptor Analysis
  # ---------------------------------------------------------------------------

  defp analyze_field(%FieldDescriptorProto{} = f, msg_full_name, type_map, map_entries, ctx) do
    editions? = match?({:editions, _}, ctx.mode)
    norm_tn = Editions.normalize_type_name(f.type_name)

    cond do
      f.label == :LABEL_REPEATED and f.type == :TYPE_MESSAGE and
          Map.has_key?(map_entries, norm_tn) ->
        {_entry_msg, kf, vf} = Map.fetch!(map_entries, norm_tn)
        kt_code = single_type_code(kf, type_map, editions?)
        vt_code = single_type_code(vf, type_map, editions?)

        %{
          kind: :map,
          number: f.number,
          name: f.name,
          optional: false,
          key_type_code: kt_code,
          val_type_code: vt_code,
          schema_type_code: "{:map, #{kt_code}, #{vt_code}}"
        }

      f.label == :LABEL_REPEATED ->
        elem_code = single_type_code(f, type_map, editions?)

        %{
          kind: :array,
          number: f.number,
          name: f.name,
          optional: false,
          elem_type_code: elem_code,
          schema_type_code: "{:array, #{elem_code}}"
        }

      f.type == :TYPE_MESSAGE or (editions? and f.type == :TYPE_GROUP) ->
        {:message, target_mod} = Map.fetch!(type_map, norm_tn)

        %{
          kind: :message,
          number: f.number,
          name: f.name,
          optional: true,
          target_mod: target_mod,
          schema_type_code: target_mod
        }

      true ->
        st = scalar_atom(f.type)
        wt = OmniBuf.Codec.wire_type_for(st)
        def_code = inspect(OmniBuf.Codec.default_value(st))
        optional? = explicit_scalar_presence?(f, msg_full_name, ctx)

        %{
          kind: :scalar,
          number: f.number,
          name: f.name,
          optional: optional?,
          scalar_type: st,
          wire_type: wt,
          default_code: def_code,
          schema_type_code: inspect(st)
        }
    end
  end

  defp analyze_oneof_branch(%FieldDescriptorProto{} = f, type_map, ctx) do
    editions? = match?({:editions, _}, ctx.mode)
    norm_tn = Editions.normalize_type_name(f.type_name)

    if f.type == :TYPE_MESSAGE or (editions? and f.type == :TYPE_GROUP) do
      {:message, target_mod} = Map.fetch!(type_map, norm_tn)

      %{
        kind: :message,
        number: f.number,
        name: f.name,
        target_mod: target_mod,
        schema_type_code: target_mod
      }
    else
      st = scalar_atom(f.type)
      wt = OmniBuf.Codec.wire_type_for(st)

      %{
        kind: :scalar,
        number: f.number,
        name: f.name,
        scalar_type: st,
        wire_type: wt,
        schema_type_code: inspect(st)
      }
    end
  end

  defp explicit_scalar_presence?(%FieldDescriptorProto{proto3_optional: true}, _msg_name, _ctx),
    do: true

  defp explicit_scalar_presence?(%FieldDescriptorProto{number: num}, msg_full_name, %{
         mode: {:editions, _},
         field_features: ff_map
       }) do
    case Map.get(ff_map, {msg_full_name, num}) do
      %{field_presence: :EXPLICIT} -> true
      _ -> false
    end
  end

  defp explicit_scalar_presence?(_f, _msg_name, _ctx), do: false

  defp single_type_code(%FieldDescriptorProto{type: t, type_name: tn}, type_map, editions?)
       when t == :TYPE_MESSAGE or (editions? and t == :TYPE_GROUP) do
    {:message, mod} = Map.fetch!(type_map, Editions.normalize_type_name(tn))
    mod
  end

  defp single_type_code(%FieldDescriptorProto{type: t}, _type_map, _editions?) do
    inspect(scalar_atom(t))
  end

  defp scalar_atom(:TYPE_UINT32), do: :uint32
  defp scalar_atom(:TYPE_UINT64), do: :uint64
  defp scalar_atom(:TYPE_INT32), do: :int32
  defp scalar_atom(:TYPE_INT64), do: :int64
  defp scalar_atom(:TYPE_SINT32), do: :sint32
  defp scalar_atom(:TYPE_SINT64), do: :sint64
  defp scalar_atom(:TYPE_ENUM), do: :enum
  defp scalar_atom(:TYPE_BOOL), do: :bool
  defp scalar_atom(:TYPE_FIXED32), do: :fixed32
  defp scalar_atom(:TYPE_FIXED64), do: :fixed64
  defp scalar_atom(:TYPE_SFIXED32), do: :sfixed32
  defp scalar_atom(:TYPE_SFIXED64), do: :sfixed64
  defp scalar_atom(:TYPE_FLOAT), do: :float
  defp scalar_atom(:TYPE_DOUBLE), do: :double
  defp scalar_atom(:TYPE_STRING), do: :string
  defp scalar_atom(:TYPE_BYTES), do: :bytes

  defp scalar_atom(:TYPE_GROUP) do
    raise ArgumentError, "proto2 groups (TYPE_GROUP) are not supported by OmniBuf"
  end

  defp scalar_atom(other) do
    raise ArgumentError, "unsupported Protobuf field type: #{inspect(other)}"
  end

  defp package_to_module("", ""), do: ""
  defp package_to_module("", prefix), do: prefix

  defp package_to_module(pkg, prefix) do
    pkg_mod =
      pkg
      |> String.split(".", trim: true)
      |> Enum.map_join(".", &camelize/1)

    join_mod(prefix, pkg_mod)
  end

  defp join_mod("", right), do: right
  defp join_mod(left, right), do: "#{left}.#{right}"

  defp camelize(str) do
    str
    |> String.split("_", trim: true)
    |> Enum.map_join(fn
      "" -> ""
      <<c::utf8, rest::binary>> -> String.upcase(<<c::utf8>>) <> rest
    end)
  end
end
