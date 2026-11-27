defmodule OmniBuf.Native do
  @moduledoc """
  Optional Rust NIF accelerator backed by `omnibuf_core` (`omnibuf-rs`).

  When the native shared library (`priv/native/libomnibuf_nif.so`) is built and
  enabled, hot paths in `OmniBuf.Schema`, `OmniBuf.Opaque`, and `OmniBuf.Blind`
  dispatch to Rust. When unavailable or disabled via `OMNIBUF_NATIVE=0` or
  `set_enabled(false)`, OmniBuf transparently falls back to the pure Elixir
  implementation.
  """

  alias OmniBuf.{Codec, Error}
  alias OmniBuf.Native.NIF

  @loaded_key {__MODULE__, :loaded}
  @enabled_key {__MODULE__, :enabled}
  @schema_key_prefix {__MODULE__, :schema}
  @dirty_threshold 32_768

  @doc """
  Returns `true` if the Rust NIF shared library was successfully loaded.
  """
  @spec loaded?() :: boolean()
  def loaded? do
    ensure_initialized()
    :persistent_term.get(@loaded_key, false)
  end

  @doc """
  Returns `true` if the Rust NIF accelerator is currently active.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case :persistent_term.get(@enabled_key, :uninitialized) do
      :uninitialized ->
        ensure_initialized()
        :persistent_term.get(@enabled_key, false)

      val ->
        val
    end
  end

  @doc """
  Enables or disables the Rust NIF accelerator at runtime.
  Returns `:ok` if the requested state was applied, or `{:error, :not_loaded}`
  when attempting to enable an unavailable NIF.
  """
  @spec set_enabled(boolean()) :: :ok | {:error, :not_loaded}
  def set_enabled(false) do
    ensure_initialized()
    :persistent_term.put(@enabled_key, false)
    :ok
  end

  def set_enabled(true) do
    if loaded?() do
      :persistent_term.put(@enabled_key, true)
      :ok
    else
      {:error, :not_loaded}
    end
  end

  @doc """
  Returns `:native` when the Rust NIF is active, or `:elixir` otherwise.
  """
  @spec mode() :: :native | :elixir
  def mode do
    if enabled?(), do: :native, else: :elixir
  end

  defp ensure_initialized do
    # Touching the NIF module triggers `@on_load :load_nif` once.
    _ = Code.ensure_loaded?(NIF)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fast Struct Encode / Decode / Merge
  # ---------------------------------------------------------------------------

  @doc false
  @spec encode_struct(module(), struct()) :: binary()
  def encode_struct(mod, msg) do
    case compiled_schema(mod) do
      :elixir_only ->
        IO.iodata_to_binary(mod.encode_iodata_elixir(msg))

      {schema, _has_custom_defaults?} ->
        case NIF.nif_encode_struct(schema, msg) do
          :dirty -> NIF.nif_encode_struct_dirty(schema, msg)
          bin -> bin
        end
    end
  end

  @doc false
  @spec decode_struct(module(), binary()) :: {:ok, struct()} | {:error, Error.t()}
  def decode_struct(mod, bin) do
    case compiled_schema(mod) do
      :elixir_only ->
        mod.decode_into(bin, struct(mod), 0)

      {_schema, true} ->
        mod.decode_into(bin, struct(mod), 0)

      {schema, false} ->
        if byte_size(bin) >= @dirty_threshold do
          wrap_result(NIF.nif_decode_struct_dirty(schema, bin))
        else
          wrap_result(NIF.nif_decode_struct(schema, bin))
        end
    end
  end

  @doc false
  @spec merge_struct(module(), struct(), binary()) :: {:ok, struct()} | {:error, Error.t()}
  def merge_struct(mod, existing, bin) do
    case compiled_schema(mod) do
      :elixir_only ->
        mod.decode_into(bin, existing, 0)

      {_schema, true} ->
        mod.decode_into(bin, existing, 0)

      {schema, false} ->
        if byte_size(bin) >= @dirty_threshold do
          wrap_result(NIF.nif_merge_struct_dirty(schema, existing, bin))
        else
          wrap_result(NIF.nif_merge_struct(schema, existing, bin))
        end
    end
  end

  defp compiled_schema(mod) do
    key = {@schema_key_prefix, mod}

    case :persistent_term.get(key, nil) do
      nil ->
        entry =
          case collect_schema_graph(mod) do
            :elixir_only ->
              :elixir_only

            {graph, has_custom_defaults?} ->
              ref = NIF.nif_compile_schema(graph)
              {ref, has_custom_defaults?}
          end

        :persistent_term.put(key, entry)
        entry

      entry ->
        entry
    end
  end

  defp collect_schema_graph(root_mod) do
    {ordered_mods, index_map} = discover_modules([root_mod], %{root_mod => 0}, [root_mod])

    elixir_only? =
      Enum.any?(ordered_mods, fn mod ->
        mod_oneofs(mod) != [] or
          Enum.any?(mod.__omnibuf_fields__(), fn f -> Map.get(f, :optional, false) end)
      end)

    if elixir_only? do
      :elixir_only
    else
      has_custom_defaults? =
        Enum.any?(ordered_mods, fn mod ->
          Enum.any?(mod.__omnibuf_fields__(), fn f ->
            f.default !== Codec.default_value(f.type)
          end)
        end)

      graph =
        Enum.map(ordered_mods, fn mod ->
          fields =
            Enum.map(mod.__omnibuf_fields__(), fn f ->
              {f.number, f.name, encode_kind(f.type, index_map), f.emit_empty}
            end)

          {mod, fields}
        end)

      {graph, has_custom_defaults?}
    end
  end

  defp mod_oneofs(mod) do
    if function_exported?(mod, :__omnibuf_oneofs__, 0) do
      mod.__omnibuf_oneofs__()
    else
      []
    end
  end

  defp discover_modules([], index_map, acc), do: {Enum.reverse(acc), index_map}

  defp discover_modules([mod | rest], index_map, acc) do
    field_child_mods =
      mod.__omnibuf_fields__()
      |> Enum.flat_map(fn f -> extract_nested_mods(f.type) end)

    oneof_child_mods =
      mod_oneofs(mod)
      |> Enum.flat_map(fn o -> Enum.flat_map(o.branches, &extract_nested_mods(&1.type)) end)

    child_mods = field_child_mods ++ oneof_child_mods

    {new_queue, new_map, new_acc} =
      Enum.reduce(child_mods, {rest, index_map, acc}, fn child, {q, m, a} ->
        if Map.has_key?(m, child) do
          {q, m, a}
        else
          idx = map_size(m)
          {q ++ [child], Map.put(m, child, idx), [child | a]}
        end
      end)

    discover_modules(new_queue, new_map, new_acc)
  end

  defp extract_nested_mods({:message, mod}), do: [mod]
  defp extract_nested_mods({:array, inner}), do: extract_nested_mods(inner)
  defp extract_nested_mods({:map, k, v}), do: extract_nested_mods(k) ++ extract_nested_mods(v)
  defp extract_nested_mods(_), do: []

  defp encode_kind({:message, mod}, index_map), do: {:message, Map.fetch!(index_map, mod)}
  defp encode_kind({:array, inner}, index_map), do: {:array, encode_kind(inner, index_map)}

  defp encode_kind({:map, k, v}, index_map),
    do: {:map, encode_kind(k, index_map), encode_kind(v, index_map)}

  defp encode_kind({:enum, _}, _index_map), do: :enum
  defp encode_kind(other, _index_map), do: other

  # ---------------------------------------------------------------------------
  # Blind Decoding
  # ---------------------------------------------------------------------------

  @doc false
  @spec decode_blind(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def decode_blind(bin, max_depth, max_elements, max_message_bytes) do
    if byte_size(bin) >= @dirty_threshold do
      wrap_result(NIF.nif_decode_blind_dirty(bin, max_depth, max_elements, max_message_bytes))
    else
      wrap_result(NIF.nif_decode_blind(bin, max_depth, max_elements, max_message_bytes))
    end
  end

  @doc false
  @spec decode_blind_json(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def decode_blind_json(bin, max_depth, max_elements, max_message_bytes) do
    if byte_size(bin) >= @dirty_threshold do
      wrap_result(
        NIF.nif_decode_blind_json_dirty(bin, max_depth, max_elements, max_message_bytes)
      )
    else
      wrap_result(NIF.nif_decode_blind_json(bin, max_depth, max_elements, max_message_bytes))
    end
  end

  # ---------------------------------------------------------------------------
  # Lazy Opaque Lookup & Splicing
  # ---------------------------------------------------------------------------

  @doc false
  @spec opaque_find_last(binary(), non_neg_integer(), 0..15 | :bool) ::
          {:ok, {:found, 0..15, binary()} | :not_found} | {:error, Error.t()}
  def opaque_find_last(bin, target_field, target_wt) do
    wt_code = if target_wt == :bool, do: 16, else: target_wt
    wrap_result(NIF.nif_opaque_find_last(bin, target_field, wt_code))
  end

  @doc false
  @spec opaque_find_all(binary(), non_neg_integer(), 0..15 | :bool) ::
          {:ok, [{0..15, binary()}]} | {:error, Error.t()}
  def opaque_find_all(bin, target_field, target_wt) do
    wt_code = if target_wt == :bool, do: 16, else: target_wt
    wrap_result(NIF.nif_opaque_find_all(bin, target_field, wt_code))
  end

  @doc false
  @spec opaque_extract_submsg(binary(), non_neg_integer()) ::
          {:ok, binary() | nil} | {:error, Error.t()}
  def opaque_extract_submsg(bin, field_num) do
    wrap_result(NIF.nif_opaque_extract_submsg(bin, field_num))
  end

  @doc false
  @spec opaque_splice(binary(), map()) :: {:ok, binary()} | {:error, Error.t()}
  def opaque_splice(packet, dirty) do
    dirty_list = Map.to_list(dirty)

    if byte_size(packet) >= @dirty_threshold do
      wrap_result(NIF.nif_opaque_splice_dirty(packet, dirty_list))
    else
      wrap_result(NIF.nif_opaque_splice(packet, dirty_list))
    end
  end

  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result({:error, {reason, msg}}), do: {:error, Error.new(reason, msg)}
end
