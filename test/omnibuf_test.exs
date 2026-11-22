defmodule OmniBufTest do
  use ExUnit.Case, async: true

  alias OmniBuf.{Blind, Error, Opaque, Protobuf, SchemaMeta, Wire}
  alias OmniBuf.Conformance.PB
  alias OmniBuf.Conformance.Struct, as: S
  alias Omnibuf.Bench.{Location, Neighbor, PeerUpdate}

  describe "Prefix-Varint" do
    test "encodes and decodes 1/2/4/9 byte boundaries" do
      cases = [
        {0, <<0x01>>},
        {127, <<0xFF>>},
        {128, <<0x02, 0x02>>},
        {300, <<0xB2, 0x04>>},
        {16_383, <<0xFE, 0xFF>>},
        {16_384, <<0x04, 0x00, 0x02, 0x00>>},
        {536_870_911, <<0xFC, 0xFF, 0xFF, 0xFF>>},
        {536_870_912, <<0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00>>},
        {18_446_744_073_709_551_615, <<0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>}
      ]

      for {val, expected} <- cases do
        assert Wire.encode_varint(val) == expected
        assert {:ok, ^val, <<>>} = Wire.decode_varint(expected)
      end
    end

    test "accepts non-minimal encodings" do
      # 42 as 2-byte prefix-varint: LE16((42 << 2) | 2) = 0x00AA -> <<0xAA, 0x00>>
      assert {:ok, 42, <<>>} = Wire.decode_varint(<<0xAA, 0x00>>)
      # 42 as 4-byte prefix-varint: LE32((42 << 3) | 4)
      assert {:ok, 42, <<>>} = Wire.decode_varint(<<42 * 8 + 4::little-unsigned-32>>)
      # 42 as 9-byte prefix-varint
      assert {:ok, 42, <<>>} = Wire.decode_varint(<<0, 42::little-unsigned-64>>)
    end

    test "rejects reserved prefix bytes" do
      for byte <- [0x08, 0x10, 0x18, 0x80, 0xF8] do
        assert {:error, %Error{reason: :reserved_varint_prefix}} =
                 Wire.decode_varint(<<byte, 0, 0, 0, 0, 0, 0, 0, 0>>)
      end
    end

    test "rejects truncated varints" do
      assert {:error, %Error{}} = Wire.decode_varint(<<>>)
      assert {:error, %Error{}} = Wire.decode_varint(<<0x02>>)
      assert {:error, %Error{}} = Wire.decode_varint(<<0x04, 0x00>>)
      assert {:error, %Error{}} = Wire.decode_varint(<<0x00, 1, 2, 3>>)
    end
  end

  describe "ZigZag and 32-bit narrowing" do
    test "round-trips 64-bit signed values including extremes" do
      values = [
        0,
        -1,
        1,
        -64,
        64,
        -2_147_483_648,
        2_147_483_647,
        -9_223_372_036_854_775_808,
        9_223_372_036_854_775_807
      ]

      for v <- values do
        u = Wire.encode_zigzag(v)
        assert Wire.decode_zigzag(u) == v
      end
    end

    test "narrows 64-bit values to two's-complement int32" do
      assert Wire.narrow_int32(0x8000_0000) == -2_147_483_648
      assert Wire.narrow_int32(0xFFFF_FFFF) == -1
      assert Wire.narrow_int32(0x1_0000_002A) == 42
    end
  end

  describe "Field #0 and container invariants" do
    test "rejects Field #0 with non-WireSubMsg wire type" do
      # Field #0 with WireUint (0): tag = 0 -> varint 0x01
      assert {:error, %Error{reason: :invalid_field_zero}} = Wire.decode_tag(<<0x01>>)
    end

    test "rejects invalid UTF-8 in decoded strings" do
      # Field #2 (router_id), WireString (10): tag = (2 << 4) | 10 = 42 -> varint 0x55
      bad_utf8 = <<0x55, Wire.encode_varint(2)::binary, 0xFF, 0xFE>>
      assert {:error, %Error{reason: :invalid_utf8}} = PeerUpdate.decode(bad_utf8)
      assert {:error, %Error{reason: :invalid_utf8}} = Blind.decode(bad_utf8)
    end

    test "Opaque skips unknown WireString in O(1) without scanning payload" do
      # Unknown field #99 with invalid UTF-8 bytes followed by field #1 (asn = 42)
      tag99 = Wire.encode_tag(99, 10)
      tag1 = Wire.encode_tag(1, 0)

      pkt =
        IO.iodata_to_binary([
          tag99,
          Wire.encode_varint(2),
          <<0xFF, 0xFE>>,
          tag1,
          Wire.encode_varint(42)
        ])

      op = PeerUpdate.Opaque.new(pkt)
      assert PeerUpdate.Opaque.get_asn(op) == 42
    end

    test "rejects empty WireArray with trailing bytes" do
      # Field #7 (tags), WireArray (13), ByteLen=3, ElementType=10, Count=0 (0x01), trailing 0x00
      tag = Wire.encode_tag(7, 13)
      pkt = IO.iodata_to_binary([tag, Wire.encode_varint(3), <<10, 0x01, 0x00>>])
      assert {:error, %Error{reason: :trailing_bytes}} = PeerUpdate.decode(pkt)
      assert {:error, %Error{reason: :trailing_bytes}} = Blind.decode(pkt)
    end

    test "rejects collection header ElementType mismatch" do
      # Field #7 (tags: array<string>), but ElementType=0 (WireUint)
      tag = Wire.encode_tag(7, 13)
      pkt = IO.iodata_to_binary([tag, Wire.encode_varint(2), <<0, 0x01>>])
      assert {:error, %Error{reason: :collection_type_mismatch}} = PeerUpdate.decode(pkt)
    end

    test "enforces exact max depth 32" do
      # Build 33 nested submessages via TreeNode.primary (field 4)
      tag4 = Wire.encode_tag(4, 12)

      deep_32 =
        Enum.reduce(1..32, <<>>, fn _, inner ->
          IO.iodata_to_binary([tag4, Wire.encode_varint(byte_size(inner)), inner])
        end)

      deep_33 = IO.iodata_to_binary([tag4, Wire.encode_varint(byte_size(deep_32)), deep_32])

      assert {:ok, _} = S.TreeNode.decode(deep_32)
      assert {:ok, _} = Blind.decode(deep_32)
      assert {:error, %Error{reason: :max_depth_exceeded}} = S.TreeNode.decode(deep_33)
      assert {:error, %Error{reason: :max_depth_exceeded}} = Blind.decode(deep_33)
    end
  end

  describe "All 4 tiers interoperability" do
    test "Tier 1, Tier 2, Tier 3 produce identical wire bytes and Tier 4 decodes with Field #0" do
      t1 = %PeerUpdate{
        asn: 64_512,
        router_id: "edge-rtr-fra01.core.backbone.net",
        active: true,
        uptime_sec: 1_849_203,
        rssi_dbm: -62,
        cpu_load: 0.42875,
        tags: ["tier1", "ebgp"],
        prefixes: [167_772_160, 172_032_000],
        location: %Location{
          region: "eu-central-1",
          datacenter: "FRA-Equinix-FR5",
          city: "Frankfurt",
          rack: 42,
          latitude: 50.1109,
          longitude: 8.6821
        },
        neighbors: [
          %Neighbor{
            peer_asn: 3356,
            router: "ae0.fra1.level3.net",
            latency_us: 850,
            established: true
          }
        ],
        sequence: 9_876_543_210
      }

      t2 = %PB.PeerUpdate{
        asn: 64_512,
        router_id: "edge-rtr-fra01.core.backbone.net",
        active: true,
        uptime_sec: 1_849_203,
        rssi_dbm: -62,
        cpu_load: 0.42875,
        tags: ["tier1", "ebgp"],
        prefixes: [167_772_160, 172_032_000],
        location: %PB.Location{
          region: "eu-central-1",
          datacenter: "FRA-Equinix-FR5",
          city: "Frankfurt",
          rack: 42,
          latitude: 50.1109,
          longitude: 8.6821
        },
        neighbors: [
          %PB.Neighbor{
            peer_asn: 3356,
            router: "ae0.fra1.level3.net",
            latency_us: 850,
            established: true
          }
        ],
        sequence: 9_876_543_210
      }

      t3 = %S.PeerUpdate{
        asn: 64_512,
        router_id: "edge-rtr-fra01.core.backbone.net",
        active: true,
        uptime_sec: 1_849_203,
        rssi_dbm: -62,
        cpu_load: 0.42875,
        tags: ["tier1", "ebgp"],
        prefixes: [167_772_160, 172_032_000],
        location: %S.Location{
          region: "eu-central-1",
          datacenter: "FRA-Equinix-FR5",
          city: "Frankfurt",
          rack: 42,
          latitude: 50.1109,
          longitude: 8.6821
        },
        neighbors: [
          %S.Neighbor{
            peer_asn: 3356,
            router: "ae0.fra1.level3.net",
            latency_us: 850,
            established: true
          }
        ],
        sequence: 9_876_543_210
      }

      b1 = PeerUpdate.encode(t1)
      b2 = Protobuf.encode(t2)
      b3 = S.PeerUpdate.encode(t3)

      assert b1 == b2
      assert b2 == b3

      assert {:ok, d1} = PeerUpdate.decode(b1)
      assert {:ok, d2} = Protobuf.decode(b2, PB.PeerUpdate)
      assert {:ok, d3} = S.PeerUpdate.decode(b3)

      assert PeerUpdate.encode(d1) == b1
      assert Protobuf.encode(d2) == b2
      assert S.PeerUpdate.encode(d3) == b3
      assert d1.asn == t1.asn
      assert d1.location.city == "Frankfurt"
      assert_in_delta d1.location.latitude, 50.1109, 1.0e-5
      assert_in_delta d1.location.longitude, 8.6821, 1.0e-5

      # Self-describing Tier 4 blind decode
      sd_bytes = PeerUpdate.encode(t1, self_describing: true)
      assert {:ok, blind_map} = Blind.decode(sd_bytes)
      assert blind_map["asn"] == 64_512
      assert blind_map["location"]["city"] == "Frankfurt"
      assert hd(blind_map["neighbors"])["router"] == "ae0.fra1.level3.net"
    end

    test "Opaque lazy getter and in-place iodata splice" do
      msg = %PeerUpdate{
        asn: 64_512,
        router_id: "edge-rtr-fra01",
        location: %Location{city: "Frankfurt", rack: 42},
        sequence: 100
      }

      bin = PeerUpdate.encode(msg)
      op = PeerUpdate.Opaque.new(bin)

      assert PeerUpdate.Opaque.get_location(op) |> Location.Opaque.get_city() == "Frankfurt"
      assert PeerUpdate.Opaque.get_sequence(op) == 100

      spliced =
        op
        |> PeerUpdate.Opaque.set_sequence(101)
        |> PeerUpdate.Opaque.marshal!()

      assert {:ok, decoded} = PeerUpdate.decode(spliced)
      assert decoded.sequence == 101
      assert decoded.router_id == "edge-rtr-fra01"
      assert decoded.location.city == "Frankfurt"
    end

    test "merge vs replace decode semantics" do
      p1 = PeerUpdate.encode(%PeerUpdate{asn: 100, tags: ["a"], location: %Location{city: "FRA"}})
      p2 = PeerUpdate.encode(%PeerUpdate{tags: ["b"], location: %Location{rack: 42}})

      {:ok, first} = PeerUpdate.decode(p1)
      {:ok, merged} = PeerUpdate.merge(first, p2)
      assert merged.asn == 100
      assert merged.tags == ["a", "b"]
      assert merged.location.city == "FRA"
      assert merged.location.rack == 42

      {:ok, replaced} = PeerUpdate.decode(p2)
      assert replaced.asn == 0
      assert replaced.tags == ["b"]
      assert replaced.location.city == ""
      assert replaced.location.rack == 42
    end
  end

  describe "SchemaMeta merge" do
    test "merges type_name, fields (including empty clear), and children recursively" do
      a = %SchemaMeta{
        type_name: "A",
        fields: %{1 => "one", 2 => "two"},
        children: %{9 => %SchemaMeta{fields: %{1 => "c1"}}}
      }

      b = %SchemaMeta{
        type_name: "",
        fields: %{2 => "", 3 => "three"},
        children: %{9 => %SchemaMeta{fields: %{2 => "c2"}}}
      }

      m = SchemaMeta.merge(a, b)
      assert m.type_name == "A"
      assert SchemaMeta.resolve_field_name(m, 1) == "one"
      assert SchemaMeta.resolve_field_name(m, 2) == "field_2"
      assert SchemaMeta.resolve_field_name(m, 3) == "three"
      assert SchemaMeta.resolve_field_name(m.children[9], 1) == "c1"
      assert SchemaMeta.resolve_field_name(m.children[9], 2) == "c2"
    end
  end

  describe "Opaque splice edge cases" do
    test "leaves empty dirty map untouched" do
      bin = PeerUpdate.encode(%PeerUpdate{asn: 7})
      assert {:ok, ^bin} = Opaque.splice(bin, %{})
    end
  end
end
