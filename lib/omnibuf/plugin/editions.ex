defmodule OmniBuf.Plugin.Editions do
  @moduledoc """
  Protobuf Editions (2023, 2024, 2026) feature resolution and validation for
  `protoc-gen-omnibuf-elixir`.
  """

  alias Google.Protobuf.{
    DescriptorProto,
    EnumDescriptorProto,
    FeatureSet,
    FieldDescriptorProto,
    FileDescriptorProto
  }

  # FEATURE_PROTO3_OPTIONAL (1) | FEATURE_SUPPORTS_EDITIONS (2)
  @supported_features 3
  @minimum_edition 1000
  @maximum_edition 1002

  @default_features %{
    field_presence: :EXPLICIT,
    enum_type: :OPEN,
    repeated_field_encoding: :PACKED,
    utf8_validation: :VERIFY,
    message_encoding: :LENGTH_PREFIXED,
    json_format: :ALLOW
  }

  @allowed_option_extendees MapSet.new([
                              "google.protobuf.FileOptions",
                              "google.protobuf.MessageOptions",
                              "google.protobuf.FieldOptions",
                              "google.protobuf.OneofOptions",
                              "google.protobuf.EnumOptions",
                              "google.protobuf.EnumValueOptions",
                              "google.protobuf.ExtensionRangeOptions",
                              "google.protobuf.ServiceOptions",
                              "google.protobuf.MethodOptions",
                              "google.protobuf.FeatureSet"
                            ])

  @integer_field_types [
    :TYPE_INT32,
    :TYPE_INT64,
    :TYPE_UINT32,
    :TYPE_UINT64,
    :TYPE_SINT32,
    :TYPE_SINT64,
    :TYPE_FIXED32,
    :TYPE_FIXED64,
    :TYPE_SFIXED32,
    :TYPE_SFIXED64
  ]

  @float_field_types [:TYPE_FLOAT, :TYPE_DOUBLE]

  @spec supported_features() :: non_neg_integer()
  def supported_features, do: @supported_features

  @spec minimum_edition() :: integer()
  def minimum_edition, do: @minimum_edition

  @spec maximum_edition() :: integer()
  def maximum_edition, do: @maximum_edition

  @spec default_features(1000 | 1001 | 1002) :: map()
  def default_features(edition) when edition in [1000, 1001, 1002], do: @default_features

  @doc """
  Determines the syntax/edition mode of a `FileDescriptorProto`.
  """
  @spec edition_mode(FileDescriptorProto.t()) ::
          {:ok, :proto2 | :proto3 | {:editions, 1000 | 1001 | 1002}} | {:error, String.t()}
  def edition_mode(%FileDescriptorProto{syntax: "editions", edition: edition, name: name}) do
    case normalize_edition(edition) do
      {:ok, ed} ->
        {:ok, {:editions, ed}}

      :unsupported ->
        {:error,
         "file #{name}: unsupported protobuf edition #{inspect(edition)} (supported: 2023, 2024, 2026)"}
    end
  end

  def edition_mode(%FileDescriptorProto{syntax: syntax, edition: edition, name: name})
      when syntax in [nil, ""] and
             edition not in [
               nil,
               0,
               :EDITION_UNKNOWN,
               998,
               :EDITION_PROTO2,
               999,
               :EDITION_PROTO3
             ] do
    case normalize_edition(edition) do
      {:ok, ed} ->
        {:ok, {:editions, ed}}

      :unsupported ->
        {:error,
         "file #{name}: unsupported protobuf edition #{inspect(edition)} (supported: 2023, 2024, 2026)"}
    end
  end

  def edition_mode(%FileDescriptorProto{syntax: "proto3"}), do: {:ok, :proto3}

  def edition_mode(%FileDescriptorProto{syntax: syntax}) when syntax in [nil, "", "proto2"],
    do: {:ok, :proto2}

  def edition_mode(%FileDescriptorProto{syntax: syntax, name: name}) do
    {:error, "file #{name}: unsupported protobuf syntax #{inspect(syntax)}"}
  end

  defp normalize_edition(:EDITION_2023), do: {:ok, 1000}
  defp normalize_edition(1000), do: {:ok, 1000}
  defp normalize_edition(:EDITION_2024), do: {:ok, 1001}
  defp normalize_edition(1001), do: {:ok, 1001}
  defp normalize_edition(:EDITION_2026), do: {:ok, 1002}
  defp normalize_edition(1002), do: {:ok, 1002}
  defp normalize_edition(_), do: :unsupported

  @doc """
  Builds a global map of enum metadata across all files in `proto_files`:
  `%{".pkg.EnumName" => %{closed?: boolean(), zero_names: MapSet.t()}}`.
  """
  @spec build_enum_info([FileDescriptorProto.t()]) :: map()
  def build_enum_info(proto_files) do
    Enum.reduce(proto_files, %{}, fn %FileDescriptorProto{} = file, acc ->
      pkg_prefix = if file.package in [nil, ""], do: "", else: ".#{file.package}"

      case edition_mode(file) do
        {:ok, :proto2} ->
          collect_file_enums_fixed(file, pkg_prefix, true, acc)

        {:ok, :proto3} ->
          collect_file_enums_fixed(file, pkg_prefix, false, acc)

        {:ok, {:editions, ed}} ->
          base =
            case merge_features(default_features(ed), file.options && file.options.features) do
              {:ok, f} -> f
              {:error, _} -> default_features(ed)
            end

          collect_file_enums_editions(file, pkg_prefix, base, acc)

        {:error, _} ->
          acc
      end
    end)
  end

  defp collect_file_enums_fixed(file, pkg_prefix, closed?, acc) do
    acc =
      Enum.reduce(file.enum_type, acc, fn e, m ->
        Map.put(m, "#{pkg_prefix}.#{e.name}", enum_entry(e, closed?))
      end)

    Enum.reduce(file.message_type, acc, fn msg, m ->
      collect_msg_enums_fixed(msg, pkg_prefix, closed?, m)
    end)
  end

  defp collect_msg_enums_fixed(%DescriptorProto{} = msg, pkg_prefix, closed?, acc) do
    full_name = "#{pkg_prefix}.#{msg.name}"

    acc =
      Enum.reduce(msg.enum_type, acc, fn e, m ->
        Map.put(m, "#{full_name}.#{e.name}", enum_entry(e, closed?))
      end)

    Enum.reduce(msg.nested_type, acc, fn nested, m ->
      collect_msg_enums_fixed(nested, full_name, closed?, m)
    end)
  end

  defp collect_file_enums_editions(file, pkg_prefix, file_features, acc) do
    acc =
      Enum.reduce(file.enum_type, acc, fn e, m ->
        ef = safe_merge_features(file_features, e.options && e.options.features)
        Map.put(m, "#{pkg_prefix}.#{e.name}", enum_entry(e, ef.enum_type == :CLOSED))
      end)

    Enum.reduce(file.message_type, acc, fn msg, m ->
      collect_msg_enums_editions(msg, pkg_prefix, file_features, m)
    end)
  end

  defp collect_msg_enums_editions(%DescriptorProto{} = msg, pkg_prefix, parent_features, acc) do
    full_name = "#{pkg_prefix}.#{msg.name}"
    msg_features = safe_merge_features(parent_features, msg.options && msg.options.features)

    acc =
      Enum.reduce(msg.enum_type, acc, fn e, m ->
        ef = safe_merge_features(msg_features, e.options && e.options.features)
        Map.put(m, "#{full_name}.#{e.name}", enum_entry(e, ef.enum_type == :CLOSED))
      end)

    Enum.reduce(msg.nested_type, acc, fn nested, m ->
      collect_msg_enums_editions(nested, full_name, msg_features, m)
    end)
  end

  defp enum_entry(%EnumDescriptorProto{value: values}, closed?) do
    zero_names =
      values
      |> Enum.filter(&(&1.number == 0))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    %{closed?: closed?, zero_names: zero_names}
  end

  defp safe_merge_features(parent, fs) do
    case merge_features(parent, fs) do
      {:ok, merged} -> merged
      {:error, _} -> parent
    end
  end

  @doc """
  Merges an optional `FeatureSet` override onto a parent feature map.
  """
  @spec merge_features(map(), FeatureSet.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def merge_features(parent, nil), do: {:ok, parent}

  def merge_features(parent, %FeatureSet{} = fs) do
    with {:ok, fp} <- merge_one(parent.field_presence, fs.field_presence, &norm_field_presence/1),
         {:ok, et} <- merge_one(parent.enum_type, fs.enum_type, &norm_enum_type/1),
         {:ok, rfe} <-
           merge_one(
             parent.repeated_field_encoding,
             fs.repeated_field_encoding,
             &norm_repeated_encoding/1
           ),
         {:ok, utf8} <- merge_one(parent.utf8_validation, fs.utf8_validation, &norm_utf8/1),
         {:ok, me} <-
           merge_one(parent.message_encoding, fs.message_encoding, &norm_message_encoding/1),
         {:ok, jf} <- merge_one(parent.json_format, fs.json_format, &norm_json_format/1) do
      {:ok,
       %{
         field_presence: fp,
         enum_type: et,
         repeated_field_encoding: rfe,
         utf8_validation: utf8,
         message_encoding: me,
         json_format: jf
       }}
    end
  end

  defp merge_one(parent_val, override, norm_fn) do
    case norm_fn.(override) do
      :inherit -> {:ok, parent_val}
      {:ok, v} -> {:ok, v}
      {:error, _} = err -> err
    end
  end

  defp norm_field_presence(v) when v in [nil, 0, :FIELD_PRESENCE_UNKNOWN], do: :inherit
  defp norm_field_presence(v) when v in [:EXPLICIT, 1], do: {:ok, :EXPLICIT}
  defp norm_field_presence(v) when v in [:IMPLICIT, 2], do: {:ok, :IMPLICIT}
  defp norm_field_presence(v) when v in [:LEGACY_REQUIRED, 3], do: {:ok, :LEGACY_REQUIRED}
  defp norm_field_presence(v), do: {:error, "unsupported field_presence value: #{inspect(v)}"}

  defp norm_enum_type(v) when v in [nil, 0, :ENUM_TYPE_UNKNOWN], do: :inherit
  defp norm_enum_type(v) when v in [:OPEN, 1], do: {:ok, :OPEN}
  defp norm_enum_type(v) when v in [:CLOSED, 2], do: {:ok, :CLOSED}
  defp norm_enum_type(v), do: {:error, "unsupported enum_type value: #{inspect(v)}"}

  defp norm_repeated_encoding(v) when v in [nil, 0, :REPEATED_FIELD_ENCODING_UNKNOWN],
    do: :inherit

  defp norm_repeated_encoding(v) when v in [:PACKED, 1], do: {:ok, :PACKED}
  defp norm_repeated_encoding(v) when v in [:EXPANDED, 2], do: {:ok, :EXPANDED}

  defp norm_repeated_encoding(v),
    do: {:error, "unsupported repeated_field_encoding value: #{inspect(v)}"}

  defp norm_utf8(v) when v in [nil, 0, :UTF8_VALIDATION_UNKNOWN], do: :inherit
  defp norm_utf8(v) when v in [:VERIFY, 2], do: {:ok, :VERIFY}
  defp norm_utf8(v) when v in [:NONE, 3], do: {:ok, :NONE}
  defp norm_utf8(v), do: {:error, "unsupported utf8_validation value: #{inspect(v)}"}

  defp norm_message_encoding(v) when v in [nil, 0, :MESSAGE_ENCODING_UNKNOWN], do: :inherit
  defp norm_message_encoding(v) when v in [:LENGTH_PREFIXED, 1], do: {:ok, :LENGTH_PREFIXED}
  defp norm_message_encoding(v) when v in [:DELIMITED, 2], do: {:ok, :DELIMITED}
  defp norm_message_encoding(v), do: {:error, "unsupported message_encoding value: #{inspect(v)}"}

  defp norm_json_format(v) when v in [nil, 0, :JSON_FORMAT_UNKNOWN], do: :inherit
  defp norm_json_format(v) when v in [:ALLOW, 1], do: {:ok, :ALLOW}
  defp norm_json_format(v) when v in [:LEGACY_BEST_EFFORT, 2], do: {:ok, :LEGACY_BEST_EFFORT}
  defp norm_json_format(v), do: {:error, "unsupported json_format value: #{inspect(v)}"}

  @doc """
  Validates a target `FileDescriptorProto` and returns its resolved file context:
  `%{mode: :proto2 | :proto3 | {:editions, integer()}, field_features: %{{msg_full_name, field_number} => map()}}`.
  """
  @spec validate_and_resolve_file(FileDescriptorProto.t(), map(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def validate_and_resolve_file(%FileDescriptorProto{} = file, enum_info, map_entries) do
    case edition_mode(file) do
      {:ok, {:editions, ed}} ->
        with {:ok, file_features} <-
               merge_features(default_features(ed), file.options && file.options.features),
             :ok <- validate_extensions(file.name, file.extension),
             pkg_prefix = if(file.package in [nil, ""], do: "", else: ".#{file.package}"),
             :ok <- validate_enums(file.name, pkg_prefix, file.enum_type, file_features),
             {:ok, field_features} <-
               validate_messages(
                 file.name,
                 pkg_prefix,
                 file.message_type,
                 file_features,
                 enum_info,
                 map_entries,
                 %{}
               ) do
          {:ok, %{mode: {:editions, ed}, field_features: field_features}}
        end

      {:ok, mode} ->
        {:ok, %{mode: mode, field_features: %{}}}

      {:error, _} = err ->
        err
    end
  end

  defp validate_extensions(_file_name, []), do: :ok

  defp validate_extensions(file_name, extensions) do
    Enum.reduce_while(extensions, :ok, fn %FieldDescriptorProto{} = ext, :ok ->
      extendee = normalize_no_leading_dot(ext.extendee || "")

      if MapSet.member?(@allowed_option_extendees, extendee) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          "file #{file_name}: non-option extension #{ext.name} extending #{ext.extendee} is not supported by OmniBuf"}}
      end
    end)
  end

  defp validate_enums(_file_name, _prefix, [], _parent_features), do: :ok

  defp validate_enums(file_name, prefix, enums, parent_features) do
    Enum.reduce_while(enums, :ok, fn %EnumDescriptorProto{} = e, :ok ->
      with {:ok, ef} <- merge_features(parent_features, e.options && e.options.features) do
        if ef.enum_type == :CLOSED do
          {:halt,
           {:error,
            "file #{file_name}: closed enum #{prefix}.#{e.name} (enum_type = CLOSED) is not supported by OmniBuf"}}
        else
          {:cont, :ok}
        end
      else
        {:error, msg} -> {:halt, {:error, "file #{file_name}: enum #{prefix}.#{e.name}: #{msg}"}}
      end
    end)
  end

  defp validate_messages(
         _file_name,
         _prefix,
         [],
         _parent_features,
         _enum_info,
         _map_entries,
         acc
       ),
       do: {:ok, acc}

  defp validate_messages(
         file_name,
         prefix,
         messages,
         parent_features,
         enum_info,
         map_entries,
         acc
       ) do
    Enum.reduce_while(messages, {:ok, acc}, fn %DescriptorProto{} = msg, {:ok, field_acc} ->
      if msg.options && msg.options.map_entry do
        {:cont, {:ok, field_acc}}
      else
        case validate_message(
               file_name,
               prefix,
               msg,
               parent_features,
               enum_info,
               map_entries,
               field_acc
             ) do
          {:ok, next_acc} -> {:cont, {:ok, next_acc}}
          {:error, _} = err -> {:halt, err}
        end
      end
    end)
  end

  defp validate_message(
         file_name,
         prefix,
         %DescriptorProto{} = msg,
         parent_features,
         enum_info,
         map_entries,
         field_acc
       ) do
    full_name = "#{prefix}.#{msg.name}"

    with {:ok, msg_features} <-
           merge_features(parent_features, msg.options && msg.options.features),
         :ok <- validate_extension_ranges(file_name, full_name, msg.extension_range),
         :ok <- validate_extensions(file_name, msg.extension),
         :ok <- validate_enums(file_name, full_name, msg.enum_type, msg_features),
         {:ok, oneof_features} <- resolve_oneof_features(file_name, full_name, msg, msg_features),
         {:ok, field_acc} <-
           validate_fields(
             file_name,
             full_name,
             msg.field,
             msg_features,
             oneof_features,
             enum_info,
             map_entries,
             field_acc
           ) do
      validate_messages(
        file_name,
        full_name,
        msg.nested_type,
        msg_features,
        enum_info,
        map_entries,
        field_acc
      )
    end
  end

  defp validate_extension_ranges(_file_name, _full_name, []), do: :ok

  defp validate_extension_ranges(file_name, full_name, _ranges) do
    if MapSet.member?(@allowed_option_extendees, normalize_no_leading_dot(full_name)) do
      :ok
    else
      {:error,
       "file #{file_name}: non-option extension range on #{full_name} is not supported by OmniBuf"}
    end
  end

  defp resolve_oneof_features(file_name, full_name, %DescriptorProto{oneof_decl: decls}, msg_feat) do
    decls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {oneof, idx}, {:ok, acc} ->
      case merge_features(msg_feat, oneof.options && oneof.options.features) do
        {:ok, of} ->
          {:cont, {:ok, Map.put(acc, idx, of)}}

        {:error, msg} ->
          {:halt, {:error, "file #{file_name}: oneof #{full_name}.#{oneof.name}: #{msg}"}}
      end
    end)
  end

  defp validate_fields(
         file_name,
         msg_full_name,
         fields,
         msg_features,
         oneof_features,
         enum_info,
         map_entries,
         field_acc
       ) do
    Enum.reduce_while(fields, {:ok, field_acc}, fn %FieldDescriptorProto{} = f, {:ok, acc} ->
      in_real_oneof? = f.oneof_index != nil and not (f.proto3_optional == true)

      parent_feat =
        if in_real_oneof? do
          Map.fetch!(oneof_features, f.oneof_index)
        else
          msg_features
        end

      case validate_field(
             file_name,
             msg_full_name,
             f,
             parent_feat,
             msg_features,
             enum_info,
             map_entries
           ) do
        {:ok, ff} ->
          {:cont, {:ok, Map.put(acc, {msg_full_name, f.number}, ff)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp validate_field(
         file_name,
         msg_full_name,
         %FieldDescriptorProto{} = f,
         parent_feat,
         msg_features,
         enum_info,
         map_entries
       ) do
    field_label = "#{msg_full_name}.#{f.name}"

    with {:ok, ff} <- merge_features(parent_feat, f.options && f.options.features) do
      is_map? =
        f.label == :LABEL_REPEATED and f.type == :TYPE_MESSAGE and
          Map.has_key?(map_entries, normalize_type_name(f.type_name))

      cond do
        is_map? ->
          {entry_msg, kf, vf} = Map.fetch!(map_entries, normalize_type_name(f.type_name))

          with {:ok, entry_feat} <-
                 merge_features(msg_features, entry_msg.options && entry_msg.options.features),
               {:ok, map_base_feat} <-
                 merge_features(entry_feat, f.options && f.options.features),
               {:ok, kf_feat} <- merge_features(map_base_feat, kf.options && kf.options.features),
               {:ok, vf_feat} <- merge_features(map_base_feat, vf.options && vf.options.features),
               :ok <- validate_utf8(file_name, "#{field_label}.key", kf, kf_feat),
               :ok <- validate_utf8(file_name, "#{field_label}.value", vf, vf_feat),
               :ok <- validate_enum_ref(file_name, "#{field_label}.value", vf, vf_feat, enum_info) do
            {:ok, ff}
          end

        true ->
          with :ok <- validate_presence(file_name, field_label, f, ff),
               :ok <- validate_utf8(file_name, field_label, f, ff),
               :ok <- validate_enum_ref(file_name, field_label, f, ff, enum_info),
               :ok <- validate_default(file_name, field_label, f, enum_info) do
            {:ok, ff}
          end
      end
    else
      {:error, msg} -> {:error, "file #{file_name}: field #{field_label}: #{msg}"}
    end
  end

  defp validate_presence(file_name, field_label, %FieldDescriptorProto{label: label}, ff) do
    cond do
      label == :LABEL_REQUIRED ->
        {:error,
         "file #{file_name}: field #{field_label} uses LEGACY_REQUIRED presence, which is not supported by OmniBuf"}

      label != :LABEL_REPEATED and ff.field_presence == :LEGACY_REQUIRED ->
        {:error,
         "file #{file_name}: field #{field_label} uses field_presence = LEGACY_REQUIRED, which is not supported by OmniBuf"}

      true ->
        :ok
    end
  end

  defp validate_utf8(file_name, field_label, %FieldDescriptorProto{type: :TYPE_STRING}, ff) do
    if ff.utf8_validation == :NONE do
      {:error,
       "file #{file_name}: string field #{field_label} uses utf8_validation = NONE, which is not supported by OmniBuf"}
    else
      :ok
    end
  end

  defp validate_utf8(_file_name, _field_label, _f, _ff), do: :ok

  defp validate_enum_ref(
         file_name,
         field_label,
         %FieldDescriptorProto{type: :TYPE_ENUM, type_name: tn},
         ff,
         enum_info
       ) do
    norm_tn = normalize_type_name(tn)

    case Map.get(enum_info, norm_tn) do
      %{closed?: true} ->
        {:error,
         "file #{file_name}: enum field #{field_label} references closed enum #{tn}, which is not supported by OmniBuf"}

      %{closed?: false} ->
        :ok

      nil ->
        if ff.enum_type == :CLOSED do
          {:error,
           "file #{file_name}: enum field #{field_label} uses enum_type = CLOSED, which is not supported by OmniBuf"}
        else
          :ok
        end
    end
  end

  defp validate_enum_ref(_file_name, _field_label, _f, _ff, _enum_info), do: :ok

  defp validate_default(_file_name, _field_label, %FieldDescriptorProto{default_value: nil}, _ei),
    do: :ok

  defp validate_default(file_name, field_label, %FieldDescriptorProto{} = f, enum_info) do
    if zero_default?(f, enum_info) do
      :ok
    else
      {:error,
       "file #{file_name}: field #{field_label} has custom non-zero default #{inspect(f.default_value)}, which is not supported by OmniBuf"}
    end
  end

  defp zero_default?(%FieldDescriptorProto{type: t, default_value: ""}, _ei)
       when t in [:TYPE_STRING, :TYPE_BYTES],
       do: true

  defp zero_default?(%FieldDescriptorProto{type: :TYPE_BOOL, default_value: "false"}, _ei),
    do: true

  defp zero_default?(%FieldDescriptorProto{type: t, default_value: raw}, _ei)
       when t in @integer_field_types do
    case Integer.parse(String.trim(raw)) do
      {0, ""} -> true
      _ -> false
    end
  end

  defp zero_default?(%FieldDescriptorProto{type: t, default_value: raw}, _ei)
       when t in @float_field_types do
    trimmed =
      raw
      |> String.trim()
      |> String.trim_trailing("f")
      |> String.trim_trailing("F")

    if String.starts_with?(trimmed, "-") do
      false
    else
      case Float.parse(trimmed) do
        {val, ""} -> <<val::little-float-64>> == <<0, 0, 0, 0, 0, 0, 0, 0>>
        _ -> false
      end
    end
  end

  defp zero_default?(
         %FieldDescriptorProto{type: :TYPE_ENUM, type_name: tn, default_value: raw},
         ei
       ) do
    case Map.get(ei, normalize_type_name(tn)) do
      %{zero_names: zero_names} ->
        MapSet.member?(zero_names, raw) or raw == "0"

      nil ->
        raw == "0"
    end
  end

  defp zero_default?(_f, _ei), do: false

  @doc false
  def normalize_type_name(nil), do: nil
  def normalize_type_name("." <> _ = tn), do: tn
  def normalize_type_name(tn) when is_binary(tn), do: "." <> tn

  defp normalize_no_leading_dot("." <> rest), do: rest
  defp normalize_no_leading_dot(other), do: other
end
