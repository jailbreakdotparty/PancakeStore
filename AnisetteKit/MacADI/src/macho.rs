//! Minimal thin x86_64 Mach-O reader: the segments to map and the dyld bind stream to stub.
//! Classic `LC_DYLD_INFO[_ONLY]` only (the CoreADI builds predate chained fixups).

use crate::Error;

const MH_MAGIC_64: u32 = 0xFEED_FACF;
const LC_SEGMENT_64: u32 = 0x19;
const LC_DYLD_INFO: u32 = 0x22;
const LC_DYLD_INFO_ONLY: u32 = 0x8000_0022;

pub struct Segment {
    pub vmaddr: u64,
    pub vmsize: u64,
    pub fileoff: u64,
    pub filesize: u64,
    pub writable: bool,
}

pub struct Bind {
    pub address: u64,
    pub symbol: String,
    pub addend: i64,
}

pub struct MachO {
    pub segments: Vec<Segment>,
    binds: Vec<Bind>,
}

fn u32_at(d: &[u8], o: usize) -> Result<u32, Error> {
    d.get(o..o + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| Error::MachO("truncated".into()))
}

fn u64_at(d: &[u8], o: usize) -> Result<u64, Error> {
    d.get(o..o + 8).map(|b| u64::from_le_bytes(b.try_into().unwrap())).ok_or_else(|| Error::MachO("truncated".into()))
}

fn uleb(d: &[u8], mut o: usize) -> Result<(u64, usize), Error> {
    let (mut v, mut shift) = (0u64, 0u32);
    loop {
        let b = *d.get(o).ok_or_else(|| Error::MachO("truncated leb".into()))?;
        o += 1;
        if shift < 64 {
            v |= u64::from(b & 0x7F) << shift;
        }
        shift += 7;
        if b & 0x80 == 0 {
            return Ok((v, o));
        }
    }
}

fn sleb(d: &[u8], mut o: usize) -> Result<(i64, usize), Error> {
    let (mut v, mut shift) = (0i64, 0u32);
    loop {
        let b = *d.get(o).ok_or_else(|| Error::MachO("truncated leb".into()))?;
        o += 1;
        if shift < 64 {
            v |= i64::from(b & 0x7F) << shift;
        }
        shift += 7;
        if b & 0x80 == 0 {
            if shift < 64 && b & 0x40 != 0 {
                v |= -1i64 << shift;
            }
            return Ok((v, o));
        }
    }
}

impl MachO {
    pub fn parse(d: &[u8]) -> Result<MachO, Error> {
        if u32_at(d, 0)? != MH_MAGIC_64 {
            return Err(Error::MachO("not a thin 64-bit Mach-O".into()));
        }
        let ncmds = u32_at(d, 16)?;
        let mut segments = Vec::new();
        let (mut bind, mut lazy) = ((0usize, 0usize), (0usize, 0usize));
        let mut off = 32usize;
        for _ in 0..ncmds {
            let cmd = u32_at(d, off)?;
            let size = u32_at(d, off + 4)? as usize;
            match cmd {
                LC_SEGMENT_64 => segments.push(Segment {
                    vmaddr: u64_at(d, off + 24)?,
                    vmsize: u64_at(d, off + 32)?,
                    fileoff: u64_at(d, off + 40)?,
                    filesize: u64_at(d, off + 48)?,
                    writable: u32_at(d, off + 60)? & 2 != 0,
                }),
                LC_DYLD_INFO | LC_DYLD_INFO_ONLY => {
                    bind = (u32_at(d, off + 16)? as usize, u32_at(d, off + 20)? as usize);
                    lazy = (u32_at(d, off + 32)? as usize, u32_at(d, off + 36)? as usize);
                }
                _ => {}
            }
            off += size;
        }
        let mut m = MachO { segments, binds: Vec::new() };
        let mut binds = m.read_binds(d, bind, false)?;
        binds.extend(m.read_binds(d, lazy, true)?);
        m.binds = binds;
        Ok(m)
    }

    fn read_binds(&self, d: &[u8], (start, len): (usize, usize), lazy: bool) -> Result<Vec<Bind>, Error> {
        let mut out = Vec::new();
        if len == 0 {
            return Ok(out);
        }
        let end = start + len;
        let (mut o, mut symbol, mut addend) = (start, String::new(), 0i64);
        let (mut seg, mut seg_off) = (0usize, 0u64);
        let push = |out: &mut Vec<Bind>, seg: usize, seg_off: u64, symbol: &str, addend: i64| -> Result<(), Error> {
            let s = self.segments.get(seg).ok_or_else(|| Error::MachO("bad bind segment".into()))?;
            out.push(Bind { address: s.vmaddr.wrapping_add(seg_off), symbol: symbol.to_string(), addend });
            Ok(())
        };
        while o < end {
            let byte = d[o];
            let (op, imm) = (byte & 0xF0, u64::from(byte & 0x0F));
            o += 1;
            match op {
                0x00 => {
                    if !lazy {
                        break;
                    }
                }
                0x10 | 0x30 | 0x50 => {}
                0x20 => o = uleb(d, o)?.1,
                0x40 => {
                    let z = d[o..].iter().position(|&b| b == 0).ok_or_else(|| Error::MachO("bad symbol".into()))?;
                    symbol = String::from_utf8_lossy(&d[o..o + z]).into_owned();
                    o += z + 1;
                }
                0x60 => {
                    let (v, n) = sleb(d, o)?;
                    addend = v;
                    o = n;
                }
                0x70 => {
                    seg = imm as usize;
                    let (v, n) = uleb(d, o)?;
                    seg_off = v;
                    o = n;
                }
                0x80 => {
                    let (v, n) = uleb(d, o)?;
                    seg_off = seg_off.wrapping_add(v);
                    o = n;
                }
                0x90 => {
                    push(&mut out, seg, seg_off, &symbol, addend)?;
                    seg_off = seg_off.wrapping_add(8);
                }
                0xA0 => {
                    push(&mut out, seg, seg_off, &symbol, addend)?;
                    let (v, n) = uleb(d, o)?;
                    seg_off = seg_off.wrapping_add(v).wrapping_add(8);
                    o = n;
                }
                0xB0 => {
                    push(&mut out, seg, seg_off, &symbol, addend)?;
                    seg_off = seg_off.wrapping_add(imm * 8 + 8);
                }
                0xC0 => {
                    let (count, n) = uleb(d, o)?;
                    let (skip, n) = uleb(d, n)?;
                    o = n;
                    for _ in 0..count {
                        push(&mut out, seg, seg_off, &symbol, addend)?;
                        seg_off = seg_off.wrapping_add(skip).wrapping_add(8);
                    }
                }
                _ => return Err(Error::MachO(format!("unsupported bind opcode {op:#x}"))),
            }
        }
        Ok(out)
    }

    pub fn binds(&self) -> &[Bind] {
        &self.binds
    }

    /// Distinct imported symbols in first-seen order (binds, then lazy binds).
    pub fn bind_symbols(&self) -> Vec<&str> {
        let mut seen = std::collections::HashSet::new();
        self.binds.iter().map(|b| b.symbol.as_str()).filter(|s| seen.insert(*s)).collect()
    }
}
