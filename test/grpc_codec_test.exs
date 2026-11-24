defmodule OmniBuf.GRPC.CodecTest do
  use ExUnit.Case, async: false

  alias OmniBuf.Conformance.PB
  alias OmniBuf.Error
  alias OmniBuf.GRPC.{Codec, SelfDescribingCodec}
  alias Omnibuf.Bench.{Location, PeerUpdate}

  defmodule PingSchema do
    use OmniBuf.Schema, name: "PingSchema"

    field(1, :id, :uint32)
    field(2, :node, :string)
    field(3, :ok, :bool)
  end

  defmodule PingService do
    use GRPC.Service, name: "omnibuf.test.PingService"

    rpc(:Ping, PingSchema, PingSchema)
    rpc(:PeerEcho, PeerUpdate, PeerUpdate)
  end

  defmodule PingStub do
    use GRPC.Stub, service: PingService
  end

  defmodule PingServer do
    use GRPC.Server,
      service: PingService,
      codecs: [Codec, SelfDescribingCodec]

    def ping(%PingSchema{id: id, node: node, ok: ok}, _stream) do
      %PingSchema{id: id + 1, node: "echo:" <> node, ok: ok}
    end

    def peer_echo(%PeerUpdate{sequence: seq} = req, _stream) do
      %{req | sequence: seq + 1}
    end
  end

  defmodule PingEndpoint do
    use GRPC.Endpoint

    run(PingServer)
  end

  describe "OmniBuf.GRPC.Codec" do
    test "exposes standard omnibuf codec name" do
      assert Codec.name() == "omnibuf"
    end

    test "round-trips OmniBuf.Schema structs" do
      msg = %PingSchema{id: 42, node: "edge-fra-1", ok: true}
      wire = Codec.encode(msg)

      assert is_binary(wire)
      assert Codec.decode(wire, PingSchema) == msg
    end

    test "round-trips generated OmniBuf modules" do
      msg = %PeerUpdate{
        asn: 64_512,
        router_id: "rtr-fra-01",
        active: true,
        location: %Location{region: "eu-central-1", city: "Frankfurt", rack: 7},
        sequence: 123_456
      }

      wire = Codec.encode(msg)

      assert Codec.decode(wire, PeerUpdate) == msg
    end

    test "round-trips elixir-protobuf structs" do
      msg = %PB.PeerUpdate{asn: 64_512, router_id: "rtr-pb-1", active: true, sequence: 99}
      wire = Codec.encode(msg)

      assert Codec.decode(wire, PB.PeerUpdate) == msg
    end

    test "handles empty payloads and raises OmniBuf.Error on malformed wire bytes" do
      assert Codec.decode(<<>>, PingSchema) == %PingSchema{}

      assert_raise Error, fn ->
        Codec.decode(<<0x08, 0x00>>, PingSchema)
      end
    end

    test "raises ArgumentError for unsupported module" do
      assert_raise ArgumentError, ~r/not an OmniBuf\.Schema/, fn ->
        Codec.decode(<<>>, URI)
      end

      assert_raise ArgumentError, ~r/not an OmniBuf\.Schema/, fn ->
        Codec.encode(%URI{})
      end
    end
  end

  describe "OmniBuf.GRPC.SelfDescribingCodec" do
    test "exposes self-describing x-omnibuf codec name" do
      assert SelfDescribingCodec.name() == "x-omnibuf"
    end

    test "encodes Field #0 metadata and decodes back to OmniBuf.Schema and generated structs" do
      schema_msg = %PingSchema{id: 7, node: "ams-1", ok: true}
      schema_wire = SelfDescribingCodec.encode(schema_msg)

      assert {:ok, %{"id" => 7, "node" => "ams-1", "ok" => true}} =
               OmniBuf.decode_blind(schema_wire)

      assert SelfDescribingCodec.decode(schema_wire, PingSchema) == schema_msg

      gen_msg = %Location{region: "eu-west-1", city: "Dublin", rack: 3}
      gen_wire = SelfDescribingCodec.encode(gen_msg)

      assert {:ok, %{"region" => "eu-west-1", "city" => "Dublin", "rack" => 3}} =
               OmniBuf.decode_blind(gen_wire)

      assert SelfDescribingCodec.decode(gen_wire, Location) == gen_msg
    end
  end

  describe "grpc-elixir loopback integration" do
    setup do
      {:ok, _pid, port} = GRPC.Server.start_endpoint(PingEndpoint, 0)

      on_exit(fn ->
        GRPC.Server.stop_endpoint(PingEndpoint)
      end)

      {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")

      {:ok, channel: channel}
    end

    test "executes unary RPC with OmniBuf.GRPC.Codec over HTTP/2", %{channel: channel} do
      req = %PingSchema{id: 42, node: "edge-fra-1", ok: true}

      assert {:ok, %PingSchema{id: 43, node: "echo:edge-fra-1", ok: true}, %{headers: headers}} =
               PingStub.ping(channel, req, codec: Codec, return_headers: true)

      assert headers["content-type"] == "application/grpc+omnibuf"
    end

    test "executes unary RPC with OmniBuf.GRPC.SelfDescribingCodec over HTTP/2", %{
      channel: channel
    } do
      req = %PingSchema{id: 7, node: "ams-1", ok: true}

      assert {:ok, %PingSchema{id: 8, node: "echo:ams-1", ok: true}, %{headers: headers}} =
               PingStub.ping(channel, req, codec: SelfDescribingCodec, return_headers: true)

      assert headers["content-type"] == "application/grpc+x-omnibuf"
    end

    test "round-trips generated PeerUpdate struct over real GRPC.Server", %{channel: channel} do
      req = %PeerUpdate{
        asn: 64_512,
        router_id: "rtr-fra-01",
        active: true,
        location: %Location{region: "eu-central-1", city: "Frankfurt", rack: 7},
        sequence: 999
      }

      assert {:ok, %PeerUpdate{} = reply} = PingStub.peer_echo(channel, req, codec: Codec)
      assert reply.asn == 64_512
      assert reply.location.city == "Frankfurt"
      assert reply.sequence == 1000
    end
  end
end
