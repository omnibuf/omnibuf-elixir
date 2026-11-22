defmodule OmniBuf.Conformance.IPC.Request do
  @moduledoc false
  use OmniBuf.Schema, name: "ConformanceRequest"

  field(1, :test_name, :string)
  field(2, :message_type, :string)
  field(3, :tier, :uint32)
  field(4, :requested_output_format, :uint32)
  field(5, :omnibuf_payload, :bytes)
  field(6, :json_payload, :string)
  field(7, :self_describing, :bool)
  field(8, :test_opaque_splice, :bool)
  field(9, :test_opaque_splice_shrink, :bool)
end

defmodule OmniBuf.Conformance.IPC.Response do
  @moduledoc false
  use OmniBuf.Schema, name: "ConformanceResponse"

  field(1, :parse_error, :string)
  field(2, :serialize_error, :string)
  field(3, :runtime_error, :string)
  field(4, :skipped, :string)
  field(5, :omnibuf_payload, :bytes)
  field(6, :json_payload, :string)
end

defmodule OmniBuf.Conformance.Struct.Location do
  @moduledoc false
  use OmniBuf.Schema, name: "Location"

  field(1, :region, :string)
  field(2, :datacenter, :string)
  field(3, :city, :string)
  field(4, :rack, :uint32)
  field(5, :latitude, :float)
  field(6, :longitude, :float)
end

defmodule OmniBuf.Conformance.Struct.Neighbor do
  @moduledoc false
  use OmniBuf.Schema, name: "Neighbor"

  field(1, :peer_asn, :uint32)
  field(2, :router, :string)
  field(3, :latency_us, :uint32)
  field(4, :established, :bool)
end

defmodule OmniBuf.Conformance.Struct.PeerUpdate do
  @moduledoc false
  use OmniBuf.Schema, name: "PeerUpdate"

  field(1, :asn, :uint32)
  field(2, :router_id, :string)
  field(3, :active, :bool)
  field(4, :uptime_sec, :uint64)
  field(5, :rssi_dbm, :sint32)
  field(6, :cpu_load, :double)
  field(7, :tags, {:array, :string})
  field(8, :prefixes, {:array, :uint32})
  field(9, :location, OmniBuf.Conformance.Struct.Location)
  field(10, :neighbors, {:array, OmniBuf.Conformance.Struct.Neighbor})
  field(11, :sequence, :uint64)
end

defmodule OmniBuf.Conformance.Struct.AllTypesSubMsg do
  @moduledoc false
  use OmniBuf.Schema, name: "AllTypesSubMsg"

  field(1, :id, :uint32)
  field(2, :label, :string)
  field(3, :flag, :bool)
  field(4, :score, :sint64)
end

defmodule OmniBuf.Conformance.Struct.TestAllTypes do
  @moduledoc false
  use OmniBuf.Schema, name: "TestAllTypes"

  field(1, :f1_uint32, :uint32)
  field(2, :f2_uint64, :uint64)
  field(3, :f3_sint32, :sint32)
  field(4, :f4_sint64, :sint64)
  field(5, :f5_bool, :bool)
  field(6, :f6_string, :string)
  field(7, :f7_bytes, :bytes)
  field(8, :f8_sub_msg, OmniBuf.Conformance.Struct.AllTypesSubMsg)
  field(9, :f9_string_arr, {:array, :string})
  field(10, :f10_uint32_arr, {:array, :uint32})
  field(11, :f11_sub_msg_arr, {:array, OmniBuf.Conformance.Struct.AllTypesSubMsg})
  field(12, :f12_map_str_uint, {:map, :string, :uint64})
  field(13, :f13_float32, :float)
  field(14, :f14_float64, :double)
  field(15, :f15_fixed32, :fixed32)
  field(16, :f16_fixed64, :fixed64)
  field(20, :f20_overflow_str, :string)
end

defmodule OmniBuf.Conformance.Struct.TreeNode do
  @moduledoc false
  use OmniBuf.Schema, name: "TreeNode"

  field(1, :id, :uint32)
  field(2, :name, :string)
  field(3, :weight, :sint64)
  field(4, :primary, OmniBuf.Conformance.Struct.TreeNode)
  field(5, :children, {:array, OmniBuf.Conformance.Struct.TreeNode}, emit_empty: true)
  field(6, :branches, {:array, OmniBuf.Conformance.Struct.TreeNode}, emit_empty: true)
  field(7, :labels, {:map, :string, :uint64}, emit_empty: true)
end

defmodule OmniBuf.Conformance.Struct.NestedNIC do
  @moduledoc false
  use OmniBuf.Schema, name: "NestedNIC"

  field(1, :if_index, :uint32)
  field(2, :mac, :string)
  field(3, :ips, {:array, :uint32})
end

defmodule OmniBuf.Conformance.Struct.NestedServer do
  @moduledoc false
  use OmniBuf.Schema, name: "NestedServer"

  field(1, :server_id, :uint32)
  field(2, :hostname, :string)
  field(3, :nics, {:array, OmniBuf.Conformance.Struct.NestedNIC})
end

defmodule OmniBuf.Conformance.Struct.NestedRack do
  @moduledoc false
  use OmniBuf.Schema, name: "NestedRack"

  field(1, :rack_id, :uint32)
  field(2, :zone, :string)
  field(3, :servers, {:array, OmniBuf.Conformance.Struct.NestedServer})
end

defmodule OmniBuf.Conformance.Struct.NestedCluster do
  @moduledoc false
  use OmniBuf.Schema, name: "NestedCluster"

  field(1, :cluster_name, :string)
  field(2, :racks, {:array, OmniBuf.Conformance.Struct.NestedRack})
  field(3, :epoch, :uint64)
end
