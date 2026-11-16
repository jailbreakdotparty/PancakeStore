//! arm64(e) Mach-O loader for the SAP/modern-ADI guest images.
//!
//! Ports ipatool's `internal/sap/machimage` on top of the `object` crate, which
//! already parses fat files, segments, symbols and `LC_DYLD_CHAINED_FIXUPS`
//! (all arm64e pointer formats). We hand-write only the ARM64e pointer-auth
//! instruction stripping and the resolve/apply glue.

use std::collections::HashMap;

use object::macho::{self, MachHeader64};
use object::read::macho::{
    DyldChainedFixups, FatArch, LoadCommandVariant, MachHeader, MachOFatFile32, MachOFatFile64,
    Nlist as _, Segment as _,
};
use object::{Endianness, FileKind};

use crate::Error;

const PAGE: u64 = 0x1000;
const POINTER: u64 = 8;

fn me(m: impl Into<String>) -> Error {
    Error::MachO(m.into())
}

struct Segment {
    name: String,
    address: u64,
    size: u64,
    file_off: u64,
    file_size: u64,
}

pub struct Image {
    name: String,
    data: Vec<u8>,
    base: u64,
    segments: Vec<Segment>,
    /// symbol name -> file vmaddr (pre-slide, image-absolute)
    symbols: HashMap<String, u64>,
    relocated: bool,
    loaded_base: u64,
}

/// A trait so the loader can target our Unicorn engine without a hard dependency.
pub trait Memory {
    fn mem_map(&mut self, address: u64, size: u64) -> Result<(), Error>;
    fn mem_write(&mut self, address: u64, data: &[u8]) -> Result<(), Error>;
}

fn align(value: u64, alignment: u64) -> u64 {
    (value + alignment - 1) & !(alignment - 1)
}

/// Select the arm64e slice of a fat binary, or return the input unchanged.
fn arm64_slice(input: &[u8]) -> Result<Vec<u8>, Error> {
    match FileKind::parse(input) {
        Ok(FileKind::MachOFat32) => {
            let fat = MachOFatFile32::parse(input).map_err(|e| me(format!("fat32: {e}")))?;
            pick_fat(input, fat.arches())
        }
        Ok(FileKind::MachOFat64) => {
            let fat = MachOFatFile64::parse(input).map_err(|e| me(format!("fat64: {e}")))?;
            pick_fat(input, fat.arches())
        }
        _ => Ok(input.to_vec()),
    }
}

fn pick_fat<A: FatArch>(input: &[u8], arches: &[A]) -> Result<Vec<u8>, Error> {
    for arch in arches {
        if arch.cputype() == macho::CPU_TYPE_ARM64 && arch.cpusubtype().id() == macho::CPU_SUBTYPE_ARM64E {
            let data = arch
                .data(input)
                .map_err(|e| me(format!("arm64e slice: {e}")))?;
            return Ok(data.to_vec());
        }
    }
    Err(me("universal binary has no arm64e slice"))
}

impl Image {
    pub fn base(&self) -> u64 {
        self.base
    }

