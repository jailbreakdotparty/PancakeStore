//! arm64 Unicorn engine + shim-dispatch framework for the modern-ADI guest.
//!
//! Ports ipatool's internal/sap/machine {machine.go engine/invoke, shims.go,
//! shim_memory.go, arm64.go}. Same shape as our x86 `vm.rs`: imported functions
//! live on stub pages holding `ret`; a code hook over the shim region runs the
//! Rust handler, which sets X0 and returns. Platform services (dyld/Mach/XPC/
//! dispatch/FairPlay) are added by `shim_platform.rs`.

use std::collections::HashMap;

use unicorn_engine::unicorn_const::{Arch, HookType, MemType, Mode, Prot};
use unicorn_engine::{RegisterARM64, Unicorn};

use crate::Error;

pub const PAGE: u64 = 0x1000;
pub const RETURN_ADDRESS: u64 = 0x0000_0001_0000_0000;
pub const CORE_FP_BASE: u64 = 0x0000_1000_0000_0000;
pub const SCRATCH_BASE: u64 = 0x0000_3000_0000_0000;
pub const SCRATCH_SIZE: u64 = 32 << 20;
pub const HEAP_BASE: u64 = 0x0000_4000_0000_0000;
pub const HEAP_SIZE: u64 = 64 << 20;
pub const STACK_BASE: u64 = 0x0000_5000_0000_0000;
pub const STACK_SIZE: u64 = 8 << 20;
pub const STACK_END: u64 = STACK_BASE + STACK_SIZE;

pub const SHIM_BASE: u64 = 0x0000_7ff8_8000_0000;
pub const SHIM_CODE_SIZE: u64 = 0x0008_0000;
pub const SHIM_SIZE: u64 = 0x0010_0000;
pub const SHIM_SLOT: u64 = 16;

pub const MAX_GUEST_TRANSFER: u64 = 64 << 20;
pub const MAX_OUTPUT_SIZE: u64 = 16 << 20;
const GUEST_TIMEOUT_US: u64 = 60 * 1_000_000;

pub fn align(value: u64, alignment: u64) -> u64 {
    (value + alignment - 1) & !(alignment - 1)
}

#[derive(Clone, Copy)]
pub struct GuestAllocation {
    pub size: u64,
    pub reserved: u64,
}

#[derive(Clone, Copy)]
pub struct FreeBlock {
    pub address: u64,
    pub size: u64,
}

#[derive(Default)]
pub struct XpcObject {
    pub data: Vec<u8>,
    pub data_address: u64,
    pub has_data: bool,
}

/// Everything the guest's shims mutate. Stored as Unicorn user data (like
/// `vm.rs`'s `Env`). `handlers` maps a stub address to the handler to run.
#[derive(Default)]
pub struct SapState {
    pub handlers: HashMap<u64, Handler>,
    pub symbols: HashMap<String, u64>,
    pub code_cursor: u64,
    pub data_cursor: u64,
    pub fault: Option<String>,

    pub core_exports: HashMap<String, u64>,
    pub icxs: Vec<u8>,
    pub icxs_offset: usize,

    pub errno: u64,
    pub heap_cursor: u64,
    pub allocations: HashMap<u64, GuestAllocation>,
    pub free_blocks: Vec<FreeBlock>,
    pub iterator: u32,
    pub callback_returns: Vec<u64>,

    // XPC / Mach / FairPlay state (used by shim_platform + modern_adi)
    pub xpc_data: Vec<u8>,
    pub xpc_objects: HashMap<u64, XpcObject>,
    pub xpc_next_object: u64,
    pub xpc_event_handler: u64,
    pub xpc_reply: Vec<u8>,
    pub xpc_replied: bool,
    pub xpc_sync_reply: Vec<u8>,
    pub mach_port_callback: u64,
    pub mach_port_context: u64,
    pub mach_port_info: u64,
    pub mach_message_reply: Vec<u8>,

    pub adi_files: HashMap<String, Vec<u8>>,
    pub adi_path: String,
    pub adi_offset: usize,
    pub host_uuid: [u8; 16],
    pub pause_run_loop: bool,

    pub aes_vtable: u64,
    pub aes_service: u64,
    pub buffer_vtable: u64,
}

