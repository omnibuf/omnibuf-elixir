use std::collections::{HashMap, HashSet};

use omnibuf::field0::validate_field0;
use omnibuf::wire::{
    MAX_FIELD_NUMBER, MAX_NESTING_DEPTH, WIRE_ARRAY, WIRE_BOOL_FALSE, WIRE_BOOL_TRUE, WIRE_BYTES,
    WIRE_FIXED32, WIRE_FIXED64, WIRE_FLOAT32, WIRE_FLOAT64, WIRE_MAP, WIRE_SFIXED32, WIRE_SFIXED64,
    WIRE_SINT, WIRE_STRING, WIRE_SUB_MSG, WIRE_UINT, append_bytes_elem, append_tag, append_varint,
    decode_varint, decode_zigzag, encode_zigzag, parse_array_header, parse_map_header,
    patch_reserved_varint, read_len_slice, read_str_slice, read_tag_at, validate_value,
};
use rustler::types::atom::Atom;
use rustler::types::list::ListIterator;
use rustler::types::map::MapIterator;
use rustler::{Binary, Encoder, Env, NewBinary, NifResult, Term};

use crate::atoms;

pub const DEFAULT_MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;
pub const DEFAULT_MAX_ELEMENTS: usize = 4_194_304;

pub struct DecodeBudget {
    pub max_elements: usize,
    pub elements: usize,
}

impl DecodeBudget {
    #[inline]
    pub fn new(max_elements: usize) -> Self {
        Self {
            max_elements,
            elements: 0,
        }
    }

