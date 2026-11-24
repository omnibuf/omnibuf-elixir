defmodule OmniBuf.Opaque do
  @moduledoc """
  Lazy zero-decode `Opaque` packet views and in-place iodata wire splicing.

  Unchanged fields are never decoded and are preserved as zero-copy sub-binaries
  until the final `IO.iodata_to_binary/1` call.
  """

  alias OmniBuf.{Error, Native, Wire}

  @doc """
  Scans `bin` in O(fields) time and returns the raw value binary (starting right after
  the tag) of the **last** occurrence of `target_field` with `target_wt` (or either
  `WireBoolFalse`/`WireBoolTrue` when `target_wt == :bool`).

  Returns `{:ok, {:found, wire_type, rest_after_tag}}`, `{:ok, :not_found}`, or `{:error, err}`.
  """
  @spec find_last(binary(), non_neg_integer(), 0..15 | :bool) ::
          {:ok, {:found, 0..15, binary()} | :not_found} | {:error, Error.t()}
  def find_last(bin, target_field, target_wt) when is_binary(bin) do
    if Native.enabled?() do
      Native.opaque_find_last(bin, target_field, target_wt)
    else
      scan_last(bin, target_field, target_wt, :not_found)
    end
  end

  defp scan_last(<<>>, _target_field, _target_wt, found), do: {:ok, found}

  defp scan_last(bin, target_field, target_wt, found) do
    case Wire.decode_tag(bin) do
      {:ok, field_num, wt, rest} ->
        found =
          if field_num == target_field and wt_matches?(wt, target_wt) do
            {:found, wt, rest}
          else
            found
          end

        case Wire.skip_fast(wt, rest) do
          {:ok, next} -> scan_last(next, target_field, target_wt, found)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Scans `bin` in O(fields) time and returns all matching occurrences (in wire order)
  of `target_field` with `target_wt`, as a list of `{wire_type, rest_after_tag}`.
  """
  @spec find_all(binary(), non_neg_integer(), 0..15 | :bool) ::
          {:ok, [{0..15, binary()}]} | {:error, Error.t()}
  def find_all(bin, target_field, target_wt) when is_binary(bin) do
    if Native.enabled?() do
      Native.opaque_find_all(bin, target_field, target_wt)
    else
      scan_all(bin, target_field, target_wt, [])
    end
  end

  defp scan_all(<<>>, _target_field, _target_wt, acc), do: {:ok, Enum.reverse(acc)}

  defp scan_all(bin, target_field, target_wt, acc) do
    case Wire.decode_tag(bin) do
      {:ok, field_num, wt, rest} ->
        acc =
          if field_num == target_field and wt_matches?(wt, target_wt) do
            [{wt, rest} | acc]
          else
            acc
          end

        case Wire.skip_fast(wt, rest) do
          {:ok, next} -> scan_all(next, target_field, target_wt, acc)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp wt_matches?(wt, :bool), do: wt == 2 or wt == 3
  defp wt_matches?(wt, target_wt), do: wt == target_wt

  @doc """
  Splices `dirty` field replacements into `packet` without decoding untouched fields.

  `dirty` is a map `%{field_number => encoded_field_iodata}` where `encoded_field_iodata`
  is the full `[Tag, Value]` iodata for that field (or `[]` to omit/clear the field).

  Preserves untouched byte runs as zero-copy sub-binaries, drops duplicate occurrences
  of spliced fields, validates framing of skipped fields, and appends any dirty fields
  not originally present in `packet` in ascending field-number order.
  """
  @spec splice(binary(), %{optional(non_neg_integer()) => iodata()}) ::
          {:ok, binary()} | {:error, Error.t()}
  def splice(packet, dirty) when is_binary(packet) and is_map(dirty) do
    cond do
      Native.enabled?() ->
        Native.opaque_splice(packet, dirty)

      map_size(dirty) == 0 ->
        case validate_framing(packet) do
          :ok -> {:ok, packet}
          {:error, _} = err -> err
        end

      true ->
        total = byte_size(packet)

        case splice_loop(packet, packet, 0, total, dirty, MapSet.new(), []) do
          {:ok, chunks, emitted} ->
            trailing_dirty =
              dirty
              |> Enum.reject(fn {fnum, _} -> MapSet.member?(emitted, fnum) end)
              |> Enum.sort_by(fn {fnum, _} -> fnum end)
              |> Enum.map(fn {_fnum, iodata} -> iodata end)

            {:ok, IO.iodata_to_binary([Enum.reverse(chunks), trailing_dirty])}

          {:error, _} = err ->
            err
        end
    end
  end

  defp validate_framing(<<>>), do: :ok

  defp validate_framing(bin) do
    with {:ok, _field_num, wt, rest} <- Wire.decode_tag(bin),
         {:ok, next} <- Wire.skip_fast(wt, rest) do
      validate_framing(next)
    end
  end

  defp splice_loop(packet, <<>>, chunk_start, total, _dirty, emitted, chunks) do
    chunks =
      if chunk_start < total do
        [:binary.part(packet, chunk_start, total - chunk_start) | chunks]
      else
        chunks
      end

    {:ok, chunks, emitted}
  end

  defp splice_loop(packet, cur, chunk_start, total, dirty, emitted, chunks) do
    field_start = total - byte_size(cur)

    case Wire.decode_tag(cur) do
      {:ok, field_num, wt, rest} ->
        case Wire.skip_fast(wt, rest) do
          {:ok, next} ->
            if Map.has_key?(dirty, field_num) do
              chunks =
                if field_start > chunk_start do
                  [:binary.part(packet, chunk_start, field_start - chunk_start) | chunks]
                else
                  chunks
                end

              {chunks, emitted} =
                if MapSet.member?(emitted, field_num) do
                  {chunks, emitted}
                else
                  replacement = Map.fetch!(dirty, field_num)
                  chunks = if replacement == [], do: chunks, else: [replacement | chunks]
                  {chunks, MapSet.put(emitted, field_num)}
                end

              next_pos = total - byte_size(next)
              splice_loop(packet, next, next_pos, total, dirty, emitted, chunks)
            else
              splice_loop(packet, next, chunk_start, total, dirty, emitted, chunks)
            end

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Convenience helper that extracts a single `WireSubMsg` field's raw payload bytes,
  concatenating multiple occurrences if present so repeated submessages merge cleanly.
  """
  @spec extract_submsg(binary(), non_neg_integer()) ::
          {:ok, binary() | nil} | {:error, Error.t()}
  def extract_submsg(bin, field_num) do
    if Native.enabled?() do
      Native.opaque_extract_submsg(bin, field_num)
    else
      case find_all(bin, field_num, 12) do
        {:ok, []} ->
          {:ok, nil}

        {:ok, [{12, rest}]} ->
          case Wire.decode_length_prefixed(rest) do
            {:ok, body, _} -> {:ok, body}
            err -> err
          end

        {:ok, many} ->
          Enum.reduce_while(many, {:ok, []}, fn {12, rest}, {:ok, acc} ->
            case Wire.decode_length_prefixed(rest) do
              {:ok, body, _} -> {:cont, {:ok, [acc, body]}}
              err -> {:halt, err}
            end
          end)
          |> case do
            {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
            err -> err
          end

        err ->
          err
      end
    end
  end
end
