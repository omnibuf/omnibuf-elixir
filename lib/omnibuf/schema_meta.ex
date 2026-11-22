defmodule OmniBuf.SchemaMeta do
  @moduledoc """
  Field #0 (`Tag = 0x19`, `WireSubMsg = 12`) self-describing schema metadata.

  Encodes optional `type_name`, `fields` (`map<uint32, string>`), and recursive
  `children` (`map<uint32, SchemaMeta>`).
  """

  alias OmniBuf.{Error, Wire}

  defstruct type_name: "", fields: %{}, children: %{}

  @type t :: %__MODULE__{
          type_name: String.t(),
          fields: %{optional(non_neg_integer()) => String.t()},
          children: %{optional(non_neg_integer()) => t()}
        }

  @field_zero_tag <<0x19>>

  @doc """
  Encodes a `SchemaMeta` struct as a complete Field #0 `[0x19][ByteLen][body]` iodata fragment.
  """
  @spec encode_field(t()) :: iodata()
  def encode_field(%__MODULE__{} = meta) do
    body = encode_body(meta)
    [@field_zero_tag, Wire.encode_length_prefixed(body)]
  end

  @doc """
  Encodes the inner field stream of a `SchemaMeta` message (without outer tag or ByteLen).
  """
  @spec encode_body(t()) :: iodata()
  def encode_body(%__MODULE__{type_name: type_name, fields: fields, children: children}) do
    part1 =
      if type_name != "" do
        [Wire.encode_tag(1, Wire.wire_string()), Wire.encode_length_prefixed(type_name)]
      else
        []
      end

    part2 =
      if map_size(fields) > 0 do
        sorted = Enum.sort_by(fields, fn {k, _v} -> k end)

        entries =
          Enum.map(sorted, fn {k, v} ->
            [Wire.encode_varint(k), Wire.encode_length_prefixed(v)]
          end)

        map_body = [<<0x00, 0x0A>>, Wire.encode_varint(length(sorted)), entries]
        [Wire.encode_tag(2, Wire.wire_map()), Wire.encode_length_prefixed(map_body)]
      else
        []
      end

    part3 =
      if map_size(children) > 0 do
        sorted = Enum.sort_by(children, fn {k, _v} -> k end)

        entries =
          Enum.map(sorted, fn {k, child_meta} ->
            [Wire.encode_varint(k), Wire.encode_length_prefixed(encode_body(child_meta))]
          end)

        map_body = [<<0x00, 0x0C>>, Wire.encode_varint(length(sorted)), entries]
        [Wire.encode_tag(3, Wire.wire_map()), Wire.encode_length_prefixed(map_body)]
      else
        []
      end

    [part1, part2, part3]
  end

  @doc """
  Decodes a Field #0 `SchemaMeta` starting right after the `0x19` tag (i.e. at `ByteLen`).
  Enforces container depth (+1 for the Field #0 `WireSubMsg`, +2 per `children` hop).
  """
  @spec decode_field(binary(), non_neg_integer()) ::
          {:ok, t(), binary()} | {:error, Error.t()}
  def decode_field(bin, depth) do
    budget = %{
      max_depth: Wire.max_depth(),
      max_elements: Wire.default_max_elements(),
      elements: 0
    }

    case decode_field(bin, depth, budget) do
      {:ok, meta, rest, _budget} -> {:ok, meta, rest}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec decode_field(binary(), non_neg_integer(), map()) ::
          {:ok, t(), binary(), map()} | {:error, Error.t()}
  def decode_field(bin, depth, %{max_depth: max_depth} = budget) do
    if depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max depth exceeded in Field #0 SchemaMeta")
    else
      with {:ok, body, rest} <- Wire.decode_length_prefixed(bin),
           {:ok, meta, new_budget} <-
             decode_body_with_budget(body, depth + 1, %__MODULE__{}, budget) do
        {:ok, meta, rest, new_budget}
      end
    end
  end

  @doc """
  Decodes the inner field stream of a `SchemaMeta` message.
  """
  @spec decode_body(binary(), non_neg_integer(), t()) :: {:ok, t()} | {:error, Error.t()}
  def decode_body(bin, depth, acc) do
    budget = %{
      max_depth: Wire.max_depth(),
      max_elements: Wire.default_max_elements(),
      elements: 0
    }

    case decode_body_with_budget(bin, depth, acc, budget) do
      {:ok, meta, _budget} -> {:ok, meta}
      {:error, _} = err -> err
    end
  end

  defp decode_body_with_budget(<<>>, _depth, acc, budget), do: {:ok, acc, budget}

  defp decode_body_with_budget(bin, depth, acc, %{max_depth: max_depth} = budget) do
    with {:ok, field_num, wt, rest} <- Wire.decode_tag(bin) do
      case {field_num, wt} do
        {0, 12} ->
          with {:ok, _nested_meta, tail, new_budget} <- decode_field(rest, depth, budget) do
            decode_body_with_budget(tail, depth, acc, new_budget)
          end

        {1, 10} ->
          with {:ok, name, tail} <- Wire.decode_string(rest) do
            acc = if name != "", do: %{acc | type_name: name}, else: acc
            decode_body_with_budget(tail, depth, acc, budget)
          end

        {2, 14} ->
          if depth + 1 > max_depth do
            Error.parse(:max_depth_exceeded, "max depth exceeded in SchemaMeta.fields")
          else
            with {:ok, kt, vt, count, entries_bin, tail} <-
                   Wire.decode_map_header(rest, budget.max_elements),
                 :ok <- check_fields_map_types(kt, vt),
                 {:ok, budget} <- add_meta_elements(budget, count),
                 {:ok, new_fields} <- decode_fields_map(entries_bin, count, acc.fields) do
              decode_body_with_budget(tail, depth, %{acc | fields: new_fields}, budget)
            end
          end

        {3, 14} ->
          if depth + 1 > max_depth do
            Error.parse(:max_depth_exceeded, "max depth exceeded in SchemaMeta.children")
          else
            with {:ok, kt, vt, count, entries_bin, tail} <-
                   Wire.decode_map_header(rest, budget.max_elements),
                 :ok <- check_children_map_types(kt, vt),
                 {:ok, budget} <- add_meta_elements(budget, count),
                 {:ok, new_children, new_budget} <-
                   decode_children_map(entries_bin, count, depth + 1, acc.children, budget) do
              decode_body_with_budget(tail, depth, %{acc | children: new_children}, new_budget)
            end
          end

        {_unknown, _wt} ->
          with {:ok, tail, new_budget} <-
                 Wire.skip_validated_with_budget(wt, rest, depth, budget) do
            decode_body_with_budget(tail, depth, acc, new_budget)
          end
      end
    end
  end

  defp add_meta_elements(%{elements: el, max_elements: max} = budget, count) do
    next = el + count

    if next > max do
      Error.parse(:element_limit_exceeded, "cumulative element count #{next} exceeds #{max}")
    else
      {:ok, %{budget | elements: next}}
    end
  end

  defp check_fields_map_types(0, 10), do: :ok

  defp check_fields_map_types(kt, vt) do
    Error.parse(
      :schema_meta_type_mismatch,
      "SchemaMeta.fields must be map<uint(0), string(10)>, got <#{kt}, #{vt}>"
    )
  end

  defp check_children_map_types(0, 12), do: :ok

  defp check_children_map_types(kt, vt) do
    Error.parse(
      :schema_meta_type_mismatch,
      "SchemaMeta.children must be map<uint(0), submsg(12)>, got <#{kt}, #{vt}>"
    )
  end

  defp decode_fields_map(<<>>, 0, acc), do: {:ok, acc}

  defp decode_fields_map(_bin, 0, _acc) do
    Error.parse(:trailing_bytes, "trailing bytes in SchemaMeta.fields")
  end

  defp decode_fields_map(bin, count, acc) do
    with {:ok, field_num, after_k} <- Wire.decode_varint(bin),
         :ok <- validate_meta_field_key(field_num),
         {:ok, name, after_v} <- Wire.decode_string(after_k) do
      decode_fields_map(after_v, count - 1, Map.put(acc, field_num, name))
    end
  end

  defp decode_children_map(<<>>, 0, _map_depth, acc, budget), do: {:ok, acc, budget}

  defp decode_children_map(_bin, 0, _map_depth, _acc, _budget) do
    Error.parse(:trailing_bytes, "trailing bytes in SchemaMeta.children")
  end

  defp decode_children_map(bin, count, map_depth, acc, %{max_depth: max_depth} = budget) do
    if map_depth + 1 > max_depth do
      Error.parse(:max_depth_exceeded, "max depth exceeded in SchemaMeta.children value")
    else
      with {:ok, field_num, after_k} <- Wire.decode_varint(bin),
           :ok <- validate_meta_field_key(field_num),
           {:ok, child_body, after_v} <- Wire.decode_length_prefixed(after_k),
           {:ok, child_meta, new_budget} <-
             decode_body_with_budget(child_body, map_depth + 1, %__MODULE__{}, budget) do
        decode_children_map(
          after_v,
          count - 1,
          map_depth,
          Map.put(acc, field_num, child_meta),
          new_budget
        )
      end
    end
  end

  defp validate_meta_field_key(0) do
    Error.parse(:invalid_schema_meta_key, "SchemaMeta field key 0 is reserved")
  end

  defp validate_meta_field_key(k) when k > 536_870_911 do
    Error.parse(:invalid_schema_meta_key, "SchemaMeta field key #{k} exceeds max field number")
  end

  defp validate_meta_field_key(_k), do: :ok

  @doc """
  Merges two `SchemaMeta` tables according to Spec Section 8.2:
  - Later non-empty `type_name` wins.
  - Later `fields` entries override per field number (an empty string `""` clears an inherited name).
  - `children` maps merge recursively by field number.
  """
  @spec merge(t() | nil, t() | nil) :: t() | nil
  def merge(nil, b), do: b
  def merge(a, nil), do: a

  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    type_name = if b.type_name != "", do: b.type_name, else: a.type_name
    fields = Map.merge(a.fields, b.fields)

    children =
      Map.merge(a.children, b.children, fn _k, child_a, child_b ->
        merge(child_a, child_b)
      end)

    %__MODULE__{type_name: type_name, fields: fields, children: children}
  end

  @doc """
  Resolves a field name from `meta`, falling back to `"field_<N>"` when absent or empty `""`.
  """
  @spec resolve_field_name(t() | nil, non_neg_integer()) :: String.t()
  def resolve_field_name(nil, field_num), do: "field_#{field_num}"

  def resolve_field_name(%__MODULE__{fields: fields}, field_num) do
    case Map.get(fields, field_num) do
      nil -> "field_#{field_num}"
      "" -> "field_#{field_num}"
      name -> name
    end
  end

  @doc """
  Returns the child `SchemaMeta` for `field_num`, or `nil`.
  """
  @spec child_meta(t() | nil, non_neg_integer()) :: t() | nil
  def child_meta(nil, _field_num), do: nil
  def child_meta(%__MODULE__{children: children}, field_num), do: Map.get(children, field_num)
end