    #[inline]
    pub fn add_elements(&mut self, count: usize) -> Result<(), DecodeErr> {
        self.elements = self.elements.checked_add(count).ok_or_else(|| {
            DecodeErr::new(
                atoms::element_limit_exceeded(),
                "cumulative element count overflow",
            )
        })?;
        if self.elements > self.max_elements {
            return Err(DecodeErr::new(
                atoms::element_limit_exceeded(),
                format!(
                    "cumulative element count {} exceeds limit {}",
                    self.elements, self.max_elements
                ),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub enum ElemKind {
    Uint32,
    Uint64,
    Sint32,
    Sint64,
    Bool,
    Fixed32,
    Fixed64,
    Sfixed32,
    Sfixed64,
    Float32,
    Float64,
    String,
    Bytes,
    Message(usize),
    Array(Box<ElemKind>),
    Map(Box<ElemKind>, Box<ElemKind>),
}

impl ElemKind {
    #[inline]
    pub fn wire_type(&self) -> u8 {
        match self {
            ElemKind::Uint32 | ElemKind::Uint64 => WIRE_UINT,
            ElemKind::Sint32 | ElemKind::Sint64 => WIRE_SINT,
            ElemKind::Bool => WIRE_BOOL_FALSE,
            ElemKind::Fixed32 => WIRE_FIXED32,
            ElemKind::Fixed64 => WIRE_FIXED64,
            ElemKind::Sfixed32 => WIRE_SFIXED32,
            ElemKind::Sfixed64 => WIRE_SFIXED64,
            ElemKind::Float32 => WIRE_FLOAT32,
            ElemKind::Float64 => WIRE_FLOAT64,
            ElemKind::String => WIRE_STRING,
            ElemKind::Bytes => WIRE_BYTES,
            ElemKind::Message(_) => WIRE_SUB_MSG,
            ElemKind::Array(_) => WIRE_ARRAY,
            ElemKind::Map(_, _) => WIRE_MAP,
        }
    }
}

pub struct FieldDesc {
    pub number: u32,
    pub name_atom: Atom,
    pub tag_bytes: [u8; 9],
    pub tag_len: u8,
    pub tag_true_bytes: [u8; 9],
    pub tag_true_len: u8,
    pub emit_empty: bool,
    pub kind: ElemKind,
}

pub struct MessageSchema {
    pub struct_atom: Atom,
    pub fields: Vec<FieldDesc>,
    pub fast_fields: [u16; 64],
    pub overflow_fields: HashMap<u32, u16>,
    pub struct_keys: Vec<Atom>,
}

pub struct CompiledSchema {
    pub messages: Vec<MessageSchema>,
}

// Safety: `Atom` in Rustler is a globally immutable BEAM atom term valid for the
// lifetime of the VM across all scheduler threads.
unsafe impl Send for CompiledSchema {}
unsafe impl Sync for CompiledSchema {}

#[rustler::resource_impl]
impl rustler::Resource for CompiledSchema {}

#[derive(Debug)]
pub struct DecodeErr {
    pub reason: Atom,
    pub message: String,
}

impl DecodeErr {
    #[inline]
    pub fn new(reason: Atom, message: impl Into<String>) -> Self {
        Self {
            reason,
            message: message.into(),
        }
    }

    pub fn from_omnibuf(err: omnibuf::Error) -> Self {
        match err {
            omnibuf::Error::InvalidUtf8 => {
                Self::new(atoms::invalid_utf8(), "WireString contains invalid UTF-8")
            }
            omnibuf::Error::DepthLimitExceeded(d) => Self::new(
                atoms::max_depth_exceeded(),
                format!("max container depth {MAX_NESTING_DEPTH} exceeded at {d}"),
            ),
            omnibuf::Error::Parse(msg) => {
                let reason = classify_parse_error(&msg);
                Self::new(reason, msg)
            }
            omnibuf::Error::Serialize(msg) => Self::new(atoms::serialize(), msg),
        }
    }
}

pub fn classify_parse_error(msg: &str) -> Atom {
    if msg.contains("UTF-8") || msg.contains("utf-8") {
        atoms::invalid_utf8()
    } else if msg.contains("depth") {
        atoms::max_depth_exceeded()
    } else if msg.contains("trailing") || msg.contains("invalid WireArray header") {
        atoms::trailing_bytes()
    } else if msg.contains("Field #0") || msg.contains("field #0") {
        atoms::invalid_field_zero()
    } else if msg.contains("reserved") {
        atoms::reserved_varint_prefix()
    } else if msg.contains("mismatch") {
        atoms::collection_type_mismatch()
    } else {
        atoms::parse_error()
    }
}

fn encode_tag_arr(field_num: u32, wt: u8) -> ([u8; 9], u8) {
    let mut tmp = Vec::with_capacity(9);
    append_tag(&mut tmp, field_num, wt);
    let mut arr = [0u8; 9];
    let len = tmp.len();
    arr[..len].copy_from_slice(&tmp[..len]);
    (arr, len as u8)
}

fn parse_elem_kind<'a>(term: Term<'a>, depth: usize) -> NifResult<ElemKind> {
    if depth > MAX_NESTING_DEPTH {
        return Err(rustler::Error::BadArg);
    }

    if let Ok(a) = term.decode::<Atom>() {
        if a == atoms::uint32() {
            return Ok(ElemKind::Uint32);
        } else if a == atoms::uint64() {
            return Ok(ElemKind::Uint64);
        } else if a == atoms::int32() || a == atoms::sint32() || a == atoms::r#enum() {
            return Ok(ElemKind::Sint32);
        } else if a == atoms::int64() || a == atoms::sint64() {
            return Ok(ElemKind::Sint64);
        } else if a == atoms::bool() {
            return Ok(ElemKind::Bool);
        } else if a == atoms::fixed32() {
            return Ok(ElemKind::Fixed32);
        } else if a == atoms::fixed64() {
            return Ok(ElemKind::Fixed64);
        } else if a == atoms::sfixed32() {
            return Ok(ElemKind::Sfixed32);
        } else if a == atoms::sfixed64() {
            return Ok(ElemKind::Sfixed64);
        } else if a == atoms::float() {
            return Ok(ElemKind::Float32);
        } else if a == atoms::double() {
            return Ok(ElemKind::Float64);
        } else if a == atoms::string() {
            return Ok(ElemKind::String);
        } else if a == atoms::bytes() {
            return Ok(ElemKind::Bytes);
        }
        return Err(rustler::Error::BadArg);
    }

    if let Ok((tag, inner)) = term.decode::<(Atom, Term<'a>)>() {
        if tag == atoms::message() {
            let idx: usize = inner.decode()?;
            return Ok(ElemKind::Message(idx));
        } else if tag == atoms::array() {
            if depth + 1 > MAX_NESTING_DEPTH {
                return Err(rustler::Error::BadArg);
            }
            let elem = parse_elem_kind(inner, depth + 1)?;
            return Ok(ElemKind::Array(Box::new(elem)));
        } else if tag == atoms::r#enum() {
            return Ok(ElemKind::Sint32);
        }
        return Err(rustler::Error::BadArg);
    }

    if let Ok((tag, k_term, v_term)) = term.decode::<(Atom, Term<'a>, Term<'a>)>() {
        if tag == atoms::map() {
            if depth + 1 > MAX_NESTING_DEPTH {
                return Err(rustler::Error::BadArg);
            }
            let k = parse_elem_kind(k_term, depth + 1)?;
            let v = parse_elem_kind(v_term, depth + 1)?;
            return Ok(ElemKind::Map(Box::new(k), Box::new(v)));
        }
        return Err(rustler::Error::BadArg);
    }

    Err(rustler::Error::BadArg)
}

fn validate_elem_kind(kind: &ElemKind, msg_count: usize) -> NifResult<()> {
    match kind {
        ElemKind::Message(idx) => {
            if *idx >= msg_count {
                return Err(rustler::Error::BadArg);
            }
            Ok(())
        }
        ElemKind::Array(inner) => validate_elem_kind(inner, msg_count),
        ElemKind::Map(k, v) => {
            validate_elem_kind(k, msg_count)?;
            validate_elem_kind(v, msg_count)
        }
        _ => Ok(()),
    }
}

/// Compiles a list of message descriptors `[{struct_mod_atom, [{num, name_atom, kind, emit_empty}]}]`
/// into a `CompiledSchema` resource.
pub fn compile_schema_from_term<'a>(msg_list: Term<'a>) -> NifResult<CompiledSchema> {
    let iter: ListIterator<'a> = msg_list.decode()?;
    let mut messages = Vec::new();

    for msg_term in iter {
        let (struct_atom, fields_term): (Atom, Term<'a>) = msg_term.decode()?;
        let field_iter: ListIterator<'a> = fields_term.decode()?;

        let mut fields = Vec::new();
        let mut fast_fields = [u16::MAX; 64];
        let mut overflow_fields = HashMap::new();
        let mut seen_numbers = HashSet::new();
        let mut seen_names = HashSet::new();
        let mut struct_keys = Vec::new();
        struct_keys.push(atoms::__struct__());

        for f_term in field_iter {
            if fields.len() >= u16::MAX as usize {
                return Err(rustler::Error::BadArg);
            }
            let (number, name_atom, kind_term, emit_empty): (u32, Atom, Term<'a>, bool) =
                f_term.decode()?;
            if number == 0 || u64::from(number) > MAX_FIELD_NUMBER {
                return Err(rustler::Error::BadArg);
            }
            if name_atom == atoms::__struct__() {
                return Err(rustler::Error::BadArg);
            }
            if !seen_numbers.insert(number) {
                return Err(rustler::Error::BadArg);
            }
            if !seen_names.insert(name_atom) {
                return Err(rustler::Error::BadArg);
            }
            let kind = parse_elem_kind(kind_term, 0)?;
            let wt = kind.wire_type();
            let (tag_bytes, tag_len) = encode_tag_arr(number, wt);
            let (tag_true_bytes, tag_true_len) = if matches!(kind, ElemKind::Bool) {
                encode_tag_arr(number, WIRE_BOOL_TRUE)
            } else {
                ([0u8; 9], 0)
            };

            let idx = fields.len() as u16;
            if (number as usize) < 64 {
                fast_fields[number as usize] = idx;
            } else {
                overflow_fields.insert(number, idx);
            }

            struct_keys.push(name_atom);
            fields.push(FieldDesc {
                number,
                name_atom,
                tag_bytes,
                tag_len,
                tag_true_bytes,
                tag_true_len,
                emit_empty,
                kind,
            });
        }

        messages.push(MessageSchema {
            struct_atom,
            fields,
            fast_fields,
            overflow_fields,
            struct_keys,
        });
    }

    if messages.is_empty() {
        return Err(rustler::Error::BadArg);
    }

    let msg_count = messages.len();
    for msg in &messages {
        for f in &msg.fields {
            validate_elem_kind(&f.kind, msg_count)?;
        }
    }

    Ok(CompiledSchema { messages })
}

// ---------------------------------------------------------------------------
// Fast Struct Encoding (BEAM term -> Vec<u8> -> Binary)
// ---------------------------------------------------------------------------

#[inline]
fn decode_u64_narrow(term: Term<'_>) -> NifResult<u64> {
    if let Ok(u) = term.decode::<u64>() {
        Ok(u)
    } else if let Ok(i) = term.decode::<i64>() {
        Ok(i as u64)
    } else {
        Err(rustler::Error::BadArg)
    }
}

#[inline]
fn decode_i64_narrow(term: Term<'_>) -> NifResult<i64> {
    if let Ok(i) = term.decode::<i64>() {
        Ok(i)
    } else if let Ok(u) = term.decode::<u64>() {
        Ok(u as i64)
    } else {
        Err(rustler::Error::BadArg)
    }
}

#[inline]
fn decode_f32_bits(term: Term<'_>) -> NifResult<u32> {
    if let Ok(f) = term.decode::<f64>() {
        return Ok((f as f32).to_bits());
    }
    if let Ok(i) = term.decode::<i64>() {
        return Ok((i as f32).to_bits());
    }
    if let Ok(u) = term.decode::<u64>() {
        return Ok((u as f32).to_bits());
    }
    if let Ok(a) = term.decode::<Atom>() {
        if a == atoms::infinity() {
            return Ok(0x7F80_0000);
        } else if a == atoms::neg_infinity() {
            return Ok(0xFF80_0000);
        } else if a == atoms::nan() {
            return Ok(0x7FC0_0000);
        }
    }
    Err(rustler::Error::BadArg)
}

#[inline]
fn decode_f64_bits(term: Term<'_>) -> NifResult<u64> {
    if let Ok(f) = term.decode::<f64>() {
        return Ok(f.to_bits());
    }
    if let Ok(i) = term.decode::<i64>() {
        return Ok((i as f64).to_bits());
    }
    if let Ok(u) = term.decode::<u64>() {
        return Ok((u as f64).to_bits());
    }
    if let Ok(a) = term.decode::<Atom>() {
        if a == atoms::infinity() {
            return Ok(0x7FF0_0000_0000_0000);
        } else if a == atoms::neg_infinity() {
            return Ok(0xFFF0_0000_0000_0000);
        } else if a == atoms::nan() {
            return Ok(0x7FF8_0000_0000_0000);
        }
    }
    Err(rustler::Error::BadArg)
}

#[inline]
fn is_nil(term: Term<'_>) -> bool {
    matches!(term.decode::<Atom>(), Ok(a) if a == atoms::nil())
}

pub fn encode_message<'a>(
    schema: &CompiledSchema,
    msg_idx: usize,
    msg_term: Term<'a>,
    dst: &mut Vec<u8>,
    depth: usize,
) -> NifResult<()> {
    if depth > MAX_NESTING_DEPTH {
        return Err(rustler::Error::BadArg);
    }
    let msg_schema = &schema.messages[msg_idx];

    for f in &msg_schema.fields {
        let val = msg_term.map_get(f.name_atom)?;
        let tag = &f.tag_bytes[..f.tag_len as usize];

        match &f.kind {
            ElemKind::Bool => {
                if val.decode::<bool>()? {
                    dst.extend_from_slice(&f.tag_true_bytes[..f.tag_true_len as usize]);
                }
            }
            ElemKind::Uint32 => {
                let v = decode_u64_narrow(val)? as u32;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    append_varint(dst, u64::from(v));
                }
            }
            ElemKind::Uint64 => {
                let v = decode_u64_narrow(val)?;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    append_varint(dst, v);
                }
            }
            ElemKind::Sint32 => {
                let v = decode_i64_narrow(val)? as i32;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    append_varint(dst, encode_zigzag(i64::from(v)));
                }
            }
            ElemKind::Sint64 => {
                let v = decode_i64_narrow(val)?;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    append_varint(dst, encode_zigzag(v));
                }
            }
            ElemKind::Fixed32 => {
                let v = decode_u64_narrow(val)? as u32;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    dst.extend_from_slice(&v.to_le_bytes());
                }
            }
            ElemKind::Fixed64 => {
                let v = decode_u64_narrow(val)?;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    dst.extend_from_slice(&v.to_le_bytes());
                }
            }
            ElemKind::Sfixed32 => {
                let v = decode_i64_narrow(val)? as i32;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    dst.extend_from_slice(&v.to_le_bytes());
                }
            }
            ElemKind::Sfixed64 => {
                let v = decode_i64_narrow(val)?;
                if v != 0 {
                    dst.extend_from_slice(tag);
                    dst.extend_from_slice(&v.to_le_bytes());
                }
            }
            ElemKind::Float32 => {
                let bits = decode_f32_bits(val)?;
                if bits != 0 {
                    dst.extend_from_slice(tag);
                    dst.extend_from_slice(&bits.to_le_bytes());
                }
            }
            ElemKind::Float64 => {
                let bits = decode_f64_bits(val)?;
                if bits != 0 {
                    dst.extend_from_slice(tag);
                    dst.extend_from_slice(&bits.to_le_bytes());
                }
            }
            ElemKind::String | ElemKind::Bytes => {
                let bin: Binary<'a> = val.decode()?;
                let slice = bin.as_slice();
                if !slice.is_empty() {
                    dst.extend_from_slice(tag);
                    append_bytes_elem(dst, slice);
                }
            }
            ElemKind::Message(sub_idx) => {
                if !is_nil(val) {
                    if depth + 1 > MAX_NESTING_DEPTH {
                        return Err(rustler::Error::BadArg);
                    }
                    dst.extend_from_slice(tag);
                    let len_pos = dst.len();
                    dst.push(0);
                    encode_message(schema, *sub_idx, val, dst, depth + 1)?;
                    let sub_len = dst.len() - (len_pos + 1);
                    patch_reserved_varint(dst, len_pos, sub_len as u64);
                }
            }
            ElemKind::Array(elem_kind) => {
                let list_len = val.list_length()?;
                if list_len > 0 || f.emit_empty {
                    if depth + 1 > MAX_NESTING_DEPTH {
                        return Err(rustler::Error::BadArg);
                    }
                    dst.extend_from_slice(tag);
                    encode_array_body(schema, elem_kind, val, list_len, dst, depth + 1)?;
                }
            }
            ElemKind::Map(k_kind, v_kind) => {
                let map_len = val.map_size()?;
                if map_len > 0 || f.emit_empty {
                    if depth + 1 > MAX_NESTING_DEPTH {
                        return Err(rustler::Error::BadArg);
                    }
                    dst.extend_from_slice(tag);
                    encode_map_body(schema, k_kind, v_kind, val, map_len, dst, depth + 1)?;
                }
            }
        }
    }

    Ok(())
}