/// A shim handler identity. The dispatcher runs a big match on these; each
/// corresponds to an Apple/libSystem symbol (or group) the guest imports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handler {
    // Memory (shim_memory.go)
    Malloc,
    MallocAligned,
    MallocTyped,
    MallocTypedVariable,
    MallocLock,
    MallocGoodSize,
    MallocSize,
    Calloc,
    Realloc,
    Free,
    FreeTyped,
    Mmap,
    Munmap,
    VmAllocate,
    VmDeallocate,
    Memmove,
    Memset,
    Bzero,
    CheckedMemcpy,
    CheckedMemset,
    Memcmp,
    Strcmp,
    Strncmp,
    Strlen,
    Strnlen,
    // Generic
    ReturnZero,
    Unsupported,
    // Platform handlers are added by shim_platform.rs via this catch-all id set.
    Platform(PlatformHandler),
}

/// Placeholder enum for the platform services; filled in shim_platform.rs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlatformHandler {
    Unimplemented,
}

type Uc<'a> = Unicorn<'a, SapState>;

const ARG_REGS: [RegisterARM64; 8] = [
    RegisterARM64::X0,
    RegisterARM64::X1,
    RegisterARM64::X2,
    RegisterARM64::X3,
    RegisterARM64::X4,
    RegisterARM64::X5,
    RegisterARM64::X6,
    RegisterARM64::X7,
];

pub struct Engine {
    pub uc: Uc<'static>,
}

impl Engine {
    pub fn new() -> Result<Engine, Error> {
        let mut uc = Unicorn::new_with_data(Arch::ARM64, Mode::ARM, SapState::default())?;
        for (addr, size) in [
            (RETURN_ADDRESS, PAGE),
            (SCRATCH_BASE, SCRATCH_SIZE),
            (HEAP_BASE, HEAP_SIZE),
            (STACK_BASE, STACK_SIZE),
            (SHIM_BASE, SHIM_SIZE),
        ] {
            uc.mem_map(addr, size, Prot::ALL)?;
        }
        // `ret` at the return trampoline.
        uc.mem_write(RETURN_ADDRESS, &0xd65f03c0u32.to_le_bytes())?;

        {
            let st = uc.get_data_mut();
            st.code_cursor = SHIM_BASE;
            st.data_cursor = SHIM_BASE + SHIM_CODE_SIZE;
            st.heap_cursor = 0;
            st.xpc_next_object = 0xffff_0000_0000_0000;
        }

        // Dispatch hook over the shim code region.
        uc.add_code_hook(SHIM_BASE, SHIM_BASE + SHIM_CODE_SIZE - 1, |uc, addr, _| {
            let handler = match uc.get_data().handlers.get(&addr).copied() {
                Some(h) => h,
                None => {
                    uc.get_data_mut().fault =
                        Some(format!("guest entered unknown service address {addr:#x}"));
                    let _ = uc.emu_stop();
                    return;
                }
            };
            let mut st = std::mem::take(uc.get_data_mut());
            let result = st.dispatch(uc, handler);
            *uc.get_data_mut() = st;
            if let Err(message) = result {
                let data = uc.get_data_mut();
                if data.fault.is_none() {
                    data.fault = Some(message);
                }
                let _ = uc.emu_stop();
            }
        })?;

        // Fault on unmapped access, like vm.rs.
        uc.add_mem_hook(
            HookType::MEM_READ_UNMAPPED | HookType::MEM_WRITE_UNMAPPED | HookType::MEM_FETCH_UNMAPPED,
            0,
            u64::MAX,
            |uc, kind, addr, size, _| {
                let pc = uc.reg_read(RegisterARM64::PC).unwrap_or(0);
                let k = match kind {
                    MemType::READ_UNMAPPED => "read",
                    MemType::WRITE_UNMAPPED => "write",
                    _ => "fetch",
                };
                uc.get_data_mut().fault =
                    Some(format!("{k}-unmapped at {addr:#x} (size {size}) pc={pc:#x}"));
                false
            },
        )?;

        Ok(Engine { uc })
    }