    pub fn open(name: &str, input: &[u8]) -> Result<Image, Error> {
        let data = arm64_slice(input)?;
        let endian = Endianness::Little;
        let header =
            MachHeader64::<Endianness>::parse(&*data, 0).map_err(|e| me(format!("{name}: {e}")))?;
        if header.cputype(endian) != macho::CPU_TYPE_ARM64 {
            return Err(me(format!("{name}: expected arm64 Mach-O")));
        }

        let mut segments = Vec::new();
        let mut base = u64::MAX;
        let mut symbols = HashMap::new();

        let mut commands = header
            .load_commands(endian, &*data, 0)
            .map_err(|e| me(format!("{name} load commands: {e}")))?;
        while let Some(command) = commands.next().map_err(|e| me(format!("{name}: {e}")))? {
            match command.variant().map_err(|e| me(format!("{name}: {e}")))? {
                LoadCommandVariant::Segment64(seg, _) => {
                    let seg_name = String::from_utf8_lossy(seg.name()).trim_end_matches('\0').to_string();
                    let addr = seg.vmaddr.get(endian);
                    if seg_name != "__PAGEZERO" && addr < base {
                        base = addr;
                    }
                    segments.push(Segment {
                        name: seg_name,
                        address: addr,
                        size: seg.vmsize.get(endian),
                        file_off: seg.fileoff.get(endian),
                        file_size: seg.filesize.get(endian),
                    });
                }
                LoadCommandVariant::Symtab(symtab) => {
                    let table = symtab
                        .symbols::<MachHeader64<Endianness>, _>(endian, &*data)
                        .map_err(|e| me(format!("{name} symtab: {e}")))?;
                    for sym in table.iter() {
                        let value = sym.n_value(endian);
                        if value == 0 {
                            continue;
                        }
                        if let Ok(sym_name) = sym.name(endian, table.strings()) {
                            if !sym_name.is_empty() {
                                symbols.insert(
                                    String::from_utf8_lossy(sym_name).into_owned(),
                                    value,
                                );
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        if base == u64::MAX {
            return Err(me(format!("{name}: no segments")));
        }

        let mut image = Image {
            name: name.to_string(),
            data,
            base,
            segments,
            symbols,
            relocated: false,
            loaded_base: 0,
        };
        image.validate_segments()?;
        image.strip_pointer_authentication()?;
        Ok(image)
    }

    fn validate_segments(&self) -> Result<(), Error> {
        for seg in &self.segments {
            if seg.file_size > seg.size {
                return Err(me(format!("{}: segment {} file>mem", self.name, seg.name)));
            }
            let end = seg
                .file_off
                .checked_add(seg.file_size)
                .ok_or_else(|| me("segment overflow"))?;
            if end > self.data.len() as u64 {
                return Err(me(format!("{}: segment {} exceeds file", self.name, seg.name)));
            }
        }
        Ok(())
    }

    /// Rewrite ARM64e pointer-authentication ops into their canonical,
    /// unsigned-pointer equivalents (ports machimage.WithoutPointerAuthentication).
    fn strip_pointer_authentication(&mut self) -> Result<(), Error> {
        // Rewrite executable sections only. We don't have section flags from the
        // object load-command walk here, so use __TEXT-family segment file ranges.
        let ranges: Vec<(u64, u64)> = self
            .segments
            .iter()
            .filter(|s| s.name == "__TEXT" || s.name == "__TEXT_EXEC")
            .map(|s| (s.file_off, s.file_off + s.file_size))
            .collect();
        for (start, end) in ranges {
            let mut offset = start;
            while offset + 4 <= end && (offset as usize) + 4 <= self.data.len() {
                let i = offset as usize;
                let instruction = u32::from_le_bytes(self.data[i..i + 4].try_into().unwrap());
                let replacement = without_pointer_authentication(instruction);
                if replacement != instruction {
                    self.data[i..i + 4].copy_from_slice(&replacement.to_le_bytes());
                }
                offset += 4;
            }
        }
        Ok(())
    }

    pub fn export(&self, name: &str, load_base: u64) -> Result<u64, Error> {
        let address = *self
            .symbols
            .get(name)
            .ok_or_else(|| me(format!("find {name} in {}", self.name)))?;
        if address < self.base {
            return Err(me(format!("symbol {name} precedes base in {}", self.name)));
        }
        load_base
            .checked_add(address - self.base)
            .ok_or_else(|| me(format!("symbol {name} overflow")))
    }

    fn contains(&self, address: u64) -> bool {
        self.segments
            .iter()
            .any(|s| address >= s.address && address - s.address < s.size)
    }

    fn segment_for_data_offset(&self, file_off: u64) -> Option<&Segment> {
        self.segments
            .iter()
            .find(|s| file_off >= s.file_off && file_off < s.file_off + s.file_size)
    }

    fn put_pointer(&mut self, file_off: u64, value: u64) -> Result<(), Error> {
        let end = file_off.checked_add(8).ok_or_else(|| me("pointer overflow"))?;
        if end > self.data.len() as u64 {
            return Err(me(format!("fixup at {file_off:#x} exceeds {}", self.name)));
        }
        let i = file_off as usize;
        self.data[i..i + 8].copy_from_slice(&value.to_le_bytes());
        Ok(())
    }

    /// Relocate a standalone image to `load_base`, resolving imports via `resolve`.
    pub fn relocate(
        &mut self,
        load_base: u64,
        resolve: &mut dyn FnMut(&str) -> Result<u64, Error>,
    ) -> Result<(), Error> {
        if self.relocated {
            return Err(me(format!("{} already relocated", self.name)));
        }
        self.relocate_chained(load_base, resolve)?;
        self.relocated = true;
        self.loaded_base = load_base;
        Ok(())
    }

    fn relocate_chained(
        &mut self,
        load_base: u64,
        resolve: &mut dyn FnMut(&str) -> Result<u64, Error>,
    ) -> Result<(), Error> {
        let endian = Endianness::Little;
        let header = MachHeader64::<Endianness>::parse(&*self.data, 0)
            .map_err(|e| me(format!("{}: {e}", self.name)))?;

        // Locate LC_DYLD_CHAINED_FIXUPS; if absent, there is nothing to do here
        // (these prelinked Apple images use chained fixups exclusively).
        let mut chained_data: Option<(u32, u32)> = None;
        let mut commands = header
            .load_commands(endian, &*self.data, 0)
            .map_err(|e| me(format!("{}: {e}", self.name)))?;
        while let Some(command) = commands.next().map_err(|e| me(format!("{}: {e}", self.name)))? {
            if let LoadCommandVariant::LinkeditData(data) = command
                .variant()
                .map_err(|e| me(format!("{}: {e}", self.name)))?
            {
                if command.cmd() == macho::LC_DYLD_CHAINED_FIXUPS {
                    chained_data = Some((data.dataoff.get(endian), data.datasize.get(endian)));
                }
            }
        }
        let Some((off, size)) = chained_data else {
            return Ok(());
        };
        let blob = self
            .data
            .get(off as usize..(off as usize + size as usize))
            .ok_or_else(|| me("chained fixups blob out of range"))?
            .to_vec();

        let fixups = DyldChainedFixups::parse(endian, &blob)
            .map_err(|e| me(format!("{} chained fixups: {e}", self.name)))?;

        // Resolve import ordinals -> absolute addresses (+ their import addend).
        let mut imports: Vec<(u64, i64)> = Vec::new();
        let mut it = fixups
            .imports(endian)
            .map_err(|e| me(format!("{} imports: {e}", self.name)))?;
        while let Some(import) = it.next().map_err(|e| me(format!("{} import: {e}", self.name)))? {
            let sym = String::from_utf8_lossy(import.name).into_owned();
            let address = resolve(&sym)?;
            imports.push((address, import.addend));
        }

        // Walk every segment's fixup chain and write the resolved pointer back
        // into our in-memory image copy at the fixup's file offset.
        let mut writes: Vec<(u64, u64)> = Vec::new();
        let base = self.base;
        let seg_file: Vec<(u64, u64)> =
            self.segments.iter().map(|s| (s.file_off, s.file_size)).collect();
        let mut segs = fixups
            .segments(endian)
            .map_err(|e| me(format!("{} segments: {e}", self.name)))?;
        while let Some(seg) = segs.next().map_err(|e| me(format!("{} seg: {e}", self.name)))? {
            let idx = seg.index() as usize;
            let (foff, fsize) = *seg_file
                .get(idx)
                .ok_or_else(|| me("fixup segment index out of range"))?;
            let seg_data = self
                .data
                .get(foff as usize..(foff + fsize) as usize)
                .ok_or_else(|| me("fixup segment data out of range"))?;
            let mut chain = seg.fixups(endian, base, seg_data);
            while let Some((offset, fixup)) =
                chain.next().map_err(|e| me(format!("{} fixup: {e}", self.name)))?
            {
                let value = match fixup {
                    object::read::macho::Fixup::Rebase(rebase) => load_base
                        .checked_add(rebase.target_offset)
                        .ok_or_else(|| me("rebase overflow"))?,
                    object::read::macho::Fixup::Bind(bind) => {
                        let (address, import_addend) = *imports
                            .get(bind.ordinal as usize)
                            .ok_or_else(|| me("bind ordinal out of range"))?;
                        add_signed(address, import_addend + i64::from(bind.addend))?
                    }
                    object::read::macho::Fixup::KernelCacheRebase(rebase) => load_base
                        .checked_add(rebase.target_offset)
                        .ok_or_else(|| me("kernel rebase overflow"))?,
                    object::read::macho::Fixup::SegmentedRebase(_) => {
                        return Err(me(format!("{}: unsupported segmented rebase", self.name)))
                    }
                };
                writes.push((offset, value));
            }
        }
        for (offset, value) in writes {
            self.put_pointer(offset, value)?;
        }
        Ok(())
    }

    /// Prepare an image extracted from a dyld shared cache: it keeps its
    /// preferred addresses, and cache symbol slots are redirected to emulator
    /// shims (ports machimage.PreparePrelinked).
    pub fn prepare_prelinked(
        &mut self,
        external: &HashMap<u64, String>,
        resolve: &mut dyn FnMut(&str) -> Result<u64, Error>,
    ) -> Result<(), Error> {
        if self.relocated {
            return Err(me(format!("{} already relocated", self.name)));
        }
        let mut patched: HashMap<u64, u64> = HashMap::new();
        for (address, name) in external {
            patched.insert(*address, resolve(name)?);
        }

        let mut writes: Vec<(u64, u64)> = Vec::new();
        for seg in &self.segments {
            if seg.name == "__TEXT" || seg.name == "__LINKEDIT" || seg.file_size < POINTER {
                continue;
            }
            let mut start = seg.file_off;
            let remainder = seg.address % POINTER;
            if remainder != 0 {
                start += POINTER - remainder;
            }
            let end = seg.file_off + seg.file_size;
            let mut offset = start;
            while offset + POINTER <= end {
                let i = offset as usize;
                let current = u64::from_le_bytes(self.data[i..i + 8].try_into().unwrap());
                if let Some(value) = patched.get(&current) {
                    writes.push((offset, *value));
                }
                offset += POINTER;
            }
        }
        for (offset, value) in writes {
            self.put_pointer(offset, value)?;
        }
        self.relocated = true;
        self.loaded_base = self.base;
        Ok(())
    }

    /// Decode authenticated pointers in an image lifted from a kernel collection
    /// (ports machimage.RelocateKernelCachePointers). `kernel_base` is where the
    /// collection was originally based.
    pub fn relocate_kernel_cache_pointers(
        &mut self,
        load_base: u64,
        kernel_base: u64,
        resolve: &mut dyn FnMut(&str) -> Result<u64, Error>,
    ) -> Result<(), Error> {
        // External symbol value -> name, for pointers that leave this image.
        let external: HashMap<u64, String> = self
            .symbols
            .iter()
            .filter(|(_, &v)| v != 0 && !self.contains(v))
            .map(|(k, &v)| (v, k.clone()))
            .collect();

        const STRIDE: u64 = 4;
        let mut writes: Vec<(u64, u64)> = Vec::new();
        let seg_copies: Vec<(String, u64, u64, u64)> = self
            .segments
            .iter()
            .map(|s| (s.name.clone(), s.address, s.file_off, s.file_size))
            .collect();
        for (name, address, file_off, file_size) in seg_copies {
            if name == "__TEXT" || name == "__TEXT_EXEC" || name == "__LINKEDIT" || file_size < POINTER {
                continue;
            }
            let mut start = file_off;
            let remainder = address % STRIDE;
            if remainder != 0 {
                start += STRIDE - remainder;
            }
            let end = file_off + file_size;
            let mut offset = start;
            while offset + POINTER <= end {
                let i = offset as usize;
                let raw = u64::from_le_bytes(self.data[i..i + 8].try_into().unwrap());
                // DyldChainedPtr64KernelCacheRebase: target in low 30 bits, cacheLevel bits 30-31.
                let cache_level = (raw >> 30) & 0x3;
                let target = raw & 0x3fff_ffff;
                if cache_level != 0 || target == 0 {
                    offset += STRIDE;
                    continue;
                }
                let original = match kernel_base.checked_add(target) {
                    Some(v) => v,
                    None => {
                        offset += STRIDE;
                        continue;
                    }
                };
                let relocated = if self.contains(original) {
                    load_base
                        .checked_add(original - self.base)
                        .ok_or_else(|| me("kernel-cache pointer overflow"))?
                } else if let Some(sym) = external.get(&original) {
                    resolve(sym)?
                } else {
                    offset += STRIDE;
                    continue;
                };
                writes.push((offset, relocated));
                offset += STRIDE;
            }
        }
        for (offset, value) in writes {
            self.put_pointer(offset, value)?;
        }
        Ok(())
    }

    /// Map and populate the image's segments in guest memory.
    pub fn load(&self, memory: &mut dyn Memory) -> Result<(), Error> {
        if !self.relocated {
            return Err(me(format!("{} must be relocated before load", self.name)));
        }
        // Compute merged page-aligned ranges to map.
        let mut ranges: Vec<(u64, u64)> = Vec::new();
        for seg in &self.segments {
            if seg.name == "__PAGEZERO" || seg.size == 0 {
                continue;
            }
            if seg.address < self.base {
                return Err(me(format!("segment {} precedes base", seg.name)));
            }
            let address = self.loaded_base + (seg.address - self.base);
            let end = address + seg.size;
            ranges.push((address - address % PAGE, align(end, PAGE)));
        }
        if ranges.is_empty() {
            return Err(me(format!("{} has no loadable segments", self.name)));
        }
        ranges.sort_by_key(|r| r.0);
        let mut merged: Vec<(u64, u64)> = Vec::new();
        for current in ranges {
            if let Some(last) = merged.last_mut() {
                if current.0 <= last.1 {
                    last.1 = last.1.max(current.1);
                    continue;
                }
            }
            merged.push(current);
        }
        for (start, end) in &merged {
            memory.mem_map(*start, end - start)?;
        }
        // Write segment file data.
        for seg in &self.segments {
            if seg.name == "__PAGEZERO" || seg.file_size == 0 {
                continue;
            }
            let end = (seg.file_off + seg.file_size) as usize;
            let address = self.loaded_base + (seg.address - self.base);
            memory.mem_write(address, &self.data[seg.file_off as usize..end])?;
        }
        Ok(())
    }
}

/// Ports machimage.WithoutPointerAuthentication: rewrite ARM64e auth ops to
/// canonical unsigned equivalents; other instructions unchanged.
pub fn without_pointer_authentication(instruction: u32) -> u32 {
    const NOP: u32 = 0xd503201f;
    let replacement: u32 = match instruction & 0xfffffc00 {
        0xd71f0800 | 0xd71f0c00 | 0xd61f0800 | 0xd61f0c00 => 0xd61f0000 | (instruction & 0x3e0), // br xN
        0xd73f0800 | 0xd73f0c00 | 0xd63f0800 | 0xd63f0c00 => 0xd63f0000 | (instruction & 0x3e0), // blr xN
        0xdac10000 | 0xdac10400 | 0xdac10800 | 0xdac10c00 | 0xdac11000 | 0xdac11400
        | 0xdac11800 | 0xdac11c00 => NOP,
        _ => match instruction {
            0xd65f0bff | 0xd65f0fff => 0xd65f03c0, // ret
            0xd503211f | 0xd503215f | 0xd503219f | 0xd50321df | 0xd503233f | 0xd503237f
            | 0xd50323bf | 0xd50323ff | 0xd50320ff => NOP,
            _ => {
                let opcode = instruction & 0xffffffe0;
                if matches!(
                    opcode,
                    0xdac123e0
                        | 0xdac127e0
                        | 0xdac12be0
                        | 0xdac12fe0
                        | 0xdac133e0
                        | 0xdac137e0
                        | 0xdac13be0
                        | 0xdac13fe0
                        | 0xdac143e0
                        | 0xdac147e0
                ) {
                    NOP
                } else {
                    0
                }
            }
        },
    };
    if replacement == 0 {
        instruction
    } else {
        replacement
    }
}

fn add_signed(value: u64, delta: i64) -> Result<u64, Error> {
    if delta >= 0 {
        value.checked_add(delta as u64).ok_or_else(|| me("address overflow"))
    } else {
        let magnitude = (-(delta + 1)) as u64 + 1;
        if magnitude > value {
            return Err(me("address underflow"));
        }
        Ok(value - magnitude)
    }
}

/// Silence unused warnings for fields consulted only through methods above.
#[allow(dead_code)]
fn _touch_removed() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_macho_image() {
        assert!(Image::open("invalid", b"not an image").is_err());
    }
}