fn encode_array_body<'a>(
    schema: &CompiledSchema,
    elem_kind: &ElemKind,
    list_term: Term<'a>,
    list_len: usize,
    dst: &mut Vec<u8>,
    depth: usize,
) -> NifResult<()> {
    let len_pos = dst.len();
    dst.push(0);
    dst.push(elem_kind.wire_type());
    append_varint(dst, list_len as u64);

    let iter: ListIterator<'a> = list_term.decode()?;
    for item in iter {
        encode_element(schema, elem_kind, item, dst, depth)?;
    }

    let body_len = dst.len() - (len_pos + 1);
    patch_reserved_varint(dst, len_pos, body_len as u64);
    Ok(())
}

fn encode_map_body<'a>(
    schema: &CompiledSchema,
    k_kind: &ElemKind,
    v_kind: &ElemKind,
    map_term: Term<'a>,
    map_len: usize,
    dst: &mut Vec<u8>,
    depth: usize,
) -> NifResult<()> {
    let len_pos = dst.len();
    dst.push(0);
    dst.push(k_kind.wire_type());
    dst.push(v_kind.wire_type());
    append_varint(dst, map_len as u64);

    if map_len > 0 {
        let iter = MapIterator::new(map_term).ok_or(rustler::Error::BadArg)?;
        match k_kind {
            ElemKind::String => {
                let mut pairs: Vec<(Binary<'a>, Term<'a>)> = Vec::with_capacity(map_len);
                for (k, v) in iter {
                    pairs.push((k.decode()?, v));
                }
                pairs.sort_unstable_by(|a, b| a.0.as_slice().cmp(b.0.as_slice()));
                for (k, v) in pairs {
                    append_bytes_elem(dst, k.as_slice());
                    encode_element(schema, v_kind, v, dst, depth)?;
                }
            }
            ElemKind::Uint32 | ElemKind::Fixed32 => {
                let mut pairs: Vec<(u32, Term<'a>)> = Vec::with_capacity(map_len);
                for (k, v) in iter {
                    pairs.push((decode_u64_narrow(k)? as u32, v));
                }
                pairs.sort_unstable_by_key(|p| p.0);
                for (k, v) in pairs {
                    match k_kind {
                        ElemKind::Uint32 => append_varint(dst, u64::from(k)),
                        ElemKind::Fixed32 => dst.extend_from_slice(&k.to_le_bytes()),
                        _ => unreachable!(),
                    }
                    encode_element(schema, v_kind, v, dst, depth)?;
                }
            }
            ElemKind::Uint64 | ElemKind::Fixed64 => {
                let mut pairs: Vec<(u64, Term<'a>)> = Vec::with_capacity(map_len);
                for (k, v) in iter {
                    pairs.push((decode_u64_narrow(k)?, v));
                }
                pairs.sort_unstable_by_key(|p| p.0);
                for (k, v) in pairs {
                    match k_kind {
                        ElemKind::Uint64 => append_varint(dst, k),
                        ElemKind::Fixed64 => dst.extend_from_slice(&k.to_le_bytes()),
                        _ => unreachable!(),
                    }
                    encode_element(schema, v_kind, v, dst, depth)?;
                }
            }
            ElemKind::Sint32 | ElemKind::Sfixed32 => {
                let mut pairs: Vec<(i32, Term<'a>)> = Vec::with_capacity(map_len);
                for (k, v) in iter {
                    pairs.push((decode_i64_narrow(k)? as i32, v));
                }
                pairs.sort_unstable_by_key(|p| p.0);
                for (k, v) in pairs {
                    match k_kind {
                        ElemKind::Sint32 => append_varint(dst, encode_zigzag(i64::from(k))),
                        ElemKind::Sfixed32 => dst.extend_from_slice(&k.to_le_bytes()),
                        _ => unreachable!(),
                    }
                    encode_element(schema, v_kind, v, dst, depth)?;
                }
            }
            ElemKind::Sint64 | ElemKind::Sfixed64 => {
                let mut pairs: Vec<(i64, Term<'a>)> = Vec::with_capacity(map_len);
                for (k, v) in iter {
                    pairs.push((decode_i64_narrow(k)?, v));
                }
                pairs.sort_unstable_by_key(|p| p.0);
                for (k, v) in pairs {
                    match k_kind {
                        ElemKind::Sint64 => append_varint(dst, encode_zigzag(k)),
                        ElemKind::Sfixed64 => dst.extend_from_slice(&k.to_le_bytes()),
                        _ => unreachable!(),
                    }
                    encode_element(schema, v_kind, v, dst, depth)?;
                }
            }
            ElemKind::Bool => {
                let mut pairs: Vec<(bool, Term<'a>)> = Vec::with_capacity(map_len);
                for (k, v) in iter {
                    pairs.push((k.decode()?, v));
                }
                pairs.sort_unstable_by_key(|p| p.0);
                for (k, v) in pairs {
                    dst.push(if k { 1 } else { 0 });
                    encode_element(schema, v_kind, v, dst, depth)?;
                }
            }
            _ => return Err(rustler::Error::BadArg),
        }
    }

    let body_len = dst.len() - (len_pos + 1);
    patch_reserved_varint(dst, len_pos, body_len as u64);
    Ok(())
}

fn encode_element<'a>(
    schema: &CompiledSchema,
    kind: &ElemKind,
    val: Term<'a>,
    dst: &mut Vec<u8>,
    depth: usize,
) -> NifResult<()> {
    match kind {
        ElemKind::Uint32 => {
            let v = decode_u64_narrow(val)? as u32;
            append_varint(dst, u64::from(v));
        }
        ElemKind::Uint64 => {
            append_varint(dst, decode_u64_narrow(val)?);
        }
        ElemKind::Sint32 => {
            let v = decode_i64_narrow(val)? as i32;
            append_varint(dst, encode_zigzag(i64::from(v)));
        }
        ElemKind::Sint64 => {
            append_varint(dst, encode_zigzag(decode_i64_narrow(val)?));
        }
        ElemKind::Bool => {
            dst.push(if val.decode::<bool>()? { 1 } else { 0 });
        }
        ElemKind::Fixed32 => {
            let v = decode_u64_narrow(val)? as u32;
            dst.extend_from_slice(&v.to_le_bytes());
        }
        ElemKind::Fixed64 => {
            let v = decode_u64_narrow(val)?;
            dst.extend_from_slice(&v.to_le_bytes());
        }
        ElemKind::Sfixed32 => {
            let v = decode_i64_narrow(val)? as i32;
            dst.extend_from_slice(&v.to_le_bytes());
        }
        ElemKind::Sfixed64 => {
            let v = decode_i64_narrow(val)?;
            dst.extend_from_slice(&v.to_le_bytes());
        }
        ElemKind::Float32 => {
            let bits = decode_f32_bits(val)?;
            dst.extend_from_slice(&bits.to_le_bytes());
        }
        ElemKind::Float64 => {
            let bits = decode_f64_bits(val)?;
            dst.extend_from_slice(&bits.to_le_bytes());
        }
        ElemKind::String | ElemKind::Bytes => {
            let bin: Binary<'a> = val.decode()?;
            append_bytes_elem(dst, bin.as_slice());
        }
        ElemKind::Message(sub_idx) => {
            if is_nil(val) {
                dst.push(0x01);
            } else {
                if depth + 1 > MAX_NESTING_DEPTH {
                    return Err(rustler::Error::BadArg);
                }
                let len_pos = dst.len();
                dst.push(0);
                encode_message(schema, *sub_idx, val, dst, depth + 1)?;
                let sub_len = dst.len() - (len_pos + 1);
                patch_reserved_varint(dst, len_pos, sub_len as u64);
            }
        }
        ElemKind::Array(inner) => {
            if depth + 1 > MAX_NESTING_DEPTH {
                return Err(rustler::Error::BadArg);
            }
            let list_len = val.list_length()?;
            encode_array_body(schema, inner, val, list_len, dst, depth + 1)?;
        }
        ElemKind::Map(k_kind, v_kind) => {
            if depth + 1 > MAX_NESTING_DEPTH {
                return Err(rustler::Error::BadArg);
            }
            let map_len = val.map_size()?;
            encode_map_body(schema, k_kind, v_kind, val, map_len, dst, depth + 1)?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Fast Struct Decoding (Binary -> BEAM struct)
// ---------------------------------------------------------------------------

#[inline]
fn make_bytes_term<'a>(env: Env<'a>, slice: &[u8]) -> Term<'a> {
    let mut bin = NewBinary::new(env, slice.len());
    bin.as_mut_slice().copy_from_slice(slice);
    bin.into()
}

#[inline]
fn make_f32_term<'a>(env: Env<'a>, bits: u32) -> Term<'a> {
    let f = f32::from_bits(bits);
    if f.is_finite() {
        f64::from(f).encode(env)
    } else if bits == 0x7F80_0000 {
        atoms::infinity().encode(env)
    } else if bits == 0xFF80_0000 {
        atoms::neg_infinity().encode(env)
    } else {
        atoms::nan().encode(env)
    }
}

#[inline]
fn make_f64_term<'a>(env: Env<'a>, bits: u64) -> Term<'a> {
    let f = f64::from_bits(bits);
    if f.is_finite() {
        f.encode(env)
    } else if bits == 0x7FF0_0000_0000_0000 {
        atoms::infinity().encode(env)
    } else if bits == 0xFFF0_0000_0000_0000 {
        atoms::neg_infinity().encode(env)
    } else {
        atoms::nan().encode(env)
    }
}

#[inline]
fn default_term<'a>(env: Env<'a>, kind: &ElemKind) -> Term<'a> {
    match kind {
        ElemKind::Uint32
        | ElemKind::Uint64
        | ElemKind::Sint32
        | ElemKind::Sint64
        | ElemKind::Fixed32
        | ElemKind::Fixed64
        | ElemKind::Sfixed32
        | ElemKind::Sfixed64 => 0i64.encode(env),
        ElemKind::Bool => false.encode(env),
        ElemKind::Float32 | ElemKind::Float64 => 0.0f64.encode(env),
        ElemKind::String | ElemKind::Bytes => make_bytes_term(env, &[]),
        ElemKind::Message(_) => atoms::nil().encode(env),
        ElemKind::Array(_) => Vec::<Term<'a>>::new().encode(env),
        ElemKind::Map(_, _) => Term::map_new(env),
    }
}