    // --- memory / register access (ipatool unicorn.Engine API) ---
    pub fn mem_map(&mut self, address: u64, size: u64) -> Result<(), Error> {
        Ok(self.uc.mem_map(address, size, Prot::ALL)?)
    }
    pub fn mem_write(&mut self, address: u64, data: &[u8]) -> Result<(), Error> {
        Ok(self.uc.mem_write(address, data)?)
    }
    pub fn mem_read(&self, address: u64, len: u64) -> Result<Vec<u8>, Error> {
        Ok(self.uc.mem_read_as_vec(address, len as usize)?)
    }
    pub fn read_u32(&self, address: u64) -> Result<u32, Error> {
        Ok(u32::from_le_bytes(self.mem_read(address, 4)?.try_into().unwrap()))
    }
    pub fn read_u64(&self, address: u64) -> Result<u64, Error> {
        Ok(u64::from_le_bytes(self.mem_read(address, 8)?.try_into().unwrap()))
    }
    pub fn write_u64(&mut self, address: u64, value: u64) -> Result<(), Error> {
        self.mem_write(address, &value.to_le_bytes())
    }
    pub fn reg_write(&mut self, reg: RegisterARM64, value: u64) -> Result<(), Error> {
        Ok(self.uc.reg_write(reg, value)?)
    }
    pub fn reg_read(&self, reg: RegisterARM64) -> Result<u64, Error> {
        Ok(self.uc.reg_read(reg)?)
    }
    pub fn state(&self) -> &SapState {
        self.uc.get_data()
    }
    pub fn state_mut(&mut self) -> &mut SapState {
        self.uc.get_data_mut()
    }

    /// Resolve a symbol to a stub address, creating an "unsupported import" stub
    /// if unknown (ports shims.resolve).
    pub fn resolve(&mut self, name: &str) -> Result<u64, Error> {
        if let Some(&addr) = self.uc.get_data().symbols.get(name) {
            return Ok(addr);
        }
        self.add_function(name, Handler::Unsupported)
    }

    pub fn add_function(&mut self, name: &str, handler: Handler) -> Result<u64, Error> {
        if let Some(&addr) = self.uc.get_data().symbols.get(name) {
            return Ok(addr);
        }
        let cursor = self.uc.get_data().code_cursor;
        if cursor + SHIM_SLOT > SHIM_BASE + SHIM_CODE_SIZE {
            return Err(Error::Emulation("guest service code area full".into()));
        }
        self.uc.mem_write(cursor, &0xd65f03c0u32.to_le_bytes())?; // ret
        let st = self.uc.get_data_mut();
        st.code_cursor += SHIM_SLOT;
        st.handlers.insert(cursor, handler);
        st.symbols.insert(name.to_string(), cursor);
        Ok(cursor)
    }

    pub fn add_aliases(&mut self, names: &[&str], handler: Handler) -> Result<(), Error> {
        for name in names {
            self.add_function(name, handler)?;
        }
        Ok(())
    }

    pub fn add_data(&mut self, name: &str, data: &[u8]) -> Result<u64, Error> {
        if let Some(&addr) = self.uc.get_data().symbols.get(name) {
            return Ok(addr);
        }
        let mut cursor = align(self.uc.get_data().data_cursor, 8);
        if cursor + data.len() as u64 > SHIM_BASE + SHIM_SIZE {
            return Err(Error::Emulation("guest service data area full".into()));
        }
        self.uc.mem_write(cursor, data)?;
        let advance = data.len().max(8) as u64;
        let st = self.uc.get_data_mut();
        cursor = cursor; // keep clippy quiet
        st.data_cursor = align(st.data_cursor, 8) + advance;
        st.symbols.insert(name.to_string(), cursor);
        Ok(cursor)
    }

    pub fn register_memory_services(&mut self) -> Result<(), Error> {
        use Handler::*;
        let table: &[(&[&str], Handler)] = &[
            (&["_malloc", "_IOMalloc", "_IOMallocData"], Malloc),
            (&["_IOMallocAligned"], MallocAligned),
            (&["_IOMallocTypeImpl"], MallocTyped),
            (&["_IOMallocTypeVarImpl", "_OSObject_typed_operator_new"], MallocTypedVariable),
            (&["_IOLockAlloc", "_IORWLockAlloc"], MallocLock),
            (&["_malloc_good_size"], MallocGoodSize),
            (&["_malloc_size"], MallocSize),
            (&["_calloc"], Calloc),
            (&["_realloc", "_reallocf"], Realloc),
            (
                &[
                    "_free", "_IOFree", "_IOFreeAligned", "_IOFreeData", "_IOLockFree",
                    "_IORWLockFree", "_OSObject_typed_operator_delete",
                ],
                Free,
            ),
            (&["_IOFreeTypeImpl", "_IOFreeTypeVarImpl"], FreeTyped),
            (&["_mmap"], Mmap),
            (&["_munmap"], Munmap),
            (&["_vm_allocate"], VmAllocate),
            (&["_vm_deallocate"], VmDeallocate),
            (&["_memcpy", "_memmove"], Memmove),
            (&["_memset"], Memset),
            (&["___bzero"], Bzero),
            (&["___memcpy_chk"], CheckedMemcpy),
            (&["___memset_chk"], CheckedMemset),
            (&["_memcmp"], Memcmp),
            (&["_strcmp"], Strcmp),
            (&["_strncmp"], Strncmp),
            (&["_strlen"], Strlen),
            (&["_strnlen"], Strnlen),
        ];
        for (names, handler) in table {
            self.add_aliases(names, *handler)?;
        }
        Ok(())
    }

