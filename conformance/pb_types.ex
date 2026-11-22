defmodule OmniBuf.Conformance.PB.Location do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:region, 1, type: :string)
  field(:datacenter, 2, type: :string)
  field(:city, 3, type: :string)
  field(:rack, 4, type: :uint32)
  field(:latitude, 5, type: :float)
  field(:longitude, 6, type: :float)
end

defmodule OmniBuf.Conformance.PB.Neighbor do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:peer_asn, 1, type: :uint32, json_name: "peerAsn")
  field(:router, 2, type: :string)
  field(:latency_us, 3, type: :uint32, json_name: "latencyUs")
  field(:established, 4, type: :bool)
end

defmodule OmniBuf.Conformance.PB.PeerUpdate do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:asn, 1, type: :uint32)
  field(:router_id, 2, type: :string, json_name: "routerId")
  field(:active, 3, type: :bool)
  field(:uptime_sec, 4, type: :uint64, json_name: "uptimeSec")
  field(:rssi_dbm, 5, type: :sint32, json_name: "rssiDbm")
  field(:cpu_load, 6, type: :double, json_name: "cpuLoad")
  field(:tags, 7, repeated: true, type: :string)
  field(:prefixes, 8, repeated: true, type: :uint32)
  field(:location, 9, type: OmniBuf.Conformance.PB.Location)
  field(:neighbors, 10, repeated: true, type: OmniBuf.Conformance.PB.Neighbor)
  field(:sequence, 11, type: :uint64)
end

defmodule OmniBuf.Conformance.PB.AllTypesSubMsg do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:id, 1, type: :uint32)
  field(:label, 2, type: :string)
  field(:flag, 3, type: :bool)
  field(:score, 4, type: :sint64)
end

defmodule OmniBuf.Conformance.PB.TestAllTypes.F12MapStrUintEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :uint64)
end

defmodule OmniBuf.Conformance.PB.TestAllTypes do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:f1_uint32, 1, type: :uint32)
  field(:f2_uint64, 2, type: :uint64)
  field(:f3_sint32, 3, type: :sint32)
  field(:f4_sint64, 4, type: :sint64)
  field(:f5_bool, 5, type: :bool)
  field(:f6_string, 6, type: :string)
  field(:f7_bytes, 7, type: :bytes)
  field(:f8_sub_msg, 8, type: OmniBuf.Conformance.PB.AllTypesSubMsg)
  field(:f9_string_arr, 9, repeated: true, type: :string)
  field(:f10_uint32_arr, 10, repeated: true, type: :uint32)
  field(:f11_sub_msg_arr, 11, repeated: true, type: OmniBuf.Conformance.PB.AllTypesSubMsg)

  field(:f12_map_str_uint, 12,
    repeated: true,
    type: OmniBuf.Conformance.PB.TestAllTypes.F12MapStrUintEntry,
    map: true
  )

  field(:f13_float32, 13, type: :float)
  field(:f14_float64, 14, type: :double)
  field(:f15_fixed32, 15, type: :fixed32)
  field(:f16_fixed64, 16, type: :fixed64)
  field(:f20_overflow_str, 20, type: :string)
end
