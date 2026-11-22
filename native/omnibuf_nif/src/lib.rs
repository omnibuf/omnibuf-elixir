mod schema;

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet};

const MAX_RETAINED_SCRATCH: usize = 256 * 1024;

thread_local! {
    static ENCODE_BUF: RefCell<Vec<u8>> = RefCell::new(Vec::with_capacity(1024));
}

use omnibuf::blind::{BlindValue, DecodeBlindOptions, decode_blind_with_options};
use omnibuf::wire::{
    MAX_NESTING_DEPTH, WIRE_BOOL_FALSE, WIRE_BOOL_TRUE, WIRE_SUB_MSG, read_len_slice, read_tag_at,
    skip_value_opt,
};
use rustler::types::list::ListIterator;
use rustler::{Binary, Encoder, Env, NewBinary, NifResult, ResourceArc, Term};

use crate::schema::{
    CompiledSchema, DEFAULT_MAX_ELEMENTS, DecodeBudget, DecodeErr, compile_schema_from_term,
};

pub mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        found,
        not_found,
        __struct__,

        // Float special atoms
        nan,
        infinity,
        neg_infinity,

        // Schema type atoms
        uint32,
        uint64,
        int32,
        int64,
        sint32,
        sint64,
        r#enum = "enum",
        bool,
        fixed32,
        fixed64,
        sfixed32,
        sfixed64,
        float,
        double,
        string,
        bytes,
        message,
        array,
        map,

        // Error reason atoms
        parse_error,
        serialize,
        invalid_utf8,
        max_depth_exceeded,
        trailing_bytes,
        invalid_field_zero,
        reserved_varint_prefix,
        collection_type_mismatch,
        element_limit_exceeded,
        message_too_large,
        truncated_varint,
        truncated_fixed32,
        truncated_fixed64,
        truncated_sfixed32,
        truncated_sfixed64,
        invalid_bool_byte,
        truncated_bool,
    }
}

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

#[inline]
fn make_bytes<'a>(env: Env<'a>, slice: &[u8]) -> Term<'a> {
    let mut bin = NewBinary::new(env, slice.len());
    bin.as_mut_slice().copy_from_slice(slice);
    bin.into()
}

#[inline]
fn err_tuple<'a>(env: Env<'a>, err: DecodeErr) -> Term<'a> {
    (atoms::error(), (err.reason, err.message)).encode(env)
}

#[inline]
fn omnibuf_err_tuple<'a>(env: Env<'a>, err: omnibuf::Error) -> Term<'a> {
    err_tuple(env, DecodeErr::from_omnibuf(err))
}

fn blind_value_to_term<'a>(env: Env<'a>, val: &BlindValue) -> Term<'a> {
    match val {
        BlindValue::Bool(b) => b.encode(env),
        BlindValue::Uint(u) => u.encode(env),
        BlindValue::Int(i) => i.encode(env),
        BlindValue::Float32(f) => {
            if f.is_finite() {
                f64::from(*f).encode(env)
            } else if f.is_nan() {
                atoms::nan().encode(env)
            } else if f.is_sign_positive() {
                atoms::infinity().encode(env)
            } else {
                atoms::neg_infinity().encode(env)
            }
        }
        BlindValue::Float64(f) => {
            if f.is_finite() {
                f.encode(env)
            } else if f.is_nan() {
                atoms::nan().encode(env)
            } else if f.is_sign_positive() {
                atoms::infinity().encode(env)
            } else {
                atoms::neg_infinity().encode(env)
            }
        }
        BlindValue::String(s) => make_bytes(env, s.as_bytes()),
        BlindValue::Bytes(b) => make_bytes(env, b),
        BlindValue::Array(items) => {
            let terms: Vec<Term<'a>> = items.iter().map(|v| blind_value_to_term(env, v)).collect();
            terms.encode(env)
        }
        BlindValue::Object(map) => blind_map_to_term(env, map),
    }
}

fn blind_map_to_term<'a>(env: Env<'a>, map: &BTreeMap<String, BlindValue>) -> Term<'a> {
    let mut keys = Vec::with_capacity(map.len());
    let mut vals = Vec::with_capacity(map.len());
    for (k, v) in map {
        keys.push(make_bytes(env, k.as_bytes()));
        vals.push(blind_value_to_term(env, v));
    }
    Term::map_from_arrays(env, &keys, &vals).unwrap_or_else(|_| Term::map_new(env))
}

// ---------------------------------------------------------------------------
// Tier 4: Blind Decoding NIFs
// ---------------------------------------------------------------------------