    /// Run `function(args...)` to the return trampoline; returns X0.
    /// Ports machine.invoke including the arm64 invalid-instruction retry.
    pub fn invoke(&mut self, function: u64, args: &[u64]) -> Result<u64, Error> {
        if function == 0 {
            return Err(Error::Emulation("guest entry point unavailable".into()));
        }
        for (i, reg) in ARG_REGS.iter().enumerate() {
            self.uc.reg_write(*reg, args.get(i).copied().unwrap_or(0))?;
        }
        let extra = args.len().saturating_sub(ARG_REGS.len());
        let mut sp = STACK_END - (extra as u64) * 8;
        sp -= sp % 16;
        for i in 0..extra {
            self.uc.mem_write(sp + (i as u64) * 8, &args[ARG_REGS.len() + i].to_le_bytes())?;
        }
        self.uc.reg_write(RegisterARM64::SP, sp)?;
        self.uc.reg_write(RegisterARM64::X30, RETURN_ADDRESS)?; // LR
        self.uc.get_data_mut().fault = None;

        let mut next = function;
        loop {
            let res = self.uc.emu_start(next, RETURN_ADDRESS, GUEST_TIMEOUT_US, 0);
            if let Some(fault) = self.uc.get_data_mut().fault.take() {
                return Err(Error::Emulation(fault));
            }
            match res {
                Ok(()) => break,
                Err(_) => {
                    if self.emulate_invalid_instruction()? {
                        next = self.uc.reg_read(RegisterARM64::PC)?;
                        continue;
                    }
                    let pc = self.uc.reg_read(RegisterARM64::PC).unwrap_or(0);
                    return Err(Error::Emulation(format!("guest fault at pc={pc:#x}: {res:?}")));
                }
            }
        }
        let pc = self.uc.reg_read(RegisterARM64::PC)?;
        if pc != RETURN_ADDRESS {
            return Err(Error::Emulation(format!("guest stopped at {pc:#x}")));
        }
        Ok(self.uc.reg_read(RegisterARM64::X0)?)
    }

    /// Ports arm64.go: emulate CASAL/SWPAL (LSE atomics) and EOR3 that the TCI
    /// interpreter rejects. Returns true if it handled and advanced PC.
    fn emulate_invalid_instruction(&mut self) -> Result<bool, Error> {
        let pc = self.uc.reg_read(RegisterARM64::PC)?;
        let data = match self.uc.mem_read_as_vec(pc, 4) {
            Ok(d) => d,
            Err(_) => return Ok(false),
        };
        let inst = u32::from_le_bytes(data.try_into().unwrap());

        const EOR3_MASK: u32 = 0xffe08000;
        const EOR3: u32 = 0xce000000;
        if inst & EOR3_MASK == EOR3 {
            self.emulate_eor3(inst)?;
            self.uc.reg_write(RegisterARM64::PC, pc + 4)?;
            return Ok(true);
        }

        const ATOMIC_MASK: u32 = 0xffe0fc00;
        const CASAL32: u32 = 0x88e0fc00;
        const CASAL64: u32 = 0xc8e0fc00;
        const SWPAL32: u32 = 0xb8e08000;
        const SWPAL64: u32 = 0xf8e08000;
        let opcode = inst & ATOMIC_MASK;
        let width: u64 = match opcode {
            CASAL32 | SWPAL32 => 4,
            CASAL64 | SWPAL64 => 8,
            _ => return Ok(false),
        };
        let source = (inst >> 16) & 31;
        let base = (inst >> 5) & 31;
        let destination = inst & 31;
        let address = self.read_base_register(base)?;
        let mem = self.uc.mem_read_as_vec(address, width as usize)?;
        let mut old_bytes = [0u8; 8];
        old_bytes[..width as usize].copy_from_slice(&mem);
        let old_value = u64::from_le_bytes(old_bytes);
        let mut source_value = self.read_value_register(source)?;
        if width == 4 {
            source_value = source_value as u32 as u64;
        }
        match opcode {
            CASAL32 | CASAL64 => {
                let mut new_value = self.read_value_register(destination)?;
                if width == 4 {
                    new_value = new_value as u32 as u64;
                }
                if old_value == source_value {
                    self.write_memory_value(address, new_value, width)?;
                }
                self.write_value_register(source, old_value)?;
            }
            SWPAL32 | SWPAL64 => {
                self.write_memory_value(address, source_value, width)?;
                self.write_value_register(destination, old_value)?;
            }
            _ => unreachable!(),
        }
        self.uc.reg_write(RegisterARM64::PC, pc + 4)?;
        Ok(true)
    }