pub fn decode_message<'a>(
    env: Env<'a>,
    schema: &CompiledSchema,
    msg_idx: usize,
    raw: &[u8],
    existing: Option<Term<'a>>,
    depth: usize,
    budget: &mut DecodeBudget,
) -> Result<Term<'a>, DecodeErr> {
    if depth == 0 && raw.len() > DEFAULT_MAX_MESSAGE_BYTES {
        return Err(DecodeErr::new(
            atoms::message_too_large(),
            format!(
                "packet size {} exceeds {}",
                raw.len(),
                DEFAULT_MAX_MESSAGE_BYTES
            ),
        ));
    }

    let msg_schema = &schema.messages[msg_idx];
    let n_fields = msg_schema.fields.len();

    let mut vals: Vec<Term<'a>> = Vec::with_capacity(n_fields + 1);
    vals.push(msg_schema.struct_atom.encode(env));

    if let Some(ex) = existing {
        for f in &msg_schema.fields {
            let v = ex
                .map_get(f.name_atom)
                .unwrap_or_else(|_| default_term(env, &f.kind));
            vals.push(v);
        }
    } else {
        for f in &msg_schema.fields {
            vals.push(default_term(env, &f.kind));
        }
    }

    let mut array_acc: Option<Vec<Option<Vec<Term<'a>>>>> = None;

    let len = raw.len();
    let mut pos = 0usize;

    while pos < len {
        let Some((fnum, wt, after_tag)) = read_tag_at(raw, pos) else {
            return Err(DecodeErr::new(
                atoms::parse_error(),
                format!("invalid or truncated tag at {pos}"),
            ));
        };
        pos = after_tag;

        if fnum == 0 {
            if wt != WIRE_SUB_MSG {
                return Err(DecodeErr::new(
                    atoms::invalid_field_zero(),
                    format!("Field #0 must have WireSubMsg (12), got {wt}"),
                ));
            }
            pos = validate_field0(raw, pos, depth).map_err(DecodeErr::from_omnibuf)?;
            continue;
        }

        let field_idx_opt = if (fnum as usize) < 64 {
            let idx = msg_schema.fast_fields[fnum as usize];
            if idx == u16::MAX { None } else { Some(idx as usize) }
        } else {
            msg_schema.overflow_fields.get(&fnum).map(|&i| i as usize)
        };

        let Some(fi) = field_idx_opt else {
            pos = validate_value(raw, pos, wt, depth).map_err(DecodeErr::from_omnibuf)?;
            continue;
        };

        let f = &msg_schema.fields[fi];
        let val_slot = fi + 1;

        match (&f.kind, wt) {
            (ElemKind::Bool, WIRE_BOOL_FALSE) => {
                vals[val_slot] = false.encode(env);
            }
            (ElemKind::Bool, WIRE_BOOL_TRUE) => {
                vals[val_slot] = true.encode(env);
            }
            (ElemKind::Uint32, WIRE_UINT) => {
                let Some((v, n)) = decode_varint(&raw[pos..]) else {
                    return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
                };
                pos += n;
                vals[val_slot] = (v as u32).encode(env);
            }
            (ElemKind::Uint64, WIRE_UINT) => {
                let Some((v, n)) = decode_varint(&raw[pos..]) else {
                    return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
                };
                pos += n;
                vals[val_slot] = v.encode(env);
            }
            (ElemKind::Sint32, WIRE_SINT) => {
                let Some((u, n)) = decode_varint(&raw[pos..]) else {
                    return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
                };
                pos += n;
                vals[val_slot] = (decode_zigzag(u) as i32).encode(env);
            }
            (ElemKind::Sint64, WIRE_SINT) => {
                let Some((u, n)) = decode_varint(&raw[pos..]) else {
                    return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
                };
                pos += n;
                vals[val_slot] = decode_zigzag(u).encode(env);
            }
            (ElemKind::Fixed32, WIRE_FIXED32) => {
                let bytes: [u8; 4] = raw
                    .get(pos..pos + 4)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed32(), "truncated fixed32"))?;
                pos += 4;
                vals[val_slot] = u32::from_le_bytes(bytes).encode(env);
            }
            (ElemKind::Fixed64, WIRE_FIXED64) => {
                let bytes: [u8; 8] = raw
                    .get(pos..pos + 8)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed64(), "truncated fixed64"))?;
                pos += 8;
                vals[val_slot] = u64::from_le_bytes(bytes).encode(env);
            }
            (ElemKind::Sfixed32, WIRE_SFIXED32) => {
                let bytes: [u8; 4] = raw
                    .get(pos..pos + 4)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| DecodeErr::new(atoms::truncated_sfixed32(), "truncated sfixed32"))?;
                pos += 4;
                vals[val_slot] = i32::from_le_bytes(bytes).encode(env);
            }
            (ElemKind::Sfixed64, WIRE_SFIXED64) => {
                let bytes: [u8; 8] = raw
                    .get(pos..pos + 8)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| DecodeErr::new(atoms::truncated_sfixed64(), "truncated sfixed64"))?;
                pos += 8;
                vals[val_slot] = i64::from_le_bytes(bytes).encode(env);
            }
            (ElemKind::Float32, WIRE_FLOAT32) => {
                let bytes: [u8; 4] = raw
                    .get(pos..pos + 4)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed32(), "truncated float32"))?;
                pos += 4;
                vals[val_slot] = make_f32_term(env, u32::from_le_bytes(bytes));
            }
            (ElemKind::Float64, WIRE_FLOAT64) => {
                let bytes: [u8; 8] = raw
                    .get(pos..pos + 8)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed64(), "truncated float64"))?;
                pos += 8;
                vals[val_slot] = make_f64_term(env, u64::from_le_bytes(bytes));
            }
            (ElemKind::String, WIRE_STRING) => {
                let (s, next_pos) =
                    read_str_slice(raw, pos).map_err(DecodeErr::from_omnibuf)?;
                pos = next_pos;
                vals[val_slot] = make_bytes_term(env, s.as_bytes());
            }
            (ElemKind::Bytes, WIRE_BYTES) => {
                let (b, next_pos) =
                    read_len_slice(raw, pos, 0).map_err(DecodeErr::from_omnibuf)?;
                pos = next_pos;
                vals[val_slot] = make_bytes_term(env, b);
            }
            (ElemKind::Message(sub_idx), WIRE_SUB_MSG) => {
                if depth + 1 > MAX_NESTING_DEPTH {
                    return Err(DecodeErr::new(
                        atoms::max_depth_exceeded(),
                        format!("max container depth {MAX_NESTING_DEPTH} exceeded"),
                    ));
                }
                let (body, next_pos) =
                    read_len_slice(raw, pos, 0).map_err(DecodeErr::from_omnibuf)?;
                pos = next_pos;
                let existing_sub = if is_nil(vals[val_slot]) {
                    None
                } else {
                    Some(vals[val_slot])
                };
                vals[val_slot] = decode_message(
                    env,
                    schema,
                    *sub_idx,
                    body,
                    existing_sub,
                    depth + 1,
                    budget,
                )?;
            }
            (ElemKind::Array(elem_kind), WIRE_ARRAY) => {
                let (items, next_pos) =
                    decode_array(env, schema, elem_kind, raw, pos, depth, budget)?;
                pos = next_pos;
                let accs = array_acc.get_or_insert_with(|| vec![None; n_fields]);
                match &mut accs[fi] {
                    Some(vec) => {
                        vec.extend(items);
                    }
                    slot @ None => {
                        let existing_list = vals[val_slot];
                        if existing_list.list_length().unwrap_or(0) == 0 {
                            *slot = Some(items);
                        } else {
                            let mut combined: Vec<Term<'a>> = existing_list
                                .decode::<ListIterator<'a>>()
                                .map(|it| it.collect())
                                .unwrap_or_default();
                            combined.extend(items);
                            *slot = Some(combined);
                        }
                    }
                }
            }
            (ElemKind::Map(k_kind, v_kind), WIRE_MAP) => {
                let (merged_map, next_pos) = decode_map(
                    env,
                    schema,
                    k_kind,
                    v_kind,
                    raw,
                    pos,
                    vals[val_slot],
                    depth,
                    budget,
                )?;
                pos = next_pos;
                vals[val_slot] = merged_map;
            }
            // Wire type mismatch on known field: skip with validation
            _ => {
                pos = validate_value(raw, pos, wt, depth).map_err(DecodeErr::from_omnibuf)?;
            }
        }
    }

    if let Some(accs) = array_acc {
        for (fi, maybe_vec) in accs.into_iter().enumerate() {
            if let Some(vec) = maybe_vec {
                vals[fi + 1] = vec.encode(env);
            }
        }
    }

    let keys: Vec<Term<'a>> = msg_schema.struct_keys.iter().map(|a| a.encode(env)).collect();
    Term::map_from_arrays(env, &keys, &vals)
        .map_err(|_| DecodeErr::new(atoms::parse_error(), "failed to construct struct map"))
}