#[inline]
fn blind_alloc_limit(max_message_bytes: usize) -> usize {
    max_message_bytes
        .saturating_mul(64)
        .min(max_message_bytes.max(64 * 1024 * 1024))
}

fn decode_blind_impl<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    max_depth: usize,
    max_elements: usize,
    max_message_bytes: usize,
) -> Term<'a> {
    let slice = bin.as_slice();
    if slice.len() > max_message_bytes {
        return err_tuple(
            env,
            DecodeErr::new(
                atoms::message_too_large(),
                format!("packet size {} exceeds {}", slice.len(), max_message_bytes),
            ),
        );
    }

    let opts = DecodeBlindOptions {
        inherited_schema: None,
        max_message_bytes,
        max_elements,
        max_alloc_bytes: blind_alloc_limit(max_message_bytes),
        max_depth: max_depth.min(MAX_NESTING_DEPTH),
    };

    match decode_blind_with_options(slice, opts) {
        Ok(map) => (atoms::ok(), blind_map_to_term(env, &map)).encode(env),
        Err(err) => omnibuf_err_tuple(env, err),
    }
}

#[rustler::nif]
fn nif_decode_blind<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    max_depth: usize,
    max_elements: usize,
    max_message_bytes: usize,
) -> Term<'a> {
    decode_blind_impl(env, bin, max_depth, max_elements, max_message_bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_decode_blind_dirty<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    max_depth: usize,
    max_elements: usize,
    max_message_bytes: usize,
) -> Term<'a> {
    decode_blind_impl(env, bin, max_depth, max_elements, max_message_bytes)
}

fn decode_blind_json_impl<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    max_depth: usize,
    max_elements: usize,
    max_message_bytes: usize,
) -> Term<'a> {
    let slice = bin.as_slice();
    if slice.len() > max_message_bytes {
        return err_tuple(
            env,
            DecodeErr::new(
                atoms::message_too_large(),
                format!("packet size {} exceeds {}", slice.len(), max_message_bytes),
            ),
        );
    }

    let opts = DecodeBlindOptions {
        inherited_schema: None,
        max_message_bytes,
        max_elements,
        max_alloc_bytes: blind_alloc_limit(max_message_bytes),
        max_depth: max_depth.min(MAX_NESTING_DEPTH),
    };

    match decode_blind_with_options(slice, opts) {
        Ok(map) => {
            if contains_non_finite(&map) {
                return err_tuple(
                    env,
                    DecodeErr::new(
                        atoms::serialize(),
                        "non-finite floating-point value cannot be represented in JSON",
                    ),
                );
            }
            let json = omnibuf::stringify_blind_json(&map, None, false);
            (atoms::ok(), make_bytes(env, json.as_bytes())).encode(env)
        }
        Err(err) => omnibuf_err_tuple(env, err),
    }
}

#[rustler::nif]
fn nif_decode_blind_json<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    max_depth: usize,
    max_elements: usize,
    max_message_bytes: usize,
) -> Term<'a> {
    decode_blind_json_impl(env, bin, max_depth, max_elements, max_message_bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_decode_blind_json_dirty<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    max_depth: usize,
    max_elements: usize,
    max_message_bytes: usize,
) -> Term<'a> {
    decode_blind_json_impl(env, bin, max_depth, max_elements, max_message_bytes)
}

fn contains_non_finite(map: &BTreeMap<String, BlindValue>) -> bool {
    map.values().any(value_has_non_finite)
}