    fn emulate_eor3(&mut self, inst: u32) -> Result<(), Error> {
        let d = inst & 31;
        let a = (inst >> 5) & 31;
        let m = (inst >> 10) & 31;
        let n = (inst >> 16) & 31;
        let va = self.read_vector(a)?;
        let vn = self.read_vector(n)?;
        let vm = self.read_vector(m)?;
        let mut r = [0u8; 16];
        for i in 0..16 {
            r[i] = va[i] ^ vn[i] ^ vm[i];
        }
        self.write_vector(d, r)
    }

    fn read_vector(&self, index: u32) -> Result<[u8; 16], Error> {
        let reg = vreg(index);
        let raw = self.uc.reg_read_long(reg)?;
        let mut out = [0u8; 16];
        let n = raw.len().min(16);
        out[..n].copy_from_slice(&raw[..n]);
        Ok(out)
    }
    fn write_vector(&mut self, index: u32, value: [u8; 16]) -> Result<(), Error> {
        Ok(self.uc.reg_write_long(vreg(index), &value)?)
    }

    fn general_register(index: u32) -> Option<RegisterARM64> {
        Some(match index {
            0..=28 => GP_REGS[index as usize],
            29 => RegisterARM64::X29,
            30 => RegisterARM64::X30,
            _ => return None,
        })
    }
    fn read_base_register(&self, index: u32) -> Result<u64, Error> {
        let reg = if index == 31 {
            RegisterARM64::SP
        } else {
            Self::general_register(index).ok_or_else(|| Error::Emulation("bad base reg".into()))?
        };
        self.reg_read(reg)
    }
    fn read_value_register(&self, index: u32) -> Result<u64, Error> {
        if index == 31 {
            return Ok(0);
        }
        let reg = Self::general_register(index).ok_or_else(|| Error::Emulation("bad reg".into()))?;
        self.reg_read(reg)
    }
    fn write_value_register(&mut self, index: u32, value: u64) -> Result<(), Error> {
        if index == 31 {
            return Ok(());
        }
        let reg = Self::general_register(index).ok_or_else(|| Error::Emulation("bad reg".into()))?;
        self.reg_write(reg, value)
    }
    fn write_memory_value(&mut self, address: u64, value: u64, width: u64) -> Result<(), Error> {
        let bytes = value.to_le_bytes();
        self.mem_write(address, &bytes[..width as usize])
    }
}

const GP_REGS: [RegisterARM64; 29] = [
    RegisterARM64::X0, RegisterARM64::X1, RegisterARM64::X2, RegisterARM64::X3,
    RegisterARM64::X4, RegisterARM64::X5, RegisterARM64::X6, RegisterARM64::X7,
    RegisterARM64::X8, RegisterARM64::X9, RegisterARM64::X10, RegisterARM64::X11,
    RegisterARM64::X12, RegisterARM64::X13, RegisterARM64::X14, RegisterARM64::X15,
    RegisterARM64::X16, RegisterARM64::X17, RegisterARM64::X18, RegisterARM64::X19,
    RegisterARM64::X20, RegisterARM64::X21, RegisterARM64::X22, RegisterARM64::X23,
    RegisterARM64::X24, RegisterARM64::X25, RegisterARM64::X26, RegisterARM64::X27,
    RegisterARM64::X28,
];

