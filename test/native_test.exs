defmodule OmniBuf.NativeTest do
  use ExUnit.Case, async: false

  alias OmniBuf.{Blind, Native}
  alias Omnibuf.Bench.{Location, Neighbor, PeerUpdate}

  setup do
    prev = Native.enabled?()

    on_exit(fn ->
      _ = Native.set_enabled(prev)
    end)

    :ok
  end

  test "runtime toggle switches cleanly between pure Elixir and Rust NIF" do
    assert :ok = Native.set_enabled(false)
    refute Native.enabled?()
    assert Native.mode() == :elixir

    if Native.loaded?() do
      assert :ok = Native.set_enabled(true)
      assert Native.enabled?()
      assert Native.mode() == :native
    else
      assert {:error, :not_loaded} = Native.set_enabled(true)
      assert Native.mode() == :elixir
    end
  end

  test "Rust NIF and pure Elixir produce identical wire bytes, structs, opaque splices, and blind JSON" do
    if Native.loaded?() do
      msg = %PeerUpdate{
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

      :ok = Native.set_enabled(false)
      elx_bytes = PeerUpdate.encode(msg)
      elx_sd = PeerUpdate.encode(msg, self_describing: true)
      {:ok, elx_dec} = PeerUpdate.decode(elx_bytes)
      {:ok, elx_blind} = Blind.decode(elx_sd)
      {:ok, elx_json} = Blind.decode_json(elx_sd)

      elx_spliced =
        elx_bytes
        |> PeerUpdate.Opaque.new()
        |> PeerUpdate.Opaque.set_sequence(9_876_543_211)
        |> PeerUpdate.Opaque.marshal!()

      :ok = Native.set_enabled(true)
      nif_bytes = PeerUpdate.encode(msg)
      nif_sd = PeerUpdate.encode(msg, self_describing: true)
      {:ok, nif_dec} = PeerUpdate.decode(nif_bytes)
      {:ok, nif_blind} = Blind.decode(nif_sd)
      {:ok, nif_json} = Blind.decode_json(nif_sd)

      nif_spliced =
        nif_bytes
        |> PeerUpdate.Opaque.new()
        |> PeerUpdate.Opaque.set_sequence(9_876_543_211)
        |> PeerUpdate.Opaque.marshal!()

      assert nif_bytes == elx_bytes
      assert nif_sd == elx_sd
      assert nif_dec == elx_dec
      assert nif_blind == elx_blind
      assert Jason.decode!(nif_json) == Jason.decode!(elx_json)
      assert nif_spliced == elx_spliced
    end
  end
end