fn value_has_non_finite(v: &BlindValue) -> bool {
    match v {
        BlindValue::Float32(f) => !f.is_finite(),
        BlindValue::Float64(f) => !f.is_finite(),
        BlindValue::Array(items) => items.iter().any(value_has_non_finite),
        BlindValue::Object(m) => contains_non_finite(m),
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Lazy Opaque Lookup & Splicing NIFs
// ---------------------------------------------------------------------------

#[inline]
fn wt_matches(wt: u8, target_wt: u8) -> bool {
    if target_wt == 16 {
        wt == WIRE_BOOL_FALSE || wt == WIRE_BOOL_TRUE
    } else {
        wt == target_wt
    }
}

#[rustler::nif]
fn nif_opaque_find_last<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    target_field: u32,
    target_wt: u8,
) -> Term<'a> {
    let raw = bin.as_slice();
    let n = raw.len();
    let mut pos = 0usize;
    let mut found: Option<(u8, usize)> = None;

    while pos < n {
        let Some((fnum, wt, after_tag)) = read_tag_at(raw, pos) else {
            return err_tuple(
                env,
                DecodeErr::new(atoms::parse_error(), format!("invalid tag at {pos}")),
            );
        };
        if fnum == 0 && wt != WIRE_SUB_MSG {
            return err_tuple(
                env,
                DecodeErr::new(atoms::invalid_field_zero(), "Field #0 must be WireSubMsg"),
            );
        }
        if fnum == target_field && wt_matches(wt, target_wt) {
            found = Some((wt, after_tag));
        }
        let Some(next) = skip_value_opt(raw, after_tag, wt) else {
            return err_tuple(
                env,
                DecodeErr::new(atoms::parse_error(), format!("truncated value at {after_tag}")),
            );
        };
        pos = next;
    }

    match found {
        Some((wt, offset)) => {
            let sub = bin
                .make_subbinary(offset, n - offset)
                .expect("subbinary bounds checked");
            (atoms::ok(), (atoms::found(), wt, sub)).encode(env)
        }
        None => (atoms::ok(), atoms::not_found()).encode(env),
    }
}

#[rustler::nif]
fn nif_opaque_find_all<'a>(
    env: Env<'a>,
    bin: Binary<'a>,
    target_field: u32,
    target_wt: u8,
) -> Term<'a> {
    let raw = bin.as_slice();
    let n = raw.len();
    let mut pos = 0usize;
    let mut matches: Vec<(u8, Binary<'a>)> = Vec::new();

    while pos < n {
        let Some((fnum, wt, after_tag)) = read_tag_at(raw, pos) else {
            return err_tuple(
                env,
                DecodeErr::new(atoms::parse_error(), format!("invalid tag at {pos}")),
            );
        };
        if fnum == 0 && wt != WIRE_SUB_MSG {
            return err_tuple(
                env,
                DecodeErr::new(atoms::invalid_field_zero(), "Field #0 must be WireSubMsg"),
            );
        }
        if fnum == target_field && wt_matches(wt, target_wt) {
            let sub = bin
                .make_subbinary(after_tag, n - after_tag)
                .expect("subbinary bounds checked");
            matches.push((wt, sub));
        }
        let Some(next) = skip_value_opt(raw, after_tag, wt) else {
            return err_tuple(
                env,
                DecodeErr::new(atoms::parse_error(), format!("truncated value at {after_tag}")),
            );
        };
        pos = next;
    }

    (atoms::ok(), matches).encode(env)
}

#[rustler::nif]
fn nif_opaque_extract_submsg<'a>(env: Env<'a>, bin: Binary<'a>, target_field: u32) -> Term<'a> {
    let raw = bin.as_slice();
    let n = raw.len();
    let mut pos = 0usize;
    let mut first: Option<(usize, usize)> = None;
    let mut multi: Option<Vec<u8>> = None;

    while pos < n {
        let Some((fnum, wt, after_tag)) = read_tag_at(raw, pos) else {
            return err_tuple(
                env,
                DecodeErr::new(atoms::parse_error(), format!("invalid tag at {pos}")),
            );
        };
        if fnum == 0 && wt != WIRE_SUB_MSG {
            return err_tuple(
                env,
                DecodeErr::new(atoms::invalid_field_zero(), "Field #0 must be WireSubMsg"),
            );
        }
        if fnum == target_field && wt == WIRE_SUB_MSG {
            let Ok((body, next)) = read_len_slice(raw, after_tag, 0) else {
                return err_tuple(
                    env,
                    DecodeErr::new(atoms::parse_error(), "truncated submessage"),
                );
            };
            let body_start = body.as_ptr() as usize - raw.as_ptr() as usize;
            let body_len = body.len();
            if let Some(ref mut buf) = multi {
                buf.extend_from_slice(body);
            } else if let Some((f_start, f_len)) = first {
                let mut buf = Vec::with_capacity(f_len + body_len);
                buf.extend_from_slice(&raw[f_start..f_start + f_len]);
                buf.extend_from_slice(body);
                multi = Some(buf);
            } else {
                first = Some((body_start, body_len));
            }
            pos = next;
        } else {
            let Some(next) = skip_value_opt(raw, after_tag, wt) else {
                return err_tuple(
                    env,
                    DecodeErr::new(atoms::parse_error(), format!("truncated value at {after_tag}")),
                );
            };
            pos = next;
        }
    }

    if let Some(buf) = multi {
        (atoms::ok(), make_bytes(env, &buf)).encode(env)
    } else if let Some((start, len)) = first {
        let sub = bin
            .make_subbinary(start, len)
            .expect("subbinary bounds checked");
        (atoms::ok(), sub).encode(env)
    } else {
        (atoms::ok(), atoms::nil()).encode(env)
    }
}

