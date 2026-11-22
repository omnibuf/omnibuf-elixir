defmodule OmniBuf.Conformance.CLI do
  @moduledoc """
  Cross-language OmniBuf conformance adapter (`conformance-elixir`).

  Communicates with `conformance-runner` over stdin/stdout using 4-byte little-endian
  length-delimited OmniBuf frames (`ConformanceRequest` / `ConformanceResponse`).
  """

  alias OmniBuf.{Blind, Error, Protobuf}
  alias OmniBuf.Conformance.IPC.{Request, Response}
  alias OmniBuf.Conformance.PB
  alias OmniBuf.Conformance.Struct, as: S
  alias Omnibuf.Bench.{Location, PeerUpdate}
  alias Omnibuf.Conformance.{AllTypesSubMsg, TestAllTypes}

  @max_frame_bytes 16 * 1024 * 1024
  @wire_format_json 2

  @tier_plugin 1
  @tier_protobuf_types 2
  @tier_annotated_struct 3
  @tier_blind 4

  @uint64_max 18_446_744_073_709_551_615
  @int64_min -9_223_372_036_854_775_808

  @spec main([String.t()]) :: no_return()
  def main(_args) do
    :io.setopts(:standard_io, encoding: :latin1)
    loop()
  end

  defp loop do
    case read_frame() do
      :eof ->
        :ok

      {:ok, req} ->
        resp = safe_handle(req)
        write_frame(resp)
        loop()

      {:error, reason} ->
        IO.write(:stderr, "conformance-elixir read error: #{inspect(reason)}\n")
        System.halt(1)
    end
  end

  defp read_frame do
    case IO.binread(:stdio, 4) do
      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}

      <<size::little-unsigned-32>> when size > @max_frame_bytes ->
        {:error, {:frame_too_large, size}}

      <<0::little-unsigned-32>> ->
        Request.decode(<<>>)

      <<size::little-unsigned-32>> ->
        case IO.binread(:stdio, size) do
          bin when is_binary(bin) and byte_size(bin) == size ->
            Request.decode(bin)

          other ->
            {:error, {:truncated_frame, other}}
        end

      short ->
        {:error, {:truncated_length, short}}
    end
  end

  defp write_frame(%Response{} = resp) do
    payload = Response.encode(resp)
    size = byte_size(payload)
    IO.binwrite(:stdio, [<<size::little-unsigned-32>>, payload])
  end

  defp safe_handle(%Request{} = req) do
    handle_request(req)
  rescue
    e ->
      %Response{runtime_error: "exception: #{Exception.message(e)}"}
  catch
    kind, val ->
      %Response{runtime_error: "#{kind}: #{inspect(val)}"}
  end

  defp handle_request(%Request{tier: @tier_blind} = req), do: handle_blind(req)
  defp handle_request(%Request{tier: @tier_plugin} = req), do: handle_plugin(req)
  defp handle_request(%Request{tier: @tier_protobuf_types} = req), do: handle_protobuf(req)
  defp handle_request(%Request{tier: @tier_annotated_struct} = req), do: handle_struct(req)

  defp handle_request(%Request{tier: other}),
    do: %Response{runtime_error: "unsupported tier: #{other}"}

  # ---------------------------------------------------------------------------
  # Tier 4: Blind Inspection
  # ---------------------------------------------------------------------------

  defp handle_blind(%Request{
         requested_output_format: @wire_format_json,
         omnibuf_payload: payload
       }) do
    case Blind.decode_json(payload) do
      {:ok, json} ->
        %Response{json_payload: json}

      {:error, %Error{reason: :serialize}} ->
        %Response{json_payload: "{}"}

      {:error, %Error{message: msg}} ->
        %Response{parse_error: msg}
    end
  end

  defp handle_blind(%Request{omnibuf_payload: payload}) do
    case Blind.decode(payload) do
      {:ok, _map} -> %Response{}
      {:error, %Error{message: msg}} -> %Response{parse_error: msg}
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 1: Plugin-Generated Code + Opaque Views & Splicing
  # ---------------------------------------------------------------------------

  defp handle_plugin(%Request{message_type: "omnibuf.bench.PeerUpdate"} = req) do
    payload = req.omnibuf_payload

    if req.test_opaque_splice or req.test_opaque_splice_shrink do
      probe = PeerUpdate.Opaque.new(payload)
      probe = PeerUpdate.Opaque.set_sequence(probe, PeerUpdate.Opaque.get_sequence(probe) + 1)

      case PeerUpdate.Opaque.marshal(probe) do
        {:ok, _} -> do_plugin_peer_update(req)
        {:error, %Error{message: msg}} -> %Response{parse_error: msg}
      end
    else
      do_plugin_peer_update(req)
    end
  end

  defp handle_plugin(%Request{message_type: "omnibuf.conformance.TestAllTypes"} = req) do
    payload = req.omnibuf_payload

    if req.test_opaque_splice or req.test_opaque_splice_shrink do
      probe = TestAllTypes.Opaque.new(payload)
      probe = TestAllTypes.Opaque.set_f1_uint32(probe, 1)

      case TestAllTypes.Opaque.marshal(probe) do
        {:ok, _} -> do_plugin_test_all_types(req)
        {:error, %Error{message: msg}} -> %Response{parse_error: msg}
      end
    else
      do_plugin_test_all_types(req)
    end
  end

  defp handle_plugin(%Request{}) do
    %Response{skipped: "plugin tier generated for PeerUpdate and TestAllTypes"}
  end

  defp do_plugin_peer_update(%Request{omnibuf_payload: payload} = req) do
    case PeerUpdate.decode(payload) do
      {:error, %Error{message: msg}} ->
        %Response{parse_error: msg}

      {:ok, msg} ->
        op = PeerUpdate.Opaque.new(payload)

        with :ok <- verify_peer_update_opaque(msg, op) do
          cond do
            req.test_opaque_splice ->
              op =
                op
                |> PeerUpdate.Opaque.set_asn(1_000_000)
                |> PeerUpdate.Opaque.set_router_id(String.duplicate("edge-rtr-fra01-", 20))
                |> PeerUpdate.Opaque.set_active(not PeerUpdate.Opaque.get_active(op))
                |> PeerUpdate.Opaque.set_uptime_sec(@uint64_max)
                |> PeerUpdate.Opaque.set_rssi_dbm(-1_000_000)
                |> PeerUpdate.Opaque.set_cpu_load(99.875)
                |> PeerUpdate.Opaque.set_tags([
                  "tag-grow-a",
                  "tag-grow-b",
                  String.duplicate("long-tag-", 20)
                ])
                |> PeerUpdate.Opaque.set_prefixes([
                  100_000,
                  200_000,
                  300_000,
                  400_000,
                  500_000,
                  600_000
                ])
                |> PeerUpdate.Opaque.set_location(%Location{
                  region: "eu-central-grown",
                  datacenter: String.duplicate("fra-dc-", 25),
                  city: "Berlin",
                  rack: 999_999,
                  latitude: 52.52,
                  longitude: 13.405
                })
                |> PeerUpdate.Opaque.set_sequence(PeerUpdate.Opaque.get_sequence(op) + 1)

              case PeerUpdate.Opaque.marshal(op) do
                {:ok, out} -> %Response{omnibuf_payload: out}
                {:error, %Error{message: m}} -> %Response{serialize_error: m}
              end

            req.test_opaque_splice_shrink ->
              op =
                op
                |> PeerUpdate.Opaque.set_asn(1)
                |> PeerUpdate.Opaque.set_router_id("r")
                |> PeerUpdate.Opaque.set_active(false)
                |> PeerUpdate.Opaque.set_uptime_sec(5)
                |> PeerUpdate.Opaque.set_rssi_dbm(-1)
                |> PeerUpdate.Opaque.set_cpu_load(0.5)
                |> PeerUpdate.Opaque.set_tags(["t"])
                |> PeerUpdate.Opaque.set_prefixes([1])
                |> PeerUpdate.Opaque.set_location(%Location{
                  region: "r",
                  datacenter: "d",
                  city: "c",
                  rack: 1,
                  latitude: 1.0,
                  longitude: 2.0
                })
                |> PeerUpdate.Opaque.set_sequence(2)

              case PeerUpdate.Opaque.marshal(op) do
                {:ok, out} -> %Response{omnibuf_payload: out}
                {:error, %Error{message: m}} -> %Response{serialize_error: m}
              end

            true ->
              %Response{
                omnibuf_payload: PeerUpdate.encode(msg, self_describing: req.self_describing)
              }
          end
        else
          {:error, reason} -> %Response{runtime_error: reason}
        end
    end
  end

  defp do_plugin_test_all_types(%Request{omnibuf_payload: payload} = req) do
    case TestAllTypes.decode(payload) do
      {:error, %Error{message: msg}} ->
        %Response{parse_error: msg}

      {:ok, msg} ->
        op = TestAllTypes.Opaque.new(payload)

        with :ok <- verify_test_all_types_opaque(msg, op) do
          cond do
            req.test_opaque_splice ->
              op =
                op
                |> TestAllTypes.Opaque.set_f1_uint32(1_000_000)
                |> TestAllTypes.Opaque.set_f2_uint64(@uint64_max)
                |> TestAllTypes.Opaque.set_f3_sint32(-1_000_000)
                |> TestAllTypes.Opaque.set_f4_sint64(@int64_min)
                |> TestAllTypes.Opaque.set_f5_bool(not TestAllTypes.Opaque.get_f5_bool(op))
                |> TestAllTypes.Opaque.set_f6_string(String.duplicate("grown-str-", 30))
                |> TestAllTypes.Opaque.set_f7_bytes(:binary.copy(<<0xAB, 0xCD>>, 130))
                |> TestAllTypes.Opaque.set_f8_sub_msg(%AllTypesSubMsg{
                  id: 888_888,
                  label: String.duplicate("sub-grown-", 20),
                  flag: true,
                  score: -999_999_999
                })
                |> TestAllTypes.Opaque.set_f9_string_arr([
                  "arr-grow-1",
                  "arr-grow-2",
                  String.duplicate("arr-grow-3-", 15)
                ])
                |> TestAllTypes.Opaque.set_f10_uint32_arr([
                  100_000,
                  200_000,
                  300_000,
                  400_000,
                  500_000
                ])
                |> TestAllTypes.Opaque.set_f11_sub_msg_arr([
                  %AllTypesSubMsg{
                    id: 100_001,
                    label: String.duplicate("elem0-", 25),
                    flag: true,
                    score: -500_000
                  },
                  %AllTypesSubMsg{
                    id: 100_002,
                    label: "elem1-grown",
                    flag: false,
                    score: 500_000
                  }
                ])
                |> TestAllTypes.Opaque.set_f12_map_str_uint(%{
                  "k1" => 1_000_000,
                  "k2" => @uint64_max,
                  "k3_long_key" => 424_242
                })
                |> TestAllTypes.Opaque.set_f13_float32(-1234.5)
                |> TestAllTypes.Opaque.set_f14_float64(3.141592653589793)
                |> TestAllTypes.Opaque.set_f15_fixed32(0xDEADBEEF)
                |> TestAllTypes.Opaque.set_f16_fixed64(0xCAFEBABEDEADBEEF)
                |> TestAllTypes.Opaque.set_f20_overflow_str(String.duplicate("overflow20-", 20))

              case TestAllTypes.Opaque.marshal(op) do
                {:ok, out} -> %Response{omnibuf_payload: out}
                {:error, %Error{message: m}} -> %Response{serialize_error: m}
              end

            req.test_opaque_splice_shrink ->
              op =
                op
                |> TestAllTypes.Opaque.set_f1_uint32(1)
                |> TestAllTypes.Opaque.set_f2_uint64(2)
                |> TestAllTypes.Opaque.set_f3_sint32(-1)
                |> TestAllTypes.Opaque.set_f4_sint64(-2)
                |> TestAllTypes.Opaque.set_f5_bool(false)
                |> TestAllTypes.Opaque.set_f6_string("s")
                |> TestAllTypes.Opaque.set_f7_bytes(<<0x01>>)
                |> TestAllTypes.Opaque.set_f8_sub_msg(%AllTypesSubMsg{
                  id: 1,
                  label: "x",
                  flag: false,
                  score: -1
                })
                |> TestAllTypes.Opaque.set_f9_string_arr(["a"])
                |> TestAllTypes.Opaque.set_f10_uint32_arr([7])
                |> TestAllTypes.Opaque.set_f11_sub_msg_arr([
                  %AllTypesSubMsg{id: 1, label: "e", flag: true, score: 1}
                ])
                |> TestAllTypes.Opaque.set_f12_map_str_uint(%{"k" => 1})
                |> TestAllTypes.Opaque.set_f13_float32(0.5)
                |> TestAllTypes.Opaque.set_f14_float64(-0.25)
                |> TestAllTypes.Opaque.set_f15_fixed32(7)
                |> TestAllTypes.Opaque.set_f16_fixed64(9)
                |> TestAllTypes.Opaque.set_f20_overflow_str("z")

              case TestAllTypes.Opaque.marshal(op) do
                {:ok, out} -> %Response{omnibuf_payload: out}
                {:error, %Error{message: m}} -> %Response{serialize_error: m}
              end

            true ->
              %Response{
                omnibuf_payload: TestAllTypes.encode(msg, self_describing: req.self_describing)
              }
          end
        else
          {:error, reason} -> %Response{runtime_error: reason}
        end
    end
  end

  defp verify_peer_update_opaque(msg, op) do
    checks = [
      {"asn", PeerUpdate.Opaque.get_asn(op) == msg.asn},
      {"router_id", PeerUpdate.Opaque.get_router_id(op) == msg.router_id},
      {"active", PeerUpdate.Opaque.get_active(op) == msg.active},
      {"uptime_sec", PeerUpdate.Opaque.get_uptime_sec(op) == msg.uptime_sec},
      {"rssi_dbm", PeerUpdate.Opaque.get_rssi_dbm(op) == msg.rssi_dbm},
      {"cpu_load", float_eq?(PeerUpdate.Opaque.get_cpu_load(op), msg.cpu_load)},
      {"tags", PeerUpdate.Opaque.get_tags(op) == msg.tags},
      {"prefixes", PeerUpdate.Opaque.get_prefixes(op) == msg.prefixes},
      {"location", PeerUpdate.Opaque.decode_location(op) == msg.location},
      {"neighbors", PeerUpdate.Opaque.get_neighbors(op) == msg.neighbors},
      {"sequence", PeerUpdate.Opaque.get_sequence(op) == msg.sequence}
    ]

    case Enum.find(checks, fn {_name, ok} -> not ok end) do
      nil -> :ok
      {field, false} -> {:error, "OpaquePeerUpdate getter mismatch on #{field}"}
    end
  end

  defp verify_test_all_types_opaque(msg, op) do
    checks = [
      {"f1_uint32", TestAllTypes.Opaque.get_f1_uint32(op) == msg.f1_uint32},
      {"f2_uint64", TestAllTypes.Opaque.get_f2_uint64(op) == msg.f2_uint64},
      {"f3_sint32", TestAllTypes.Opaque.get_f3_sint32(op) == msg.f3_sint32},
      {"f4_sint64", TestAllTypes.Opaque.get_f4_sint64(op) == msg.f4_sint64},
      {"f5_bool", TestAllTypes.Opaque.get_f5_bool(op) == msg.f5_bool},
      {"f6_string", TestAllTypes.Opaque.get_f6_string(op) == msg.f6_string},
      {"f7_bytes", TestAllTypes.Opaque.get_f7_bytes(op) == msg.f7_bytes},
      {"f8_sub_msg", TestAllTypes.Opaque.decode_f8_sub_msg(op) == msg.f8_sub_msg},
      {"f9_string_arr", TestAllTypes.Opaque.get_f9_string_arr(op) == msg.f9_string_arr},
      {"f10_uint32_arr", TestAllTypes.Opaque.get_f10_uint32_arr(op) == msg.f10_uint32_arr},
      {"f11_sub_msg_arr", TestAllTypes.Opaque.get_f11_sub_msg_arr(op) == msg.f11_sub_msg_arr},
      {"f12_map_str_uint", TestAllTypes.Opaque.get_f12_map_str_uint(op) == msg.f12_map_str_uint},
      {"f13_float32", float_eq?(TestAllTypes.Opaque.get_f13_float32(op), msg.f13_float32)},
      {"f14_float64", float_eq?(TestAllTypes.Opaque.get_f14_float64(op), msg.f14_float64)},
      {"f15_fixed32", TestAllTypes.Opaque.get_f15_fixed32(op) == msg.f15_fixed32},
      {"f16_fixed64", TestAllTypes.Opaque.get_f16_fixed64(op) == msg.f16_fixed64},
      {"f20_overflow_str", TestAllTypes.Opaque.get_f20_overflow_str(op) == msg.f20_overflow_str}
    ]

    case Enum.find(checks, fn {_name, ok} -> not ok end) do
      nil -> :ok
      {field, false} -> {:error, "OpaqueTestAllTypes getter mismatch on #{field}"}
    end
  end

  defp float_eq?(a, b) when is_float(a) and is_float(b), do: a == b
  defp float_eq?(a, b), do: a == b

  # ---------------------------------------------------------------------------
  # Tier 2: Standard elixir-protobuf Types
  # ---------------------------------------------------------------------------

  defp handle_protobuf(%Request{message_type: "omnibuf.bench.PeerUpdate"} = req) do
    case Protobuf.decode(req.omnibuf_payload, PB.PeerUpdate) do
      {:ok, msg} ->
        %Response{omnibuf_payload: Protobuf.encode(msg, self_describing: req.self_describing)}

      {:error, %Error{message: msg}} ->
        %Response{parse_error: msg}
    end
  end

  defp handle_protobuf(%Request{message_type: "omnibuf.conformance.TestAllTypes"} = req) do
    case Protobuf.decode(req.omnibuf_payload, PB.TestAllTypes) do
      {:ok, msg} ->
        %Response{omnibuf_payload: Protobuf.encode(msg, self_describing: req.self_describing)}

      {:error, %Error{message: msg}} ->
        %Response{parse_error: msg}
    end
  end

  defp handle_protobuf(%Request{}) do
    %Response{skipped: "protobuf tier defined for PeerUpdate and TestAllTypes"}
  end

  # ---------------------------------------------------------------------------
  # Tier 3: Declarative OmniBuf.Schema Structs
  # ---------------------------------------------------------------------------

  defp handle_struct(%Request{message_type: type} = req) do
    case struct_module_for(type) do
      :error ->
        %Response{skipped: "unsupported struct message type: #{type}"}

      {:ok, mod} ->
        case mod.decode(req.omnibuf_payload) do
          {:ok, msg} ->
            %Response{omnibuf_payload: mod.encode(msg, self_describing: req.self_describing)}

          {:error, %Error{message: msg}} ->
            %Response{parse_error: msg}
        end
    end
  end

  defp struct_module_for("omnibuf.bench.PeerUpdate"), do: {:ok, S.PeerUpdate}
  defp struct_module_for("omnibuf.conformance.TestAllTypes"), do: {:ok, S.TestAllTypes}
  defp struct_module_for("omnibuf.conformance.TreeNode"), do: {:ok, S.TreeNode}
  defp struct_module_for("omnibuf.conformance.NestedCluster"), do: {:ok, S.NestedCluster}
  defp struct_module_for(_), do: :error
end