const V_REGS: [RegisterARM64; 32] = [
    RegisterARM64::V0, RegisterARM64::V1, RegisterARM64::V2, RegisterARM64::V3,
    RegisterARM64::V4, RegisterARM64::V5, RegisterARM64::V6, RegisterARM64::V7,
    RegisterARM64::V8, RegisterARM64::V9, RegisterARM64::V10, RegisterARM64::V11,
    RegisterARM64::V12, RegisterARM64::V13, RegisterARM64::V14, RegisterARM64::V15,
    RegisterARM64::V16, RegisterARM64::V17, RegisterARM64::V18, RegisterARM64::V19,
    RegisterARM64::V20, RegisterARM64::V21, RegisterARM64::V22, RegisterARM64::V23,
    RegisterARM64::V24, RegisterARM64::V25, RegisterARM64::V26, RegisterARM64::V27,
    RegisterARM64::V28, RegisterARM64::V29, RegisterARM64::V30, RegisterARM64::V31,
];

fn vreg(index: u32) -> RegisterARM64 {
    V_REGS[(index as usize) & 31]
}

// --- shim argument / result helpers + dispatch (methods on SapState) ---

fn arg(uc: &Uc<'_>, i: usize) -> u64 {
    if i < ARG_REGS.len() {
        return uc.reg_read(ARG_REGS[i]).unwrap_or(0);
    }
    let sp = uc.reg_read(RegisterARM64::SP).unwrap_or(0);
    uc.mem_read_as_vec(sp + ((i - ARG_REGS.len()) as u64) * 8, 8)
        .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
        .unwrap_or(0)
}

fn set_result(uc: &mut Uc<'_>, value: u64) {
    let _ = uc.reg_write(RegisterARM64::X0, value);
}

