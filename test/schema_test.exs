defmodule OmniBuf.SchemaTest do
  use ExUnit.Case, async: false

  alias OmniBuf.{Blind, Error, Native, Protobuf, Wire}
  alias OmniBuf.Conformance.PB
  alias OmniBuf.Conformance.Struct, as: S
  alias OmniBuf.Native.NIF
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

  defmodule BudgetSchema do
    use OmniBuf.Schema, name: "BudgetSchema"

    field(1, :raw, :bytes)
    field(2, :items, {:array, :uint32})
    field(3, :entries, {:map, :uint32, :uint32})
  end

  setup do
    prev = Native.enabled?()

    on_exit(fn ->
      _ = Native.set_enabled(prev)
    end)

    :ok
  end

  describe "high field numbers (>= 33_554_432)" do
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

  describe "compile-time and NIF schema validation" do
    test "OmniBuf.Schema rejects invalid field numbers and duplicates at compile time" do
      assert_raise ArgumentError, ~r/invalid OmniBuf field number 0/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.SchemaTest.BadFieldZero do
          use OmniBuf.Schema
          field 0, :a, :uint32
        end
        """)
      end

      assert_raise ArgumentError, ~r/invalid OmniBuf field number 536870912/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.SchemaTest.BadFieldTooBig do
          use OmniBuf.Schema
          field 536_870_912, :a, :uint32
        end
        """)
      end

      assert_raise ArgumentError, ~r/duplicate OmniBuf field number 1/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.SchemaTest.BadDupNumber do
          use OmniBuf.Schema
          field 1, :a, :uint32
          field 1, :b, :string
        end
        """)
      end

      assert_raise ArgumentError, ~r/duplicate OmniBuf field name :a/, fn ->
        Code.compile_string("""
        defmodule OmniBuf.SchemaTest.BadDupName do
          use OmniBuf.Schema
          field 1, :a, :uint32
          field 2, :a, :string
        end
        """)
      end
    end

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

    test "Schema.schema_meta/2 and Protobuf.schema_meta/3 enforce depth + 2 <= max_depth" do
      meta_s = PeerUpdate.schema_meta(MapSet.new(), Wire.max_depth() - 1)
      assert meta_s.children == %{}

      meta_pb = Protobuf.schema_meta(PB.PeerUpdate, MapSet.new(), Wire.max_depth() - 1)
      assert meta_pb.children == %{}
    end
  end

  describe "Elixir and NIF codec parity" do
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

    test "large struct encode uses dirty-CPU NIF cleanly" do
      if Native.loaded?() do
        big = %PeerUpdate{asn: 7, router_id: String.duplicate("a", 300_000), active: true}
        :ok = Native.set_enabled(false)
        elx_bin = PeerUpdate.encode(big)

        :ok = Native.set_enabled(true)
        nif_bin = PeerUpdate.encode(big)
        assert nif_bin == elx_bin
      end
    end

    test "normal-scheduler encode handles 40 KB payloads and bails to dirty-CPU past byte or element budgets" do
      if Native.loaded?() do
        schema =
          NIF.nif_compile_schema([
            {BudgetSchema,
             [
               {1, :raw, :bytes, false},
               {2, :items, {:array, :uint32}, false},
               {3, :entries, {:map, :uint32, :uint32}, false}
             ]}
          ])

        medium = %BudgetSchema{raw: :binary.copy(<<0xAB>>, 40_000)}
        at_elem_limit = %BudgetSchema{items: Enum.to_list(1..8_192)}
        big_bytes = %BudgetSchema{raw: :binary.copy(<<0xCD>>, 262_145)}
        big_array = %BudgetSchema{items: Enum.to_list(1..8_193)}
        big_map = %BudgetSchema{entries: Map.new(1..8_193, &{&1, &1 * 2})}

        # Normal-scheduler path encodes 40 KB and 8,192-elem payloads directly without yielding.
        for msg <- [medium, at_elem_limit] do
          :ok = Native.set_enabled(false)
          elx_bin = BudgetSchema.encode(msg)

          :ok = Native.set_enabled(true)
          assert NIF.nif_encode_struct(schema, msg) == elx_bin
          assert BudgetSchema.encode(msg) == elx_bin
        end

        # Payloads exceeding 256 KiB or 8,192 elements yield :dirty and match pure Elixir via dirty-CPU.
        for msg <- [big_bytes, big_array, big_map] do
          :ok = Native.set_enabled(false)
          elx_bin = BudgetSchema.encode(msg)

          :ok = Native.set_enabled(true)
          assert NIF.nif_encode_struct(schema, msg) == :dirty
          assert BudgetSchema.encode(msg) == elx_bin
        end
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
  end
end
