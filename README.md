# omnibuf-elixir

[![OmniBuf Spec: v1 DRAFT-1](https://img.shields.io/badge/OmniBuf%20Spec-v1%20DRAFT--1-FF4F18)](https://omnibuf.com/spec)

Elixir 1.17+ (OTP 27+) implementation of the [OmniBuf v1 DRAFT-1 wire specification](https://omnibuf.com/spec). Documentation and benchmarks live at [omnibuf.com/elixir](https://omnibuf.com/elixir).

## Install

Add `omnibuf` to `mix.exs`:

```elixir
def deps do
  [
    {:omnibuf, "~> 0.1.0"}
  ]
end
```

## Quick Usage

```elixir
defmodule MyApp.Location do
  use OmniBuf.Schema, name: "Location"

  field 1, :region, :string
  field 3, :city, :string
  field 4, :rack, :uint32
end

wire = MyApp.Location.encode(%MyApp.Location{city: "Frankfurt", rack: 42}, self_describing: true)
{:ok, loc} = MyApp.Location.decode(wire)
```

## Implementation Details

- **`OmniBuf.Schema` macro**: Compile-time DSL that generates iodata encoders and binary pattern-matching decoders directly on Elixir structs.
- **Optional Rustler NIF**: `native/omnibuf_nif` provides an optional Rustler NIF built on the Rust `omnibuf` crate.
- **`protobuf` interop**: `OmniBuf.encode_proto/2` and `OmniBuf.decode_proto/2` handle standard `use Protobuf` structs.
- **Codegen**: `protoc-gen-omnibuf-elixir` (`mix escript.build`) generates struct codecs and lazy `<Message>.Opaque` views with zero-copy BEAM sub-binary splicing.
- **Blind decode**: `OmniBuf.decode_blind/1` and `OmniBuf.decode_blind_json/1` inspect packets using `Field #0` names or `field_<N>` fallbacks.

## Development

```bash
just test && just conformance
```

## License

Apache-2.0. See [LICENSE](./LICENSE).