fn read_cstring(uc: &Uc<'_>, mut address: u64) -> String {
    let mut out = Vec::new();
    while out.len() < 4096 {
        match uc.mem_read_as_vec(address, 1) {
            Ok(b) if b[0] != 0 => {
                out.push(b[0]);
                address += 1;
            }
            _ => break,
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl SapState {
    fn dispatch(&mut self, uc: &mut Uc<'_>, handler: Handler) -> Result<(), String> {
        use Handler::*;
        match handler {
            Malloc => {
                let size = arg(uc, 0);
                let a = self.allocate(uc, size)?;
                set_result(uc, a);
            }
            MallocAligned => {
                let size = arg(uc, 0);
                let alignment = arg(uc, 1);
                if alignment == 0 || alignment & (alignment - 1) != 0 {
                    return Err(format!("invalid allocation alignment {alignment:#x}"));
                }
                let a = self.allocate_aligned(uc, size, alignment)?;
                set_result(uc, a);
            }
            MallocTyped => {
                let view = arg(uc, 0);
                let size = read_u32(uc, view + 44)? & 0x00ff_ffff;
                let a = self.allocate(uc, size as u64)?;
                set_result(uc, a);
            }
            MallocTypedVariable => {
                let size = arg(uc, 1);
                let a = self.allocate(uc, size)?;
                set_result(uc, a);
            }
            MallocLock => {
                let a = self.allocate(uc, 8)?;
                uc.mem_write(a, &[0u8; 8]).map_err(ue)?;
                set_result(uc, a);
            }
            MallocGoodSize => set_result(uc, align(arg(uc, 0).max(1), 16)),
            MallocSize => {
                let a = arg(uc, 0);
                set_result(uc, self.allocations.get(&a).map(|x| x.reserved).unwrap_or(0));
            }
            Calloc => {
                let count = arg(uc, 0);
                let size = arg(uc, 1);
                if count != 0 && size > u64::MAX / count {
                    return Err("allocation size overflows".into());
                }
                let total = count * size;
                let a = self.allocate(uc, total)?;
                if total != 0 {
                    uc.mem_write(a, &vec![0u8; total as usize]).map_err(ue)?;
                }
                set_result(uc, a);
            }
            Realloc => {
                let old = arg(uc, 0);
                let new_size = arg(uc, 1);
                if old == 0 {
                    let a = self.allocate(uc, new_size)?;
                    set_result(uc, a);
                } else {
                    let oldalloc = *self
                        .allocations
                        .get(&old)
                        .ok_or_else(|| format!("reallocate unknown pointer {old:#x}"))?;
                    if new_size <= oldalloc.reserved {
                        let mut a = oldalloc;
                        a.size = new_size;
                        self.allocations.insert(old, a);
                        set_result(uc, old);
                    } else {
                        let newaddr = self.allocate(uc, new_size)?;
                        let data = uc.mem_read_as_vec(old, oldalloc.size as usize).map_err(ue)?;
                        uc.mem_write(newaddr, &data).map_err(ue)?;
                        self.release(uc, old)?;
                        set_result(uc, newaddr);
                    }
                }
            }
            Free => {
                let a = arg(uc, 0);
                if a != 0 {
                    self.release(uc, a)?;
                }
                set_result(uc, 0);
            }
            FreeTyped => {
                let a = arg(uc, 1);
                if a != 0 {
                    self.release(uc, a)?;
                }
                set_result(uc, 0);
            }
            Mmap => {
                let length = arg(uc, 1);
                match self.allocate_aligned(uc, length, PAGE) {
                    Ok(a) => {
                        uc.mem_write(a, &vec![0u8; length as usize]).map_err(ue)?;
                        set_result(uc, a);
                    }
                    Err(_) => set_result(uc, u64::MAX),
                }
            }
            Munmap => {
                let a = arg(uc, 0);
                match self.release(uc, a) {
                    Ok(()) => set_result(uc, 0),
                    Err(_) => set_result(uc, u64::MAX),
                }
            }
            VmAllocate => {
                let field = arg(uc, 1);
                let size = arg(uc, 2);
                match self.allocate_aligned(uc, size, PAGE) {
                    Ok(a) => {
                        uc.mem_write(a, &vec![0u8; size as usize]).map_err(ue)?;
                        write_u64(uc, field, a)?;
                        set_result(uc, 0);
                    }
                    Err(_) => set_result(uc, 3), // KERN_NO_SPACE
                }
            }
            VmDeallocate => {
                let a = arg(uc, 1);
                match self.release(uc, a) {
                    Ok(()) => set_result(uc, 0),
                    Err(_) => set_result(uc, 1), // KERN_INVALID_ADDRESS
                }
            }
            Memmove => {
                let dst = arg(uc, 0);
                let src = arg(uc, 1);
                let len = arg(uc, 2);
                checked_size(len)?;
                let data = uc.mem_read_as_vec(src, len as usize).map_err(ue)?;
                uc.mem_write(dst, &data).map_err(ue)?;
                set_result(uc, dst);
            }
            Memset => {
                let dst = arg(uc, 0);
                let value = arg(uc, 1) as u8;
                let len = checked_size(arg(uc, 2))?;
                uc.mem_write(dst, &vec![value; len]).map_err(ue)?;
                set_result(uc, dst);
            }
            Bzero => {
                let dst = arg(uc, 0);
                let len = checked_size(arg(uc, 1))?;
                uc.mem_write(dst, &vec![0u8; len]).map_err(ue)?;
                set_result(uc, dst);
            }
            CheckedMemcpy => {
                let len = arg(uc, 2);
                let cap = arg(uc, 3);
                if len > cap {
                    return Err("checked copy exceeds destination".into());
                }
                return self.dispatch(uc, Memmove);
            }
            CheckedMemset => {
                let len = arg(uc, 2);
                let cap = arg(uc, 3);
                if len > cap {
                    return Err("checked fill exceeds destination".into());
                }
                return self.dispatch(uc, Memset);
            }
            Memcmp => {
                let left = arg(uc, 0);
                let right = arg(uc, 1);
                let len = arg(uc, 2);
                checked_size(len)?;
                let a = uc.mem_read_as_vec(left, len as usize).map_err(ue)?;
                let b = uc.mem_read_as_vec(right, len as usize).map_err(ue)?;
                set_result(uc, cmp_to_u64(a.cmp(&b)));
            }
            Strcmp => {
                let a = read_cstring(uc, arg(uc, 0));
                let b = read_cstring(uc, arg(uc, 1));
                set_result(uc, cmp_to_u64(a.as_bytes().cmp(b.as_bytes())));
            }
            Strncmp => {
                let left = arg(uc, 0);
                let right = arg(uc, 1);
                let len = arg(uc, 2);
                checked_size(len)?;
                let a = uc.mem_read_as_vec(left, len as usize).map_err(ue)?;
                let b = uc.mem_read_as_vec(right, len as usize).map_err(ue)?;
                let mut result = 0u64;
                for i in 0..len as usize {
                    if a[i] != b[i] {
                        result = (a[i] as i64 - b[i] as i64) as u64;
                        break;
                    }
                    if a[i] == 0 {
                        break;
                    }
                }
                set_result(uc, result);
            }
            Strlen => {
                let v = read_cstring(uc, arg(uc, 0));
                set_result(uc, v.len() as u64);
            }
            Strnlen => {
                let address = arg(uc, 0);
                let limit = arg(uc, 1);
                if limit > MAX_GUEST_TRANSFER {
                    return Err(format!("strnlen limit {limit} too large"));
                }
                let data = uc.mem_read_as_vec(address, limit as usize).map_err(ue)?;
                let n = data.iter().position(|&b| b == 0).unwrap_or(limit as usize);
                set_result(uc, n as u64);
            }
            ReturnZero => set_result(uc, 0),
            Unsupported => return Err("guest called unsupported import".into()),
            Platform(_) => {
                // Routed in shim_platform.rs (added later); fault for now.
                return Err("unimplemented platform service".into());
            }
        }
        Ok(())
    }

    fn allocate(&mut self, uc: &mut Uc<'_>, size: u64) -> Result<u64, String> {
        if size > MAX_GUEST_TRANSFER {
            return Err(format!("allocation size {size} exceeds limit"));
        }
        let reserved = align(size.max(1), 16);
        if let Some(index) = self.free_blocks.iter().position(|b| b.size >= reserved) {
            let block = self.free_blocks[index];
            let address = block.address;
            if block.size == reserved {
                self.free_blocks.remove(index);
            } else {
                self.free_blocks[index].address += reserved;
                self.free_blocks[index].size -= reserved;
            }
            self.allocations.insert(address, GuestAllocation { size, reserved });
            return Ok(address);
        }
        if self.heap_cursor > HEAP_SIZE || reserved > HEAP_SIZE - self.heap_cursor {
            return Err("guest heap exhausted".into());
        }
        let address = HEAP_BASE + self.heap_cursor;
        self.heap_cursor += reserved;
        self.allocations.insert(address, GuestAllocation { size, reserved });
        let _ = uc;
        Ok(address)
    }

    fn allocate_aligned(&mut self, _uc: &mut Uc<'_>, size: u64, alignment: u64) -> Result<u64, String> {
        if size > MAX_GUEST_TRANSFER {
            return Err(format!("allocation size {size} exceeds limit"));
        }
        let reserved = align(size.max(1), alignment);
        let cursor = align(self.heap_cursor, alignment);
        if cursor > HEAP_SIZE || reserved > HEAP_SIZE - cursor {
            return Err("guest heap exhausted".into());
        }
        let address = HEAP_BASE + cursor;
        self.heap_cursor = cursor + reserved;
        self.allocations.insert(address, GuestAllocation { size, reserved });
        Ok(address)
    }

    fn release(&mut self, uc: &mut Uc<'_>, address: u64) -> Result<(), String> {
        let allocation = *self
            .allocations
            .get(&address)
            .ok_or_else(|| format!("free unknown pointer {address:#x}"))?;
        uc.mem_write(address, &vec![0u8; allocation.reserved as usize]).map_err(ue)?;
        self.allocations.remove(&address);
        self.free_blocks.push(FreeBlock { address, size: allocation.reserved });
        self.coalesce_free_blocks();
        Ok(())
    }

    fn coalesce_free_blocks(&mut self) {
        self.free_blocks.sort_by_key(|b| b.address);
        let mut merged: Vec<FreeBlock> = Vec::new();
        for block in self.free_blocks.drain(..) {
            if let Some(last) = merged.last_mut() {
                if last.address + last.size == block.address {
                    last.size += block.size;
                    continue;
                }
            }
            merged.push(block);
        }
        self.free_blocks = merged;
        while let Some(last) = self.free_blocks.last().copied() {
            if last.address + last.size != HEAP_BASE + self.heap_cursor {
                break;
            }
            self.heap_cursor -= last.size;
            self.free_blocks.pop();
        }
    }
}

fn ue(e: unicorn_engine::unicorn_const::uc_error) -> String {
    format!("unicorn: {e:?}")
}

fn read_u32(uc: &Uc<'_>, address: u64) -> Result<u32, String> {
    let b = uc.mem_read_as_vec(address, 4).map_err(ue)?;
    Ok(u32::from_le_bytes(b.try_into().unwrap()))
}

fn write_u64(uc: &mut Uc<'_>, address: u64, value: u64) -> Result<(), String> {
    uc.mem_write(address, &value.to_le_bytes()).map_err(ue)
}

fn checked_size(value: u64) -> Result<usize, String> {
    if value > MAX_GUEST_TRANSFER {
        return Err(format!("guest transfer size {value} exceeds limit"));
    }
    Ok(value as usize)
}

fn cmp_to_u64(ordering: std::cmp::Ordering) -> u64 {
    match ordering {
        std::cmp::Ordering::Less => (-1i64) as u64,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }
}
