defmodule OmniBuf.Bench.PeerBench do
  @moduledoc false

  alias OmniBuf.Conformance.PB
  alias OmniBuf.Conformance.Struct, as: S
  alias Omnibuf.Bench.{Location, Neighbor, PeerUpdate}

  def run do
    gen_msg = sample_generated()
    schema_msg = sample_schema()
    pb_msg = sample_pb()
    json_map = sample_json_map()

    omnibuf_bytes = PeerUpdate.encode(gen_msg)
    schema_bytes = S.PeerUpdate.encode(schema_msg)
    pb_bytes = PB.PeerUpdate.encode(pb_msg)
    json_bytes = Jason.encode!(json_map)

    # Minimal Prefix-Varint length prefixes produce 358 bytes (vs 366 with 2-byte backpatched slots)
    if byte_size(omnibuf_bytes) != 358 do
      raise "Expected OmniBuf SamplePeerUpdate wire size 358, got #{byte_size(omnibuf_bytes)}"
    end

    if schema_bytes != omnibuf_bytes do
      raise "Schema DSL wire output does not match generated output"
    end

    if byte_size(pb_bytes) != 341 do
      raise "Expected Protobuf SamplePeerUpdate wire size 341, got #{byte_size(pb_bytes)}"
    end

    {:ok, decoded_gen} = PeerUpdate.decode(omnibuf_bytes)
    ^omnibuf_bytes = PeerUpdate.encode(decoded_gen)
    {:ok, decoded_schema} = S.PeerUpdate.decode(schema_bytes)
    ^schema_bytes = S.PeerUpdate.encode(decoded_schema)
    decoded_pb = PB.PeerUpdate.decode(pb_bytes)
    ^pb_bytes = PB.PeerUpdate.encode(decoded_pb)
    _ = Jason.decode!(json_bytes)

    # Verify Opaque lookup & splice
    op = PeerUpdate.Opaque.new(omnibuf_bytes)
    "Frankfurt" = op |> PeerUpdate.Opaque.get_location() |> Location.Opaque.get_city()

    spliced =
      op
      |> PeerUpdate.Opaque.set_sequence(PeerUpdate.Opaque.get_sequence(op) + 1)
      |> PeerUpdate.Opaque.marshal!()

    {:ok, %{sequence: 9_876_543_211}} = PeerUpdate.decode(spliced)

    # Category 5: Large Embedded Message Encode (>16 KiB submessage + cascading array shift)
    shift_dc = String.duplicate("d", 20_480)
    shift_rtr = String.duplicate("n", 18_432)

    gen_shift = %{
      gen_msg
      | location: %{gen_msg.location | datacenter: shift_dc},
        neighbors: [%{hd(gen_msg.neighbors) | router: shift_rtr} | tl(gen_msg.neighbors)]
    }

    schema_shift = %{
      schema_msg
      | location: %{schema_msg.location | datacenter: shift_dc},
        neighbors: [%{hd(schema_msg.neighbors) | router: shift_rtr} | tl(schema_msg.neighbors)]
    }

    pb_shift = %{
      pb_msg
      | location: %{pb_msg.location | datacenter: shift_dc},
        neighbors: [%{hd(pb_msg.neighbors) | router: shift_rtr} | tl(pb_msg.neighbors)]
    }

    json_shift = %{
      json_map
      | "location" => %{json_map["location"] | "datacenter" => shift_dc},
        "neighbors" => [
          %{hd(json_map["neighbors"]) | "router" => shift_rtr} | tl(json_map["neighbors"])
        ]
    }

    gen_shift_bytes = PeerUpdate.encode(gen_shift)
    schema_shift_bytes = S.PeerUpdate.encode(schema_shift)
    pb_shift_bytes = PB.PeerUpdate.encode(pb_shift)
    json_shift_bytes = Jason.encode!(json_shift)

    # Category 6: Embedded Message Growth (32 neighbors trailing location -> >16 KiB growth)
    routing_neighbors_gen = List.flatten(List.duplicate(gen_msg.neighbors, 8))
    routing_gen = %{gen_msg | neighbors: routing_neighbors_gen}
    routing_omnibuf_bytes = PeerUpdate.encode(routing_gen)

    routing_pb = %{pb_msg | neighbors: List.flatten(List.duplicate(pb_msg.neighbors, 8))}
    routing_pb_bytes = PB.PeerUpdate.encode(routing_pb)

    routing_json = %{
      json_map
      | "neighbors" => List.flatten(List.duplicate(json_map["neighbors"], 8))
    }

    routing_json_bytes = Jason.encode!(routing_json)

    grown_dc = String.duplicate("d", 20_480)

    runtime = "Elixir #{System.version()} (OTP #{:erlang.system_info(:otp_release)})"
    platform = detect_platform()
    arch = detect_arch()
    cpu = detect_cpu()

    IO.puts("OmniBuf Elixir Benchmark Suite")
    IO.puts("Runtime: #{runtime} | Platform: #{platform}/#{arch} | CPU: #{cpu}")

    categories = [
      build_category("encode", "Full Message Encode Speed", [
        measure("OmniBuf (Generated)", byte_size(omnibuf_bytes), true, true, fn ->
          PeerUpdate.encode(gen_msg)
        end),
        measure("OmniBuf (Schema DSL)", byte_size(schema_bytes), true, false, fn ->
          S.PeerUpdate.encode(schema_msg)
        end),
        measure("elixir-protobuf", byte_size(pb_bytes), false, false, fn ->
          PB.PeerUpdate.encode(pb_msg)
        end),
        measure("Jason (JSON)", byte_size(json_bytes), false, false, fn ->
          Jason.encode!(json_map)
        end)
      ]),
      build_category("decode", "Full Message Decode Speed", [
        measure("OmniBuf (Generated)", nil, true, true, fn ->
          {:ok, _} = PeerUpdate.decode(omnibuf_bytes)
        end),
        measure("OmniBuf (Schema DSL)", nil, true, false, fn ->
          {:ok, _} = S.PeerUpdate.decode(schema_bytes)
        end),
        measure("elixir-protobuf", nil, false, false, fn ->
          PB.PeerUpdate.decode(pb_bytes)
        end),
        measure("Jason (JSON)", nil, false, false, fn ->
          Jason.decode!(json_bytes)
        end)
      ]),
      build_category("lookup_city", "Read a Single Nested Field", [
        measure("OmniBuf (Generated)", nil, true, true, fn ->
          omnibuf_bytes
          |> PeerUpdate.Opaque.new()
          |> PeerUpdate.Opaque.get_location()
          |> Location.Opaque.get_city()
        end),
        measure("elixir-protobuf", nil, false, false, fn ->
          PB.PeerUpdate.decode(pb_bytes).location.city
        end),
        measure("Jason (JSON)", nil, false, false, fn ->
          Jason.decode!(json_bytes)["location"]["city"]
        end)
      ]),
      build_category("mutate_sequence", "Selective Single-Field Mutation", [
        measure("OmniBuf (Generated)", nil, true, true, fn ->
          view = PeerUpdate.Opaque.new(omnibuf_bytes)
          seq = PeerUpdate.Opaque.get_sequence(view) + 1
          view |> PeerUpdate.Opaque.set_sequence(seq) |> PeerUpdate.Opaque.marshal!()
        end),
        measure("elixir-protobuf", nil, false, false, fn ->
          m = PB.PeerUpdate.decode(pb_bytes)
          PB.PeerUpdate.encode(%{m | sequence: m.sequence + 1})
        end),
        measure("Jason (JSON)", nil, false, false, fn ->
          m = Jason.decode!(json_bytes)
          Jason.encode!(%{m | "sequence" => m["sequence"] + 1})
        end)
      ]),
      build_category("encode_nested_shift", "Large Embedded Message Encode", [
        measure("OmniBuf (Generated)", byte_size(gen_shift_bytes), true, true, fn ->
          PeerUpdate.encode(gen_shift)
        end),
        measure("OmniBuf (Schema DSL)", byte_size(schema_shift_bytes), true, false, fn ->
          S.PeerUpdate.encode(schema_shift)
        end),
        measure("elixir-protobuf", byte_size(pb_shift_bytes), false, false, fn ->
          PB.PeerUpdate.encode(pb_shift)
        end),
        measure("Jason (JSON)", byte_size(json_shift_bytes), false, false, fn ->
          Jason.encode!(json_shift)
        end)
      ]),
      build_category("mutate_embedded_grow", "Embedded Message Growth", [
        measure("OmniBuf (Generated)", nil, true, true, fn ->
          view = PeerUpdate.Opaque.new(routing_omnibuf_bytes)
          lv = PeerUpdate.Opaque.get_location(view)

          new_loc = %Location{
            region: Location.Opaque.get_region(lv),
            datacenter: grown_dc,
            city: Location.Opaque.get_city(lv),
            rack: Location.Opaque.get_rack(lv),
            latitude: Location.Opaque.get_latitude(lv),
            longitude: Location.Opaque.get_longitude(lv)
          }

          view |> PeerUpdate.Opaque.set_location(new_loc) |> PeerUpdate.Opaque.marshal!()
        end),
        measure("elixir-protobuf", nil, false, false, fn ->
          m = PB.PeerUpdate.decode(routing_pb_bytes)
          PB.PeerUpdate.encode(%{m | location: %{m.location | datacenter: grown_dc}})
        end),
        measure("Jason (JSON)", nil, false, false, fn ->
          m = Jason.decode!(routing_json_bytes)
          Jason.encode!(%{m | "location" => %{m["location"] | "datacenter" => grown_dc}})
        end)
      ])
    ]

    Enum.each(categories, &print_category/1)

    report = %{
      "language" => "elixir",
      "runtime" => runtime,
      "platform" => platform,
      "arch" => arch,
      "cpu" => cpu,
      "workload" => "PeerUpdate",
      "categories" => categories
    }

    File.mkdir_p!("testdata")
    File.write!("testdata/benchmarks.json", Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("\nWrote testdata/benchmarks.json")
  end

  defp build_category(id, title, results) do
    sorted = Enum.sort_by(results, & &1["nsPerOp"])

    %{
      "id" => id,
      "title" => title,
      "unit" => "ns",
      "results" => sorted
    }
  end

  defp measure(name, wire_bytes, highlight, baseline, fun) do
    # Warmup
    run_loop(fun, 200)

    # Calibrate iteration count to run for ~150ms
    {t_cal, _} = :timer.tc(fn -> run_loop(fun, 200) end)
    iters = max(200, min(500_000, div(150_000 * 200, max(t_cal, 1))))

    # Take 3 samples and keep median
    samples =
      for _ <- 1..3 do
        t0 = System.monotonic_time(:nanosecond)
        run_loop(fun, iters)
        t1 = System.monotonic_time(:nanosecond)
        div(t1 - t0, iters)
      end
      |> Enum.sort()

    ns_per_op = Enum.at(samples, 1)
    ops_per_sec = if ns_per_op > 0, do: div(1_000_000_000, ns_per_op), else: 0

    base = %{
      "name" => name,
      "nsPerOp" => ns_per_op,
      "opsPerSec" => ops_per_sec
    }

    base = if wire_bytes, do: Map.put(base, "wireBytes", wire_bytes), else: base
    base = if highlight, do: Map.put(base, "highlight", true), else: base
    if baseline, do: Map.put(base, "baseline", true), else: base
  end

  defp run_loop(_fun, 0), do: :ok

  defp run_loop(fun, n) do
    _ = fun.()
    run_loop(fun, n - 1)
  end

  defp print_category(%{"title" => title, "results" => results}) do
    baseline_ns =
      case Enum.find(results, &(&1["baseline"] == true)) do
        %{"nsPerOp" => ns} when ns > 0 -> ns
        _ -> 1
      end

    IO.puts("\n=== #{title} ===")

    IO.puts(
      String.pad_trailing("Codec", 26) <>
        String.pad_leading("ns/op", 10) <>
        String.pad_leading("ops/sec", 14) <>
        String.pad_leading("wire (B)", 10) <>
        String.pad_leading("vs OmniBuf", 12)
    )

    IO.puts(String.duplicate("-", 72))

    for r <- results do
      wire_col = if r["wireBytes"], do: Integer.to_string(r["wireBytes"]), else: "-"
      ratio = r["nsPerOp"] / baseline_ns

      rel =
        if r["baseline"],
          do: "1.00x",
          else: :io_lib.format("~.2fx", [ratio]) |> IO.iodata_to_binary()

      IO.puts(
        String.pad_trailing(r["name"], 26) <>
          String.pad_leading(Integer.to_string(r["nsPerOp"]), 10) <>
          String.pad_leading(Integer.to_string(r["opsPerSec"]), 14) <>
          String.pad_leading(wire_col, 10) <>
          String.pad_leading(rel, 12)
      )
    end
  end

  defp detect_platform do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "windows"
      {_, os} -> Atom.to_string(os)
    end
  end

  defp detect_arch do
    arch_str = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      String.contains?(arch_str, "aarch64") or String.contains?(arch_str, "arm64") -> "arm64"
      String.contains?(arch_str, "x86_64") -> "x86_64"
      true -> arch_str
    end
  end

  defp detect_cpu do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> "Unknown CPU"
        end

      _ ->
        "Unknown CPU"
    end
  rescue
    _ -> "Unknown CPU"
  end

  defp sample_generated do
    %PeerUpdate{
      asn: 64_512,
      router_id: "edge-rtr-fra01.core.backbone.net",
      active: true,
      uptime_sec: 1_849_203,
      rssi_dbm: -62,
      cpu_load: 0.42875,
      tags: ["tier1", "ebgp", "eu-central", "ixp-de-cix"],
      prefixes: [167_772_160, 172_032_000, 3_232_235_520, 2_886_729_728, 134_744_072, 134_743_040],
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
        },
        %Neighbor{
          peer_asn: 1299,
          router: "ffm-b5-link.telia.net",
          latency_us: 920,
          established: true
        },
        %Neighbor{
          peer_asn: 174,
          router: "be2040.ccr41.fra03.atlas.cogentco.com",
          latency_us: 1120,
          established: true
        },
        %Neighbor{
          peer_asn: 2914,
          router: "ae-12.r24.frnkge08.de.bb.gin.ntt.net",
          latency_us: 980,
          established: false
        }
      ],
      sequence: 9_876_543_210
    }
  end

  defp sample_schema do
    %S.PeerUpdate{
      asn: 64_512,
      router_id: "edge-rtr-fra01.core.backbone.net",
      active: true,
      uptime_sec: 1_849_203,
      rssi_dbm: -62,
      cpu_load: 0.42875,
      tags: ["tier1", "ebgp", "eu-central", "ixp-de-cix"],
      prefixes: [167_772_160, 172_032_000, 3_232_235_520, 2_886_729_728, 134_744_072, 134_743_040],
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
        },
        %S.Neighbor{
          peer_asn: 1299,
          router: "ffm-b5-link.telia.net",
          latency_us: 920,
          established: true
        },
        %S.Neighbor{
          peer_asn: 174,
          router: "be2040.ccr41.fra03.atlas.cogentco.com",
          latency_us: 1120,
          established: true
        },
        %S.Neighbor{
          peer_asn: 2914,
          router: "ae-12.r24.frnkge08.de.bb.gin.ntt.net",
          latency_us: 980,
          established: false
        }
      ],
      sequence: 9_876_543_210
    }
  end

  defp sample_pb do
    %PB.PeerUpdate{
      asn: 64_512,
      router_id: "edge-rtr-fra01.core.backbone.net",
      active: true,
      uptime_sec: 1_849_203,
      rssi_dbm: -62,
      cpu_load: 0.42875,
      tags: ["tier1", "ebgp", "eu-central", "ixp-de-cix"],
      prefixes: [167_772_160, 172_032_000, 3_232_235_520, 2_886_729_728, 134_744_072, 134_743_040],
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
        },
        %PB.Neighbor{
          peer_asn: 1299,
          router: "ffm-b5-link.telia.net",
          latency_us: 920,
          established: true
        },
        %PB.Neighbor{
          peer_asn: 174,
          router: "be2040.ccr41.fra03.atlas.cogentco.com",
          latency_us: 1120,
          established: true
        },
        %PB.Neighbor{
          peer_asn: 2914,
          router: "ae-12.r24.frnkge08.de.bb.gin.ntt.net",
          latency_us: 980,
          established: false
        }
      ],
      sequence: 9_876_543_210
    }
  end

  defp sample_json_map do
    %{
      "asn" => 64_512,
      "router_id" => "edge-rtr-fra01.core.backbone.net",
      "active" => true,
      "uptime_sec" => 1_849_203,
      "rssi_dbm" => -62,
      "cpu_load" => 0.42875,
      "tags" => ["tier1", "ebgp", "eu-central", "ixp-de-cix"],
      "prefixes" => [
        167_772_160,
        172_032_000,
        3_232_235_520,
        2_886_729_728,
        134_744_072,
        134_743_040
      ],
      "location" => %{
        "region" => "eu-central-1",
        "datacenter" => "FRA-Equinix-FR5",
        "city" => "Frankfurt",
        "rack" => 42,
        "latitude" => 50.1109,
        "longitude" => 8.6821
      },
      "neighbors" => [
        %{
          "peer_asn" => 3356,
          "router" => "ae0.fra1.level3.net",
          "latency_us" => 850,
          "established" => true
        },
        %{
          "peer_asn" => 1299,
          "router" => "ffm-b5-link.telia.net",
          "latency_us" => 920,
          "established" => true
        },
        %{
          "peer_asn" => 174,
          "router" => "be2040.ccr41.fra03.atlas.cogentco.com",
          "latency_us" => 1120,
          "established" => true
        },
        %{
          "peer_asn" => 2914,
          "router" => "ae-12.r24.frnkge08.de.bb.gin.ntt.net",
          "latency_us" => 980,
          "established" => false
        }
      ],
      "sequence" => 9_876_543_210
    }
  end
end

OmniBuf.Bench.PeerBench.run()
