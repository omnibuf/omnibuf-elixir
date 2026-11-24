defmodule OmniBuf.WireTest do
  use ExUnit.Case, async: false

  alias OmniBuf.{Blind, Error, Native, Opaque, Protobuf, Wire}
  alias OmniBuf.Conformance.PB
  alias Omnibuf.Bench.PeerUpdate

  setup do
    prev = Native.enabled?()

    on_exit(fn ->
      _ = Native.set_enabled(prev)
    end)

    :ok
  end

  describe "integer bounds" do
    test "Wire.encode_varint/1 and encode_zigzag/1 validate 64-bit bounds" do
      assert is_binary(Wire.encode_varint(0))
      assert is_binary(Wire.encode_varint(0xFFFF_FFFF_FFFF_FFFF))
      assert_raise ArgumentError, fn -> Wire.encode_varint(-1) end
      assert_raise ArgumentError, fn -> Wire.encode_varint(0x1_0000_0000_0000_0000) end

      assert Wire.encode_zigzag(9_223_372_036_854_775_807) == 0xFFFF_FFFF_FFFF_FFFE
      assert Wire.encode_zigzag(-9_223_372_036_854_775_808) == 0xFFFF_FFFF_FFFF_FFFF
      assert_raise ArgumentError, fn -> Wire.encode_zigzag(9_223_372_036_854_775_808) end
      assert_raise ArgumentError, fn -> Wire.encode_zigzag(-9_223_372_036_854_775_809) end
    end
  end

  describe "container header validation and decode budgets" do
    test "rejects malformed WireArray/WireMap count exceeding remaining bytes in NIF and Elixir" do
      # Field #7 (tags: array<string>), ByteLen=2, ElemType=10, Count=50 (0 bytes remaining)
      bad_array =
        IO.iodata_to_binary([
          Wire.encode_tag(7, 13),
          Wire.encode_varint(2),
          <<10>>,
          Wire.encode_varint(50)
        ])

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)
        assert {:error, %Error{}} = PeerUpdate.decode(bad_array)
        assert {:error, %Error{}} = Blind.decode(bad_array)
      end
    end

    test "pure Elixir Schema, Protobuf, and Wire.skip_validated enforce cumulative budget & options" do
      # 4 chunks of 3 uint32 elements = 12 elements total (> max_elements: 10)
      tag = Wire.encode_tag(8, 13)

      chunked =
        1..4
        |> Enum.map(fn _ ->
          body = IO.iodata_to_binary([<<0>>, Wire.encode_varint(3), <<3, 5, 7>>])
          [tag, Wire.encode_varint(byte_size(body)), body]
        end)
        |> IO.iodata_to_binary()

      :ok = Native.set_enabled(false)

      assert {:error, %Error{reason: :element_limit_exceeded}} =
               PeerUpdate.decode(chunked, max_elements: 10)

      assert {:ok, %PeerUpdate{prefixes: [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3]}} =
               PeerUpdate.decode(chunked, max_elements: 12)

      assert {:error, %Error{reason: :message_too_large}} =
               PeerUpdate.decode(chunked, max_message_bytes: byte_size(chunked) - 1)

      assert {:error, %Error{reason: :element_limit_exceeded}} =
               Protobuf.decode(chunked, PB.PeerUpdate, max_elements: 10)

      assert {:error, %Error{reason: :message_too_large}} =
               Protobuf.decode(chunked, PB.PeerUpdate, max_message_bytes: byte_size(chunked) - 1)

      assert {:error, %Error{reason: :max_depth_exceeded}} =
               PeerUpdate.decode(
                 PeerUpdate.encode(%PeerUpdate{
                   neighbors: [%Omnibuf.Bench.Neighbor{peer_asn: 1}]
                 }),
                 max_depth: 1
               )

      assert {:error, %Error{reason: :element_limit_exceeded}} =
               Wire.skip_validated(
                 13,
                 IO.iodata_to_binary([
                   Wire.encode_varint(5),
                   <<0>>,
                   Wire.encode_varint(3),
                   <<3, 5, 7>>
                 ]),
                 0,
                 max_elements: 2
               )
    end
  end

  describe "Opaque wire validation" do
    test "Opaque skip_fast validates malformed WireArray and WireMap headers identically" do
      # Field #7 (WireArray) with invalid ElementType 3 (WireBoolTrue), followed by field #1 = 42
      bad_array_pkt =
        IO.iodata_to_binary([
          Wire.encode_tag(7, 13),
          Wire.encode_varint(2),
          <<3, 0x01>>,
          Wire.encode_tag(1, 0),
          Wire.encode_varint(42)
        ])

      # Field #7 (WireMap) with invalid KeyType 8 (WireFloat32), followed by field #1 = 42
      bad_map_pkt =
        IO.iodata_to_binary([
          Wire.encode_tag(7, 14),
          Wire.encode_varint(3),
          <<8, 0, 0x01>>,
          Wire.encode_tag(1, 0),
          Wire.encode_varint(42)
        ])

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)
        assert {:error, %Error{}} = Opaque.find_last(bad_array_pkt, 1, 0)
        assert {:error, %Error{}} = Opaque.find_last(bad_map_pkt, 1, 0)
      end
    end

    test "Opaque.splice/2 validates packet even when dirty map is empty" do
      bad_pkt = <<0x08, 0x00>>

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)
        assert {:error, %Error{}} = Opaque.splice(bad_pkt, %{})
      end
    end
  end
end
