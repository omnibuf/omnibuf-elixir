defmodule OmniBuf.BlindTest do
  use ExUnit.Case, async: false

  alias OmniBuf.{Blind, Error, Native, SchemaMeta, Wire}
  alias Omnibuf.Bench.PeerUpdate

  setup do
    prev = Native.enabled?()

    on_exit(fn ->
      _ = Native.set_enabled(prev)
    end)

    :ok
  end

  describe "decode limits and budgets" do
    test "Blind.decode respects small max_message_bytes without failing valid small packets" do
      pkt = PeerUpdate.encode(%PeerUpdate{asn: 42, active: true})

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)

        assert {:ok, %{"field_1" => 42, "field_3" => true}} =
                 Blind.decode(pkt, max_message_bytes: byte_size(pkt))

        assert {:error, %Error{reason: :message_too_large}} =
                 Blind.decode(pkt, max_message_bytes: byte_size(pkt) - 1)
      end
    end

    test "enforces custom max_depth and max_elements inside Field #0 SchemaMeta" do
      meta = %SchemaMeta{
        type_name: "Root",
        fields: %{1 => "a", 2 => "b", 3 => "c", 4 => "d"},
        children: %{
          5 => %SchemaMeta{
            type_name: "Child",
            fields: %{1 => "x"}
          }
        }
      }

      pkt = IO.iodata_to_binary([SchemaMeta.encode_field(meta), Wire.encode_tag(1, 0), <<0x03>>])

      :ok = Native.set_enabled(false)
      # Pure Elixir enforces max_elements inside SchemaMeta.fields
      assert {:error, %Error{reason: :element_limit_exceeded}} =
               Blind.decode(pkt, max_elements: 3)

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)

        # max_depth: 2 must reject SchemaMeta.children (depth 1 + 2 = 3 > 2) in both modes
        assert {:error, %Error{reason: :max_depth_exceeded}} = Blind.decode(pkt, max_depth: 2)
      end
    end

    test "enforces custom max_elements inside nested container shape checks" do
      # Array of 2 arrays of 3 uints = 2 + 6 = 8 elements total
      inner =
        IO.iodata_to_binary([
          <<0>>,
          Wire.encode_varint(3),
          Wire.encode_varint(1),
          Wire.encode_varint(2),
          Wire.encode_varint(3)
        ])

      inner_lp = IO.iodata_to_binary([Wire.encode_varint(byte_size(inner)), inner])
      outer_body = IO.iodata_to_binary([<<13>>, Wire.encode_varint(2), inner_lp, inner_lp])

      pkt =
        IO.iodata_to_binary([
          Wire.encode_tag(1, 13),
          Wire.encode_varint(byte_size(outer_body)),
          outer_body
        ])

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)
        assert {:error, %Error{}} = Blind.decode(pkt, max_elements: 5)
        assert {:ok, %{"field_1" => [[1, 2, 3], [1, 2, 3]]}} = Blind.decode(pkt, max_elements: 10)
      end
    end
  end

  describe "JSON ordering and SchemaMeta invariants" do
    test "pure-Elixir Blind.decode_json/2 sorts maps with > 32 keys in unsigned UTF-8 byte order" do
      :ok = Native.set_enabled(false)

      # Build a packet with 45 fields (> 32 so BEAM uses HAMT map representation)
      pkt =
        45..1//-1
        |> Enum.map(fn i ->
          [Wire.encode_tag(i, 0), Wire.encode_varint(i)]
        end)
        |> IO.iodata_to_binary()

      {:ok, json} = Blind.decode_json(pkt)
      keys = Regex.scan(~r/"(field_\d+)":/, json) |> Enum.map(fn [_, k] -> k end)
      assert length(keys) == 45
      assert keys == Enum.sort(keys)
    end

    test "rejects nested Field #0 inside SchemaMeta" do
      inner = IO.iodata_to_binary(SchemaMeta.encode_field(%SchemaMeta{type_name: "Inner"}))
      outer = IO.iodata_to_binary([<<0x19>>, Wire.encode_length_prefixed(inner)])

      :ok = Native.set_enabled(false)
      assert {:error, %Error{reason: :invalid_field_zero}} = Blind.decode(outer)
      assert {:error, %Error{reason: :invalid_field_zero}} = PeerUpdate.decode(outer)
    end
  end
end
