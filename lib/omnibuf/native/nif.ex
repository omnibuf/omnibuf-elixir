defmodule OmniBuf.Native.NIF do
  @moduledoc false
  @on_load :load_nif

  @loaded_key {OmniBuf.Native, :loaded}
  @enabled_key {OmniBuf.Native, :enabled}

  def load_nif do
    loaded? = try_load_nif()
    :persistent_term.put(@loaded_key, loaded?)

    enabled? =
      case System.get_env("OMNIBUF_NATIVE") do
        val when val in ["0", "false", "FALSE", "no"] ->
          false

        val when val in ["1", "true", "TRUE", "yes"] ->
          loaded?

        _ ->
          Application.get_env(:omnibuf, :native, true) and loaded?
      end

    :persistent_term.put(@enabled_key, enabled?)
    :ok
  end

  defp try_load_nif do
    candidate_paths()
    |> Enum.any?(fn path ->
      if File.exists?(path <> ".so") or File.exists?(path <> ".dylib") do
        case :erlang.load_nif(String.to_charlist(path), 0) do
          :ok -> true
          {:error, {:reload, _}} -> true
          _ -> false
        end
      else
        false
      end
    end)
  end

  defp candidate_paths do
    env_path =
      case System.get_env("OMNIBUF_NIF_PATH") do
        nil -> []
        "" -> []
        p -> [String.replace_suffix(p, ".so", "")]
      end

    priv_path =
      case :code.priv_dir(:omnibuf) do
        {:error, _} -> []
        dir -> [Path.join([List.to_string(dir), "native", "libomnibuf_nif"])]
      end

    fallback_paths = [
      Path.expand("priv/native/libomnibuf_nif"),
      Path.expand("_build/prod/lib/omnibuf/priv/native/libomnibuf_nif"),
      Path.expand("_build/dev/lib/omnibuf/priv/native/libomnibuf_nif"),
      Path.expand("_build/test/lib/omnibuf/priv/native/libomnibuf_nif")
    ]

    Enum.uniq(env_path ++ priv_path ++ fallback_paths)
  end

  def nif_decode_blind(_bin, _max_depth, _max_elements, _max_message_bytes),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_decode_blind_json(_bin, _max_depth, _max_elements, _max_message_bytes),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_opaque_find_last(_bin, _target_field, _target_wt),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_opaque_find_all(_bin, _target_field, _target_wt),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_opaque_extract_submsg(_bin, _target_field),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_opaque_splice(_packet, _dirty_list),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_compile_schema(_msg_list),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_encode_struct(_schema, _msg),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_decode_struct(_schema, _bin),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_merge_struct(_schema, _existing, _bin),
    do: :erlang.nif_error(:nif_not_loaded)
end