fn opaque_splice_impl<'a>(env: Env<'a>, packet: Binary<'a>, dirty_list: Term<'a>) -> Term<'a> {
    let raw = packet.as_slice();
    let Ok(iter) = dirty_list.decode::<ListIterator<'a>>() else {
        return err_tuple(env, DecodeErr::new(atoms::parse_error(), "invalid dirty list"));
    };

    let mut entries: Vec<(u32, Binary<'a>)> = Vec::new();
    let mut all_small = true;
    let mut dirty_mask = 0u64;
    let mut max_field = 0u16;

    for item in iter {
        let Ok((fnum, iodata_term)) = item.decode::<(u32, Term<'a>)>() else {
            return err_tuple(env, DecodeErr::new(atoms::parse_error(), "invalid dirty entry"));
        };
        let Ok(bin) = Binary::from_iolist(iodata_term) else {
            return err_tuple(env, DecodeErr::new(atoms::parse_error(), "invalid dirty iodata"));
        };
        if fnum == 0 || fnum >= 64 {
            all_small = false;
        } else {
            dirty_mask |= 1u64 << fnum;
            if (fnum as u16) > max_field {
                max_field = fnum as u16;
            }
        }
        entries.push((fnum, bin));
    }

    if entries.is_empty() {
        return (atoms::ok(), packet).encode(env);
    }

    let extra: usize = entries.iter().map(|(_, b)| b.len()).sum();
    let mut out = Vec::with_capacity(raw.len().saturating_add(extra));

    if all_small {
        let mut by_field: [&[u8]; 64] = [&[]; 64];
        for (fnum, bin) in &entries {
            by_field[*fnum as usize] = bin.as_slice();
        }
        let n = raw.len();
        let mut pos = 0usize;
        let mut clean_start = 0usize;
        let mut emitted = 0u64;

        while pos < n {
            let field_start = pos;
            let Some((fnum, wt, after_tag)) = read_tag_at(raw, pos) else {
                return err_tuple(
                    env,
                    DecodeErr::new(atoms::parse_error(), format!("invalid tag at {pos}")),
                );
            };
            if fnum == 0 && wt != WIRE_SUB_MSG {
                return err_tuple(
                    env,
                    DecodeErr::new(atoms::invalid_field_zero(), "Field #0 must be WireSubMsg"),
                );
            }
            let Some(field_end) = skip_value_opt(raw, after_tag, wt) else {
                return err_tuple(
                    env,
                    DecodeErr::new(
                        atoms::parse_error(),
                        format!("truncated value at {after_tag}"),
                    ),
                );
            };
            pos = field_end;

            let bit = if fnum > 0 && fnum < 64 {
                1u64 << fnum
            } else {
                0
            };
            if (dirty_mask & bit) != 0 {
                if clean_start < field_start {
                    out.extend_from_slice(&raw[clean_start..field_start]);
                }
                if (emitted & bit) == 0 {
                    let rep = by_field[fnum as usize];
                    if !rep.is_empty() {
                        out.extend_from_slice(rep);
                    }
                    emitted |= bit;
                }
                clean_start = field_end;
            }
        }

        if clean_start < n {
            out.extend_from_slice(&raw[clean_start..n]);
        }

        let rem = dirty_mask & !emitted;
        if rem != 0 {
            let limit = max_field.min(63);
            for fnum in 1..=limit {
                if (rem & (1u64 << fnum)) != 0 {
                    let rep = by_field[fnum as usize];
                    if !rep.is_empty() {
                        out.extend_from_slice(rep);
                    }
                }
            }
        }

        (atoms::ok(), make_bytes(env, &out)).encode(env)
    } else {
        let mut dirty_map: HashMap<u32, &[u8]> = HashMap::with_capacity(entries.len());
        for (fnum, bin) in &entries {
            dirty_map.insert(*fnum, bin.as_slice());
        }
        let mut emitted: HashSet<u32> = HashSet::with_capacity(entries.len());
        let n = raw.len();
        let mut pos = 0usize;
        let mut clean_start = 0usize;

        while pos < n {
            let field_start = pos;
            let Some((fnum, wt, after_tag)) = read_tag_at(raw, pos) else {
                return err_tuple(
                    env,
                    DecodeErr::new(atoms::parse_error(), format!("invalid tag at {pos}")),
                );
            };
            if fnum == 0 && wt != WIRE_SUB_MSG {
                return err_tuple(
                    env,
                    DecodeErr::new(atoms::invalid_field_zero(), "Field #0 must be WireSubMsg"),
                );
            }
            let Some(field_end) = skip_value_opt(raw, after_tag, wt) else {
                return err_tuple(
                    env,
                    DecodeErr::new(
                        atoms::parse_error(),
                        format!("truncated value at {after_tag}"),
                    ),
                );
            };
            pos = field_end;

            if let Some(&rep) = dirty_map.get(&fnum) {
                if clean_start < field_start {
                    out.extend_from_slice(&raw[clean_start..field_start]);
                }
                if emitted.insert(fnum) && !rep.is_empty() {
                    out.extend_from_slice(rep);
                }
                clean_start = field_end;
            }
        }

        if clean_start < n {
            out.extend_from_slice(&raw[clean_start..n]);
        }

        let mut trailing: Vec<(u32, &[u8])> = dirty_map
            .into_iter()
            .filter(|(fnum, rep)| !emitted.contains(fnum) && !rep.is_empty())
            .collect();
        trailing.sort_unstable_by_key(|(fnum, _)| *fnum);
        for (_, rep) in trailing {
            out.extend_from_slice(rep);
        }

        (atoms::ok(), make_bytes(env, &out)).encode(env)
    }
}

