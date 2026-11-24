defmodule OmniBuf.AuditRegressionTest do
  use ExUnit.Case, async: false

  alias Google.Protobuf.Compiler.CodeGeneratorRequest

  alias Google.Protobuf.{
    DescriptorProto,
    EnumDescriptorProto,
    EnumValueDescriptorProto,
    FieldDescriptorProto,
    FileDescriptorProto
  }

  alias OmniBuf.{Blind, Error, Native, Opaque, Protobuf, SchemaMeta, Wire}
  alias OmniBuf.Conformance.PB
  alias OmniBuf.Conformance.Struct, as: S
  alias OmniBuf.Native.NIF
  alias OmniBuf.Plugin.Generator
  alias Omnibuf.Bench.PeerUpdate

  defmodule HighFieldSchema do
    use OmniBuf.Schema, name: "HighFieldSchema"

    field(1, :low, :uint32)
    field(33_554_432, :mid_high, :string)
    field(536_870_911, :max_num, :bool)
  end

  defmodule CustomDefaultInner do
    use OmniBuf.Schema, name: "CustomDefaultInner"

    field(1, :port, :uint32, default: 8080)
    field(2, :label, :string, default: "default-label")
  end

  defmodule CustomDefaultOuter do
    use OmniBuf.Schema, name: "CustomDefaultOuter"

    field(1, :retries, :int32, default: 3)
    field(2, :inner, CustomDefaultInner)
  end

  defmodule ParitySchema do
    use OmniBuf.Schema, name: "ParitySchema"

    field(1, :u32, :uint32)
    field(2, :i32, :int32)
    field(3, :f32, :fixed32)
    field(4, :sf32, :sfixed32)
    field(5, :fl, :float)
    field(6, :db, :double)
    field(7, :u32_map, {:map, :uint32, :string})
    field(8, :i32_map, {:map, :int32, :string})
  end

  setup do
    prev = Native.enabled?()

    on_exit(fn ->
      _ = Native.set_enabled(prev)
    end)

    :ok
  end

  describe "1. High field numbers (>= 33_554_432)" do
    test "round-trips 9-byte tags up to 536_870_911 identically in Elixir and NIF" do
      msg = %HighFieldSchema{low: 7, mid_high: "hello", max_num: true}

      :ok = Native.set_enabled(false)
      elx_bin = HighFieldSchema.encode(msg)
      assert {:ok, ^msg} = HighFieldSchema.decode(elx_bin)

      if Native.loaded?() do
        :ok = Native.set_enabled(true)
        nif_bin = HighFieldSchema.encode(msg)
        assert nif_bin == elx_bin
        assert {:ok, ^msg} = HighFieldSchema.decode(nif_bin)
      end
    end

    test "nif_compile_schema rejects out-of-range field numbers" do
      if Native.loaded?() do
        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([{BadZero, [{0, :a, :uint32, false}]}])
        end

        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([{BadMax, [{536_870_912, :a, :uint32, false}]}])
        end
      end
    end
  end

  describe "2. Bounded recursion in NIF schema compile and encode" do
    test "nif_compile_schema rejects > 32 nested container types" do
      if Native.loaded?() do
        deep_type = Enum.reduce(1..33, :uint32, fn _, acc -> {:array, acc} end)

        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([{DeepType, [{1, :x, deep_type, false}]}])
        end
      end
    end

    test "nif_encode_struct enforces max nesting depth 32 without crashing" do
      if Native.loaded?() do
        :ok = Native.set_enabled(true)

        # TreeNode has emit_empty: true on children/branches/labels, so 31 primary hops
        # places the leaf's empty arrays at depth 32 (max allowed), while 32 hops reaches 33.
        deep_31 =
          Enum.reduce(1..31, %S.TreeNode{}, fn _, child ->
            %S.TreeNode{primary: child}
          end)

        assert is_binary(S.TreeNode.encode(deep_31))

        deep_32 = %S.TreeNode{primary: deep_31}

        assert_raise ArgumentError, fn ->
          S.TreeNode.encode(deep_32)
        end
      end
    end
  end

  describe "3. Schema compiler bounds & duplicate validation" do
    test "nif_compile_schema rejects OOB message index, duplicate numbers/names, and :__struct__" do
      if Native.loaded?() do
        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([{BadIdx, [{1, :sub, {:message, 99}, false}]}])
        end

        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([
            {DupNum, [{1, :a, :uint32, false}, {1, :b, :uint32, false}]}
          ])
        end

        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([
            {DupName, [{1, :a, :uint32, false}, {2, :a, :uint32, false}]}
          ])
        end

        assert_raise ArgumentError, fn ->
          NIF.nif_compile_schema([{BadStruct, [{1, :__struct__, :uint32, false}]}])
        end
      end
    end
  end

  describe "4. Decode limits, header validation, and linear repeated-array merge" do
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

    test "merges 2,000 fragmented array occurrences linearly in Schema, Blind, and Protobuf" do
      # Field #8 (prefixes: array<uint32>) repeated 2,000 times with 1 element each
      tag = Wire.encode_tag(8, 13)

      pkt =
        1..2_000
        |> Enum.map(fn i ->
          body = IO.iodata_to_binary([<<0>>, Wire.encode_varint(1), Wire.encode_varint(i)])
          [tag, Wire.encode_varint(byte_size(body)), body]
        end)
        |> IO.iodata_to_binary()

      expected = Enum.to_list(1..2_000)

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)
        assert {:ok, %PeerUpdate{prefixes: ^expected}} = PeerUpdate.decode(pkt)
        assert {:ok, %{"field_8" => ^expected}} = Blind.decode(pkt)
      end

      assert {:ok, %PB.PeerUpdate{prefixes: ^expected}} = Protobuf.decode(pkt, PB.PeerUpdate)
    end

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
  end

  describe "5. Pure Elixir Blind.decode budget enforcement" do
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

  describe "6. DirtyCpu NIF routing for large payloads (>= 32_768 bytes)" do
    test "large payloads decode, merge, blind-decode, and splice identically in Elixir and NIF" do
      big_str = String.duplicate("x", 40_000)
      msg = %PeerUpdate{asn: 1234, router_id: big_str, active: true, sequence: 99}

      :ok = Native.set_enabled(false)
      pkt = PeerUpdate.encode(msg)
      sd_pkt = PeerUpdate.encode(msg, self_describing: true)
      assert byte_size(pkt) >= 32_768

      {:ok, elx_dec} = PeerUpdate.decode(pkt)
      {:ok, elx_merged} = PeerUpdate.merge(%PeerUpdate{rssi_dbm: -50}, pkt)
      {:ok, elx_blind} = Blind.decode(sd_pkt)
      {:ok, elx_json} = Blind.decode_json(sd_pkt)

      elx_spliced =
        pkt
        |> PeerUpdate.Opaque.new()
        |> PeerUpdate.Opaque.set_sequence(100)
        |> PeerUpdate.Opaque.marshal!()

      if Native.loaded?() do
        :ok = Native.set_enabled(true)
        assert {:ok, ^elx_dec} = PeerUpdate.decode(pkt)
        assert {:ok, ^elx_merged} = PeerUpdate.merge(%PeerUpdate{rssi_dbm: -50}, pkt)
        assert {:ok, ^elx_blind} = Blind.decode(sd_pkt)
        assert {:ok, nif_json} = Blind.decode_json(sd_pkt)
        assert Jason.decode!(nif_json) == Jason.decode!(elx_json)

        nif_spliced =
          pkt
          |> PeerUpdate.Opaque.new()
          |> PeerUpdate.Opaque.set_sequence(100)
          |> PeerUpdate.Opaque.marshal!()

        assert nif_spliced == elx_spliced
      end
    end
  end

  describe "7. Custom :default options parity" do
    test "NIF and pure Elixir return identical structs with custom :default values" do
      partial =
        CustomDefaultOuter.encode(%CustomDefaultOuter{
          retries: 0,
          inner: %CustomDefaultInner{port: 0, label: ""}
        })

      :ok = Native.set_enabled(false)
      {:ok, elx_empty} = CustomDefaultOuter.decode(<<>>)
      {:ok, elx_partial} = CustomDefaultOuter.decode(partial)
      {:ok, elx_merged} = CustomDefaultOuter.merge(%CustomDefaultOuter{retries: 9}, partial)

      assert elx_empty.retries == 3
      assert elx_partial.retries == 3
      assert elx_partial.inner.port == 8080
      assert elx_partial.inner.label == "default-label"
      assert elx_merged.retries == 9

      if Native.loaded?() do
        :ok = Native.set_enabled(true)
        assert {:ok, ^elx_empty} = CustomDefaultOuter.decode(<<>>)
        assert {:ok, ^elx_partial} = CustomDefaultOuter.decode(partial)

        assert {:ok, ^elx_merged} =
                 CustomDefaultOuter.merge(%CustomDefaultOuter{retries: 9}, partial)
      end
    end
  end

  describe "8. Integer, float, map-key, and Opaque skip_fast parity" do
    test "32-bit zero-omission, float32 underflow, u64-as-float, and 32-bit map key ordering match" do
      msg = %ParitySchema{
        u32: 0x1_0000_0000,
        i32: 0x1_0000_0000,
        f32: 0x1_0000_0000,
        sf32: 0x1_0000_0000,
        fl: 1.0e-50,
        db: 10_000_000_000_000_000_000,
        u32_map: %{0x1_0000_0001 => "one", 2 => "two"},
        i32_map: %{0xFFFF_FFFF => "neg_one", 0 => "zero"}
      }

      :ok = Native.set_enabled(false)
      elx_bin = ParitySchema.encode(msg)
      {:ok, elx_dec} = ParitySchema.decode(elx_bin)

      # All four 32-bit ints narrowed to 0 and float32 1.0e-50 underflowed to 0 -> omitted
      assert elx_dec.u32 == 0
      assert elx_dec.i32 == 0
      assert elx_dec.f32 == 0
      assert elx_dec.sf32 == 0
      assert elx_dec.fl == 0.0

      if Native.loaded?() do
        :ok = Native.set_enabled(true)
        nif_bin = ParitySchema.encode(msg)
        assert nif_bin == elx_bin
        assert {:ok, ^elx_dec} = ParitySchema.decode(nif_bin)
      end
    end

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
  end

  describe "9. Compile-time field validation and SchemaMeta depth cap" do
    test "OmniBuf.Schema rejects invalid field numbers and duplicates at compile time" do
      assert_raise ArgumentError, ~r/invalid OmniBuf field number 0/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.AuditRegressionTest.BadFieldZero do
          use OmniBuf.Schema
          field 0, :a, :uint32
        end
        """)
      end

      assert_raise ArgumentError, ~r/invalid OmniBuf field number 536870912/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.AuditRegressionTest.BadFieldTooBig do
          use OmniBuf.Schema
          field 536_870_912, :a, :uint32
        end
        """)
      end

      assert_raise ArgumentError, ~r/duplicate OmniBuf field number 1/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.AuditRegressionTest.BadDupNumber do
          use OmniBuf.Schema
          field 1, :a, :uint32
          field 1, :b, :string
        end
        """)
      end

      assert_raise ArgumentError, ~r/duplicate OmniBuf field name :a/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.AuditRegressionTest.BadDupName do
          use OmniBuf.Schema
          field 1, :a, :uint32
          field 2, :a, :string
        end
        """)
      end
    end

    test "Schema.schema_meta/2 and Protobuf.schema_meta/3 enforce depth + 2 <= max_depth" do
      meta_s = PeerUpdate.schema_meta(MapSet.new(), Wire.max_depth() - 1)
      assert meta_s.children == %{}

      meta_pb = Protobuf.schema_meta(PB.PeerUpdate, MapSet.new(), Wire.max_depth() - 1)
      assert meta_pb.children == %{}
    end
  end

  describe "10. Codegen enum keyword escaping and TYPE_GROUP rejection" do
    test "escapes Elixir reserved keywords in generated enums so output compiles" do
      enum_desc = %EnumDescriptorProto{
        name: "KeywordEnum",
        value: [
          %EnumValueDescriptorProto{name: "END", number: 0},
          %EnumValueDescriptorProto{name: "DO", number: 1},
          %EnumValueDescriptorProto{name: "FN", number: 2},
          %EnumValueDescriptorProto{name: "TRUE", number: 3},
          %EnumValueDescriptorProto{name: "FALSE", number: 4},
          %EnumValueDescriptorProto{name: "NIL", number: 5},
          %EnumValueDescriptorProto{name: "NORMAL", number: 6}
        ]
      }

      req = %CodeGeneratorRequest{
        file_to_generate: ["kw.proto"],
        parameter: "module_prefix=OmniBuf.AuditRegressionTest.Gen",
        proto_file: [
          %FileDescriptorProto{
            name: "kw.proto",
            package: "test",
            enum_type: [enum_desc]
          }
        ]
      }

      resp = Generator.generate(req)
      assert [%{content: code}] = resp.file
      assert code =~ "def end_, do: 0"
      assert code =~ "def do_, do: 1"
      assert code =~ "def fn_, do: 2"
      assert code =~ "def true_, do: 3"
      assert code =~ "def false_, do: 4"
      assert code =~ "def nil_, do: 5"
      assert code =~ "def normal, do: 6"
      assert [{mod, _}] = Code.compile_string(code)
      assert mod.end_() == 0
      assert mod.normal() == 6
    end

    test "rejects TYPE_GROUP cleanly with ArgumentError" do
      req = %CodeGeneratorRequest{
        file_to_generate: ["group.proto"],
        proto_file: [
          %FileDescriptorProto{
            name: "group.proto",
            message_type: [
              %DescriptorProto{
                name: "HasGroup",
                field: [
                  %FieldDescriptorProto{
                    name: "legacy",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_GROUP
                  }
                ]
              }
            ]
          }
        ]
      }

      assert_raise ArgumentError, ~r/TYPE_GROUP/, fn ->
        Generator.generate(req)
      end
    end
  end

  describe "11. Cumulative DecodeBudget, integer bounds, spec & ergonomics" do
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

    test "Opaque.splice/2 validates packet even when dirty map is empty" do
      bad_pkt = <<0x08, 0x00>>

      for native? <- if(Native.loaded?(), do: [false, true], else: [false]) do
        :ok = Native.set_enabled(native?)
        assert {:error, %Error{}} = Opaque.splice(bad_pkt, %{})
      end
    end

    test "bang variants return decoded value or raise OmniBuf.Error" do
      msg = %PeerUpdate{asn: 42, router_id: "rtr-1", active: true}
      pkt = OmniBuf.encode(msg, self_describing: true)

      assert ^msg = PeerUpdate.decode!(pkt)
      assert ^msg = OmniBuf.decode!(pkt, PeerUpdate)
      assert %{"asn" => 42, "router_id" => "rtr-1", "active" => true} = OmniBuf.decode_blind!(pkt)
      assert is_binary(OmniBuf.decode_blind_json!(pkt))

      assert_raise Error, fn -> PeerUpdate.decode!(<<0x08, 0x00>>) end
      assert_raise Error, fn -> OmniBuf.decode_blind!(<<0x08, 0x00>>) end
      assert_raise Error, fn -> OmniBuf.decode_blind_json!(<<0x08, 0x00>>) end
    end

    test "large struct encode uses dirty-CPU NIF cleanly" do
      if Native.loaded?() do
        big = %PeerUpdate{asn: 7, router_id: String.duplicate("a", 40_000), active: true}
        :ok = Native.set_enabled(false)
        elx_bin = PeerUpdate.encode(big)

        :ok = Native.set_enabled(true)
        nif_bin = PeerUpdate.encode(big)
        assert nif_bin == elx_bin
      end
    end
  end
end