fn decode_array<'a>(
    env: Env<'a>,
    schema: &CompiledSchema,
    elem_kind: &ElemKind,
    raw: &[u8],
    pos: usize,
    depth: usize,
    budget: &mut DecodeBudget,
) -> Result<(Vec<Term<'a>>, usize), DecodeErr> {
    if depth + 1 > MAX_NESTING_DEPTH {
        return Err(DecodeErr::new(
            atoms::max_depth_exceeded(),
            format!("max container depth {MAX_NESTING_DEPTH} exceeded"),
        ));
    }
    let (body, next_pos) = read_len_slice(raw, pos, 2).map_err(DecodeErr::from_omnibuf)?;
    let actual_wt = body[0];
    if actual_wt > 15 || actual_wt == WIRE_BOOL_TRUE {
        return Err(DecodeErr::new(
            atoms::parse_error(),
            format!("invalid WireArray ElementType {actual_wt}"),
        ));
    }
    let Some((count_u64, vn)) = decode_varint(&body[1..]) else {
        return Err(DecodeErr::new(
            atoms::truncated_varint(),
            "invalid WireArray count varint",
        ));
    };
    let count = usize::try_from(count_u64).map_err(|_| {
        DecodeErr::new(
            atoms::element_limit_exceeded(),
            format!("array element count {count_u64} overflows usize"),
        )
    })?;
    let hdr_len = 1 + vn;
    let remaining = body.len() - hdr_len;
    if count == 0 && remaining != 0 {
        return Err(DecodeErr::new(
            atoms::trailing_bytes(),
            "empty WireArray has trailing bytes",
        ));
    }
    let expected_wt = elem_kind.wire_type();
    if actual_wt != expected_wt {
        return Err(DecodeErr::new(
            atoms::collection_type_mismatch(),
            format!("WireArray ElementType mismatch: expected {expected_wt}, got {actual_wt}"),
        ));
    }
    let Some((_, parsed_count, parsed_hdr_len)) = parse_array_header(body) else {
        return Err(DecodeErr::new(
            atoms::parse_error(),
            "invalid WireArray header or count exceeds remaining bytes",
        ));
    };
    debug_assert_eq!(count, parsed_count);
    debug_assert_eq!(hdr_len, parsed_hdr_len);

    budget.add_elements(count)?;

    let mut cur = hdr_len;
    let mut items = Vec::with_capacity(count.min(1024));
    for _ in 0..count {
        let (val, next) = decode_element(env, schema, elem_kind, body, cur, depth + 1, budget)?;
        items.push(val);
        cur = next;
    }
    if cur != body.len() {
        return Err(DecodeErr::new(
            atoms::trailing_bytes(),
            "trailing bytes in WireArray",
        ));
    }
    Ok((items, next_pos))
}