#[rustler::nif]
fn nif_opaque_splice<'a>(env: Env<'a>, packet: Binary<'a>, dirty_list: Term<'a>) -> Term<'a> {
    opaque_splice_impl(env, packet, dirty_list)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_opaque_splice_dirty<'a>(
    env: Env<'a>,
    packet: Binary<'a>,
    dirty_list: Term<'a>,
) -> Term<'a> {
    opaque_splice_impl(env, packet, dirty_list)
}

// ---------------------------------------------------------------------------
// Fast Struct Schema Compilation, Encode & Decode NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
fn nif_compile_schema<'a>(msg_list: Term<'a>) -> NifResult<ResourceArc<CompiledSchema>> {
    let compiled = compile_schema_from_term(msg_list)?;
    Ok(ResourceArc::new(compiled))
}

#[rustler::nif]
fn nif_encode_struct<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    msg: Term<'a>,
) -> NifResult<Term<'a>> {
    ENCODE_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        buf.clear();
        let res = schema::encode_message(&schema, 0, msg, &mut buf, 0);
        let out = res.map(|()| make_bytes(env, &buf));
        if buf.capacity() > MAX_RETAINED_SCRATCH {
            buf.clear();
            buf.shrink_to(1024);
        }
        out
    })
}

fn decode_struct_impl<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    bin: Binary<'a>,
) -> Term<'a> {
    let mut budget = DecodeBudget::new(DEFAULT_MAX_ELEMENTS);
    match schema::decode_message(env, &schema, 0, bin.as_slice(), None, 0, &mut budget) {
        Ok(term) => (atoms::ok(), term).encode(env),
        Err(err) => err_tuple(env, err),
    }
}

#[rustler::nif]
fn nif_decode_struct<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    bin: Binary<'a>,
) -> Term<'a> {
    decode_struct_impl(env, schema, bin)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_decode_struct_dirty<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    bin: Binary<'a>,
) -> Term<'a> {
    decode_struct_impl(env, schema, bin)
}

fn merge_struct_impl<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    existing: Term<'a>,
    bin: Binary<'a>,
) -> Term<'a> {
    let mut budget = DecodeBudget::new(DEFAULT_MAX_ELEMENTS);
    match schema::decode_message(
        env,
        &schema,
        0,
        bin.as_slice(),
        Some(existing),
        0,
        &mut budget,
    ) {
        Ok(term) => (atoms::ok(), term).encode(env),
        Err(err) => err_tuple(env, err),
    }
}

#[rustler::nif]
fn nif_merge_struct<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    existing: Term<'a>,
    bin: Binary<'a>,
) -> Term<'a> {
    merge_struct_impl(env, schema, existing, bin)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn nif_merge_struct_dirty<'a>(
    env: Env<'a>,
    schema: ResourceArc<CompiledSchema>,
    existing: Term<'a>,
    bin: Binary<'a>,
) -> Term<'a> {
    merge_struct_impl(env, schema, existing, bin)
}

rustler::init!("Elixir.OmniBuf.Native.NIF", load = on_load);
