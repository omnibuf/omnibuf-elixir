# OmniBuf for Elixir

Elixir implementation of the [OmniBuf v0.1](https://omnibuf.com/spec) binary wire format.

OmniBuf uses numbered Protobuf fields, 1/2/4/9-byte Prefix-Varints, distinct wire codes for all 16 scalar and container types, single-pass iodata encoding, lazy zero-decode `Opaque` views with in-place iodata wire splicing, and optional Field #0 (`SchemaMeta`) self-describing metadata.

## Installation

Add `omnibuf` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:omnibuf, "~> 0.1.0"}
  ]
end
```

Requires Elixir 1.17+ and Erlang/OTP 27+.

## Four Implementation Tiers

### Tier 1: `protoc-gen-omnibuf-elixir` Plugin & Lazy `Opaque` Views

Build the escript plugin and run `buf generate`:

```bash
mix escript.build
buf generate
```

Generated modules provide fast struct codecs and lazy `<Message>.Opaque` views that read nested fields in `O(fields)` time and splice mutations using zero-copy BEAM sub-binaries:

```elixir
alias Omnibuf.Bench.{Location, PeerUpdate}

# Zero-decode nested field read
city =
  packet
  |> PeerUpdate.Opaque.new()
  |> PeerUpdate.Opaque.get_location()
  |> Location.Opaque.get_city()

# Selective in-place wire splice (untouched fields stay raw sub-binaries)
updated =
  packet
  |> PeerUpdate.Opaque.new()
  |> PeerUpdate.Opaque.set_sequence(9_876_543_211)
  |> PeerUpdate.Opaque.marshal!()
```

### Tier 2: `elixir-protobuf` Integration

Encode and decode standard `use Protobuf` structs directly to and from OmniBuf wire bytes:

```elixir
wire = OmniBuf.encode_proto(pb_struct)
{:ok, decoded} = OmniBuf.decode_proto(wire, MyApp.PB.PeerUpdate)
```

### Tier 3: Declarative Struct DSL (`OmniBuf.Schema`)

Define OmniBuf messages directly in Elixir without `.proto` files. Compile-time macros generate specialized iodata encoders and binary pattern-matching decoders:

```elixir
defmodule MyApp.Location do
  use OmniBuf.Schema, name: "Location"

  field 1, :region, :string
  field 2, :datacenter, :string
  field 3, :city, :string
  field 4, :rack, :uint32
  field 5, :latitude, :float
  field 6, :longitude, :float
end

wire = MyApp.Location.encode(%MyApp.Location{city: "Frankfurt", rack: 42})
{:ok, loc} = MyApp.Location.decode(wire)
```

Pass `self_describing: true` to prepend Field #0 `SchemaMeta`:

```elixir
wire = MyApp.Location.encode(loc, self_describing: true)
```

### Tier 4: Schema-less Blind Decode (`OmniBuf.Blind`)

Inspect any OmniBuf packet with no compiled schema. Declared Field #0 names propagate through nested messages, arrays, and maps; unnamed fields fall back to `"field_<N>"`.

```elixir
{:ok, map} = OmniBuf.decode_blind(wire)
{:ok, json} = OmniBuf.decode_blind_json(wire)
```

## Conformance & Benchmarks

```bash
just fmt-check
just lint
just test
just conformance
just bench
```

The conformance suite passes **992 / 992** test cases across all 4 tiers (`TIER_PLUGIN`, `TIER_PROTOBUF_TYPES`, `TIER_ANNOTATED_STRUCT`, `TIER_BLIND`) with 0 failures.

## License

Apache-2.0. See [LICENSE](LICENSE).