#[allow(clippy::too_many_arguments)]
fn decode_map<'a>(
    env: Env<'a>,
    schema: &CompiledSchema,
    k_kind: &ElemKind,
    v_kind: &ElemKind,
    raw: &[u8],
    pos: usize,
    mut acc: Term<'a>,
    depth: usize,
    budget: &mut DecodeBudget,
) -> Result<(Term<'a>, usize), DecodeErr> {
    if depth + 1 > MAX_NESTING_DEPTH {
        return Err(DecodeErr::new(
            atoms::max_depth_exceeded(),
            format!("max container depth {MAX_NESTING_DEPTH} exceeded"),
        ));
    }
    let (body, next_pos) = read_len_slice(raw, pos, 3).map_err(DecodeErr::from_omnibuf)?;
    let actual_kt = body[0];
    let actual_vt = body[1];
    let valid_kt = matches!(
        actual_kt,
        WIRE_UINT
            | WIRE_SINT
            | WIRE_BOOL_FALSE
            | WIRE_FIXED32
            | WIRE_FIXED64
            | WIRE_SFIXED32
            | WIRE_SFIXED64
            | WIRE_STRING
    );
    if !valid_kt || actual_vt > 15 || actual_vt == WIRE_BOOL_TRUE {
        return Err(DecodeErr::new(
            atoms::parse_error(),
            format!("invalid WireMap header <{actual_kt}, {actual_vt}>"),
        ));
    }
    let Some((count_u64, vn)) = decode_varint(&body[2..]) else {
        return Err(DecodeErr::new(
            atoms::truncated_varint(),
            "invalid WireMap count varint",
        ));
    };
    let count = usize::try_from(count_u64).map_err(|_| {
        DecodeErr::new(
            atoms::element_limit_exceeded(),
            format!("map entry count {count_u64} overflows usize"),
        )
    })?;
    let hdr_len = 2 + vn;
    let remaining = body.len() - hdr_len;
    if count == 0 && remaining != 0 {
        return Err(DecodeErr::new(
            atoms::trailing_bytes(),
            "empty WireMap has trailing bytes",
        ));
    }
    let expected_kt = k_kind.wire_type();
    let expected_vt = v_kind.wire_type();
    if actual_kt != expected_kt || actual_vt != expected_vt {
        return Err(DecodeErr::new(
            atoms::collection_type_mismatch(),
            format!(
                "WireMap type mismatch: expected <{expected_kt}, {expected_vt}>, got <{actual_kt}, {actual_vt}>"
            ),
        ));
    }
    let Some((_, _, parsed_count, parsed_hdr_len)) = parse_map_header(body) else {
        return Err(DecodeErr::new(
            atoms::parse_error(),
            "invalid WireMap header or count exceeds remaining bytes",
        ));
    };
    debug_assert_eq!(count, parsed_count);
    debug_assert_eq!(hdr_len, parsed_hdr_len);

    budget.add_elements(count)?;

    let mut cur = hdr_len;
    for _ in 0..count {
        let (k, after_k) = decode_element(env, schema, k_kind, body, cur, depth + 1, budget)?;
        let (v, after_v) = decode_element(env, schema, v_kind, body, after_k, depth + 1, budget)?;
        acc = acc
            .map_put(k, v)
            .map_err(|_| DecodeErr::new(atoms::parse_error(), "failed to insert map entry"))?;
        cur = after_v;
    }
    if cur != body.len() {
        return Err(DecodeErr::new(
            atoms::trailing_bytes(),
            "trailing bytes in WireMap",
        ));
    }
    Ok((acc, next_pos))
}

fn decode_element<'a>(
    env: Env<'a>,
    schema: &CompiledSchema,
    kind: &ElemKind,
    raw: &[u8],
    pos: usize,
    depth: usize,
    budget: &mut DecodeBudget,
) -> Result<(Term<'a>, usize), DecodeErr> {
    match kind {
        ElemKind::Uint32 => {
            let Some((v, n)) = decode_varint(&raw[pos..]) else {
                return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
            };
            Ok(((v as u32).encode(env), pos + n))
        }
        ElemKind::Uint64 => {
            let Some((v, n)) = decode_varint(&raw[pos..]) else {
                return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
            };
            Ok((v.encode(env), pos + n))
        }
        ElemKind::Sint32 => {
            let Some((u, n)) = decode_varint(&raw[pos..]) else {
                return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
            };
            Ok(((decode_zigzag(u) as i32).encode(env), pos + n))
        }
        ElemKind::Sint64 => {
            let Some((u, n)) = decode_varint(&raw[pos..]) else {
                return Err(DecodeErr::new(atoms::truncated_varint(), "invalid varint"));
            };
            Ok((decode_zigzag(u).encode(env), pos + n))
        }
        ElemKind::Bool => match raw.get(pos) {
            Some(0) => Ok((false.encode(env), pos + 1)),
            Some(1) => Ok((true.encode(env), pos + 1)),
            Some(b) => Err(DecodeErr::new(
                atoms::invalid_bool_byte(),
                format!("invalid boolean byte {b}"),
            )),
            None => Err(DecodeErr::new(atoms::truncated_bool(), "truncated boolean")),
        },
        ElemKind::Fixed32 => {
            let bytes: [u8; 4] = raw
                .get(pos..pos + 4)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed32(), "truncated fixed32"))?;
            Ok((u32::from_le_bytes(bytes).encode(env), pos + 4))
        }
        ElemKind::Fixed64 => {
            let bytes: [u8; 8] = raw
                .get(pos..pos + 8)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed64(), "truncated fixed64"))?;
            Ok((u64::from_le_bytes(bytes).encode(env), pos + 8))
        }
        ElemKind::Sfixed32 => {
            let bytes: [u8; 4] = raw
                .get(pos..pos + 4)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| DecodeErr::new(atoms::truncated_sfixed32(), "truncated sfixed32"))?;
            Ok((i32::from_le_bytes(bytes).encode(env), pos + 4))
        }
        ElemKind::Sfixed64 => {
            let bytes: [u8; 8] = raw
                .get(pos..pos + 8)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| DecodeErr::new(atoms::truncated_sfixed64(), "truncated sfixed64"))?;
            Ok((i64::from_le_bytes(bytes).encode(env), pos + 8))
        }
        ElemKind::Float32 => {
            let bytes: [u8; 4] = raw
                .get(pos..pos + 4)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed32(), "truncated float32"))?;
            Ok((make_f32_term(env, u32::from_le_bytes(bytes)), pos + 4))
        }
        ElemKind::Float64 => {
            let bytes: [u8; 8] = raw
                .get(pos..pos + 8)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| DecodeErr::new(atoms::truncated_fixed64(), "truncated float64"))?;
            Ok((make_f64_term(env, u64::from_le_bytes(bytes)), pos + 8))
        }
        ElemKind::String => {
            let (s, next_pos) = read_str_slice(raw, pos).map_err(DecodeErr::from_omnibuf)?;
            Ok((make_bytes_term(env, s.as_bytes()), next_pos))
        }
        ElemKind::Bytes => {
            let (b, next_pos) = read_len_slice(raw, pos, 0).map_err(DecodeErr::from_omnibuf)?;
            Ok((make_bytes_term(env, b), next_pos))
        }
        ElemKind::Message(sub_idx) => {
            if depth + 1 > MAX_NESTING_DEPTH {
                return Err(DecodeErr::new(
                    atoms::max_depth_exceeded(),
                    format!("max container depth {MAX_NESTING_DEPTH} exceeded"),
                ));
            }
            let (body, next_pos) = read_len_slice(raw, pos, 0).map_err(DecodeErr::from_omnibuf)?;
            let sub = decode_message(env, schema, *sub_idx, body, None, depth + 1, budget)?;
            Ok((sub, next_pos))
        }
        ElemKind::Array(inner) => {
            let (items, next_pos) = decode_array(env, schema, inner, raw, pos, depth, budget)?;
            Ok((items.encode(env), next_pos))
        }
        ElemKind::Map(k_kind, v_kind) => {
            let empty_map = Term::map_new(env);
            let (m, next_pos) =
                decode_map(env, schema, k_kind, v_kind, raw, pos, empty_map, depth, budget)?;
            Ok((m, next_pos))
        }
    }
}
