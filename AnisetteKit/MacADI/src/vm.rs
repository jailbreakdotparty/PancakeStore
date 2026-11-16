//! Unicorn x86_64 runtime for the Mac CoreADI dylib, plus the synthetic macOS userland it talks to.
//!
//! The dylib's preferred base is 0, so every segment is mapped at its literal vmaddr and no rebasing
//! is done. Each imported function gets a stub address holding `ret`; a code hook on the stub page
//! runs the Rust handler and the `ret` returns to the caller. Imported data symbols point at
//! per-symbol cells. This mirrors `tools/machoadi/{harness,stubs}.py`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

use unicorn_engine::unicorn_const::{Arch, HookType, MemType, Mode, Prot};
use unicorn_engine::{RegisterX86, Unicorn};

use crate::macho::MachO;
use crate::Error;

const PAGE: u64 = 0x1000;
const RETURN_ADDRESS: u64 = 0x4000_0000;
const HEAP_ADDRESS: u64 = 0x4001_0000;
const HEAP_SIZE: u64 = 0x0100_0000;
const STACK_ADDRESS: u64 = 0x5000_0000;
const STACK_SIZE: u64 = 0x0020_0000;
const STUB_ADDRESS: u64 = 0x6000_0000;
const STUB_SIZE: u64 = 0x2_0000;
const DATA_ADDRESS: u64 = 0x6002_0000;
const DATA_SIZE: u64 = 0x2_0000;
const SCRATCH_ADDRESS: u64 = 0x6004_0000;
const SCRATCH_SIZE: u64 = 0x4_0000;
const OBJECT_ADDRESS: u64 = 0x6008_0000;
const OBJECT_SIZE: u64 = 0x4_0000;
const SLOT: u64 = 0x10;

pub const STORE_DIR: &str = "/Users/Shared/adi";

const STAT_SIZE: usize = 144;
const STATFS_SIZE: usize = 2168;
const S_IFDIR: u16 = 0o040000;
const S_IFREG: u16 = 0o100000;
const O_CREAT: u64 = 0x0200;
const O_TRUNC: u64 = 0x0400;
const ENOENT: u64 = 2;
const EBADF: u64 = 9;
const EEXIST: u64 = 17;
const EISDIR: u64 = 21;

const DATA_SYMBOLS: [&str; 10] = [
    "stack_chk_guard",
    "kCFAllocatorDefault",
    "kCFBooleanFalse",
    "kCFBooleanTrue",
    "kCFErrorDomainOSStatus",
    "kCFURLFileSecurityKey",
    "kCFURLIsDirectoryKey",
    "kCFURLIsHiddenKey",
    "kCFURLTypeIdentifierKey",
    "kUTTypePlainText",
];

fn norm(s: &str) -> &str {
    s.trim_start_matches('_')
}

#[derive(Clone, Copy)]
enum H {
    Abort,
    Ret(u64),
    Arc4Buf,
    HostUuid,
    TimeOfDay,
    Errno,
    ObjcMsgSend,
    Malloc,
    Open,
    Close,
    Read,
    Write,
    Lstat,
    Fstat,
    Statfs,
    Mkdir,
    Unlink,
    Chmod,
    Ftruncate,
    Getenv,
    CfurlCreate,
    CfurlCopyProp,
}

fn handler_for(name: &str) -> Option<H> {
    Some(match name {
        "stack_chk_fail" => H::Abort,
        "pthread_rwlock_init" | "pthread_rwlock_rdlock" | "pthread_rwlock_wrlock" | "pthread_rwlock_unlock"
        | "pthread_rwlock_destroy" => H::Ret(0),
        "getuid" => H::Ret(501),
        "umask" => H::Ret(0o022),
        "arc4random" => H::Ret(0x1234_5678),
        "arc4random_buf" => H::Arc4Buf,
        "gethostuuid" => H::HostUuid,
        "gettimeofday" => H::TimeOfDay,
        "error" => H::Errno,
        "objc_msgSend" => H::ObjcMsgSend,
        "NSVersionOfRunTimeLibrary" => H::Ret(0x1_0000_0000),
        "CFErrorGetCode" | "CFErrorGetDomain" | "CFRelease" | "CSBackupIsItemExcluded" | "notify_post" => H::Ret(0),
        "CSBackupSetItemExcluded" | "CFFileSecuritySetMode" | "CFURLSetResourcePropertyForKey" => H::Ret(1),
        "malloc" => H::Malloc,
        "free" | "fchmod" | "fcntl" | "lockf" => H::Ret(0),
        "open" => H::Open,
        "close" => H::Close,
        "read" => H::Read,
        "write" => H::Write,
        "lstat$INODE64" | "stat$INODE64" => H::Lstat,
        "fstat$INODE64" => H::Fstat,
        "statfs$INODE64" => H::Statfs,
        "mkdir" => H::Mkdir,
        "unlink" => H::Unlink,
        "chmod" => H::Chmod,
        "ftruncate" => H::Ftruncate,
        "getenv" => H::Getenv,
        "CFURLCreateFromFileSystemRepresentation" => H::CfurlCreate,
        "CFURLCopyResourcePropertyForKey" => H::CfurlCopyProp,
        _ => return None,
    })
}

struct Fd {
    path: String,
    off: usize,
}

#[derive(Default)]
struct Env {
    handlers: HashMap<u64, H>,
    object_of: HashMap<String, u64>,
    key_by_object: HashMap<u64, String>,
    heap_cur: u64,
    scratch_cur: u64,
    scratch_base: u64,
    obj_cur: u64,
    next_url: u64,
    errno_addr: u64,
    getenv_addr: HashMap<&'static str, u64>,
    files: BTreeMap<String, Vec<u8>>,
    dirs: HashSet<String>,
    fds: HashMap<u64, Fd>,
    next_fd: u64,
    urls: HashMap<u64, String>,
    host_uuid: [u8; 16],
    /// `Some(secs)` pins `gettimeofday`; `None` is the real clock.
    frozen_time: Option<u64>,
    fault: Option<String>,
}

type Uc<'a> = Unicorn<'a, Env>;

fn reg(i: usize) -> RegisterX86 {
    [RegisterX86::RDI, RegisterX86::RSI, RegisterX86::RDX, RegisterX86::RCX, RegisterX86::R8, RegisterX86::R9][i]
}

fn arg(uc: &Uc<'_>, i: usize) -> u64 {
    uc.reg_read(reg(i)).unwrap_or(0)
}

fn cstr(uc: &Uc<'_>, addr: u64) -> String {
    let mut out = Vec::new();
    while out.len() < 4096 {
        match uc.mem_read_as_vec(addr + out.len() as u64, 1) {
            Ok(b) if b[0] != 0 => out.push(b[0]),
            _ => break,
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn w32(uc: &mut Uc<'_>, addr: u64, v: u32) {
    let _ = uc.mem_write(addr, &v.to_le_bytes());
}

fn w64(uc: &mut Uc<'_>, addr: u64, v: u64) {
    let _ = uc.mem_write(addr, &v.to_le_bytes());
}

fn r64(uc: &Uc<'_>, addr: u64) -> u64 {
    uc.mem_read_as_vec(addr, 8).map(|b| u64::from_le_bytes(b.try_into().unwrap())).unwrap_or(0)
}

fn inode(path: &str) -> u64 {
    // CRC-32 as in the Python harness (zlib.crc32), so inodes are stable per path.
    let mut crc = !0u32;
    for &b in path.as_bytes() {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (!(crc & 1)).wrapping_add(1));
        }
    }
    0x10000 + u64::from(!crc & 0xF_FFFF)
}

impl Env {
    fn bump_scratch(&mut self, size: u64) -> u64 {
        let addr = self.scratch_cur;
        self.scratch_cur += (size + 0xF) & !0xF;
        addr
    }

    fn fail(&mut self, uc: &mut Uc<'_>, err: u64) -> u64 {
        w32(uc, self.errno_addr, err as u32);
        u64::MAX
    }

    fn fill_stat(&self, uc: &mut Uc<'_>, addr: u64, path: &str, is_dir: bool, size: i64) {
        let mut b = [0u8; STAT_SIZE];
        b[0..4].copy_from_slice(&0x100_0003u32.to_le_bytes());
        b[4..6].copy_from_slice(&((if is_dir { S_IFDIR } else { S_IFREG }) | 0o755).to_le_bytes());
        b[6..8].copy_from_slice(&(if is_dir { 2u16 } else { 1 }).to_le_bytes());
        b[8..16].copy_from_slice(&inode(path).to_le_bytes());
        b[16..20].copy_from_slice(&501u32.to_le_bytes());
        b[20..24].copy_from_slice(&20u32.to_le_bytes());
        b[96..104].copy_from_slice(&size.to_le_bytes());
        b[104..112].copy_from_slice(&((size + 511) / 512).to_le_bytes());
        b[112..116].copy_from_slice(&4096i32.to_le_bytes());
        let _ = uc.mem_write(addr, &b);
    }

    fn call(&mut self, uc: &mut Uc<'_>, h: H) -> Option<u64> {
        Some(match h {
            H::Abort => {
                self.fault = Some("stack check failed".into());
                let _ = uc.emu_stop();
                return None;
            }
            H::Ret(v) => v,
            H::Arc4Buf => {
                let (buf, n) = (arg(uc, 0), arg(uc, 1) as usize);
                let bytes: Vec<u8> = (0..n).map(|i| (i * 7 + 3) as u8).collect();
                let _ = uc.mem_write(buf, &bytes);
                0
            }
            H::HostUuid => {
                let _ = uc.mem_write(arg(uc, 0), &self.host_uuid);
                0
            }
            H::TimeOfDay => {
                let tv = arg(uc, 0);
                if tv != 0 {
                    let (s, us) = match self.frozen_time {
                        Some(s) => (s, 0),
                        None => {
                            let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
                            (d.as_secs(), u64::from(d.subsec_micros()))
                        }
                    };
                    w64(uc, tv, s);
                    w64(uc, tv + 8, us);
                }
                0
            }
            H::Errno => self.errno_addr,
            H::ObjcMsgSend => {
                let sel = cstr(uc, arg(uc, 1));
                match sel.as_str() {
                    "processInfo" => {
                        let a = self.obj_cur;
                        self.obj_cur += 0x100;
                        a
                    }
                    "operatingSystem" => 0x0D,
                    "isOperatingSystemAtLeastVersion:" => 1,
                    _ => 0,
                }
            }
            H::Malloc => {
                // Bump allocator, like the validated Python harness. Nothing is freed: the VM is
                // reset to its post-load snapshot between sessions (`Vm::reset_session`) instead.
                let size = (arg(uc, 0).max(0x20) + 0xF) & !0xF;
                let addr = self.heap_cur;
                if addr + size > HEAP_ADDRESS + HEAP_SIZE {
                    self.fault = Some("emulated heap exhausted".into());
                    let _ = uc.emu_stop();
                    return None;
                }
                self.heap_cur = addr + size;
                addr
            }
            H::Open => {
                let path = cstr(uc, arg(uc, 0));
                let flags = arg(uc, 1);
                if let Some(f) = self.files.get_mut(&path) {
                    if flags & O_TRUNC != 0 {
                        f.clear();
                    }
                } else if flags & O_CREAT != 0 {
                    self.files.insert(path.clone(), Vec::new());
                } else if self.dirs.contains(&path) {
                    return Some(self.fail(uc, EISDIR));
                } else {
                    return Some(self.fail(uc, ENOENT));
                }
                let fd = self.next_fd;
                self.next_fd += 1;
                self.fds.insert(fd, Fd { path, off: 0 });
                fd
            }
            H::Close => {
                self.fds.remove(&arg(uc, 0));
                0
            }
            H::Read => {
                let (fd, buf, n) = (arg(uc, 0), arg(uc, 1), arg(uc, 2) as usize);
                let Some(info) = self.fds.get_mut(&fd) else { return Some(self.fail(uc, EBADF)) };
                let data = self.files.get(&info.path).map(Vec::as_slice).unwrap_or(&[]);
                let start = info.off.min(data.len());
                let chunk = &data[start..(start + n).min(data.len())];
                let _ = uc.mem_write(buf, chunk);
                info.off += chunk.len();
                chunk.len() as u64
            }
            H::Write => {
                let (fd, buf, n) = (arg(uc, 0), arg(uc, 1), arg(uc, 2) as usize);
                let Some(info) = self.fds.get_mut(&fd) else { return Some(self.fail(uc, EBADF)) };
                let payload = uc.mem_read_as_vec(buf, n).unwrap_or_default();
                let data = self.files.entry(info.path.clone()).or_default();
                if info.off > data.len() {
                    data.resize(info.off, 0);
                }
                let end = info.off + payload.len();
                if end > data.len() {
                    data.resize(end, 0);
                }
                data[info.off..end].copy_from_slice(&payload);
                info.off = end;
                n as u64
            }
            H::Lstat => {
                let path = cstr(uc, arg(uc, 0));
                let buf = arg(uc, 1);
                if let Some(f) = self.files.get(&path) {
                    self.fill_stat(uc, buf, &path, false, f.len() as i64);
                    0
                } else if self.dirs.contains(&path) {
                    self.fill_stat(uc, buf, &path, true, 0);
                    0
                } else {
                    self.fail(uc, ENOENT)
                }
            }
            H::Fstat => {
                let (fd, buf) = (arg(uc, 0), arg(uc, 1));
                let Some(info) = self.fds.get(&fd) else { return Some(self.fail(uc, EBADF)) };
                let size = self.files.get(&info.path).map_or(0, Vec::len) as i64;
                let path = info.path.clone();
                self.fill_stat(uc, buf, &path, false, size);
                0
            }
            H::Statfs => {
                let mut raw = vec![0u8; STATFS_SIZE];
                raw[0..4].copy_from_slice(&0x100_0003u32.to_le_bytes());
                let _ = uc.mem_write(arg(uc, 1), &raw);
                0
            }
            H::Mkdir => {
                let path = cstr(uc, arg(uc, 0));
                if self.files.contains_key(&path) || self.dirs.contains(&path) {
                    return Some(self.fail(uc, EEXIST));
                }
                self.dirs.insert(path);
                0
            }
            H::Unlink => {
                let path = cstr(uc, arg(uc, 0));
                if self.files.remove(&path).is_some() {
                    0
                } else {
                    self.fail(uc, ENOENT)
                }
            }
            H::Chmod => {
                let path = cstr(uc, arg(uc, 0));
                if self.files.contains_key(&path) || self.dirs.contains(&path) {
                    0
                } else {
                    self.fail(uc, ENOENT)
                }
            }
            H::Ftruncate => {
                let (fd, len) = (arg(uc, 0), arg(uc, 1) as usize);
                let Some(info) = self.fds.get(&fd) else { return Some(self.fail(uc, EBADF)) };
                self.files.entry(info.path.clone()).or_default().resize(len, 0);
                0
            }
            H::Getenv => {
                let name = cstr(uc, arg(uc, 0));
                self.getenv_addr.get(name.as_str()).copied().unwrap_or(0)
            }
            H::CfurlCreate => {
                let (buf, len) = (arg(uc, 1), arg(uc, 2) as usize);
                let path = String::from_utf8_lossy(&uc.mem_read_as_vec(buf, len).unwrap_or_default()).into_owned();
                self.next_url += 0x10;
                self.urls.insert(self.next_url, path);
                self.next_url
            }
            H::CfurlCopyProp => {
                let (url, key, out) = (arg(uc, 0), arg(uc, 1), arg(uc, 2));
                let path = self.urls.get(&url).cloned().unwrap_or_else(|| format!("<{url:#x}>"));
                let name = self.key_by_object.get(&key).map(|s| norm(s).to_string());
                let obj = |n: &str| self.object_of.get(n).copied().unwrap_or(0);
                match name.as_deref() {
                    Some("kCFURLIsDirectoryKey") => {
                        let v = if self.dirs.contains(&path) { obj("kCFBooleanTrue") } else { obj("kCFBooleanFalse") };
                        w64(uc, out, v);
                        1
                    }
                    Some("kCFURLIsHiddenKey") => {
                        w64(uc, out, obj("kCFBooleanFalse"));
                        1
                    }
                    Some("kCFURLFileSecurityKey") | Some("kCFURLTypeIdentifierKey") => {
                        w64(uc, out, OBJECT_ADDRESS);
                        1
                    }
                    _ => 0,
                }
            }
        })
    }
}

/// The pristine state right after load and binding, before any call into the library.
struct Snapshot {
    segments: Vec<(u64, Vec<u8>)>,
    cells: Vec<u8>,
    heap_cur: u64,
    obj_cur: u64,
    next_url: u64,
    next_fd: u64,
}

pub struct Vm {
    uc: Uc<'static>,
    snapshot: Snapshot,
    zeros: Vec<u8>,
}

impl Vm {
    pub fn new(image: &[u8]) -> Result<Vm, Error> {
        let macho = MachO::parse(image)?;
        let mut uc = Unicorn::new_with_data(Arch::X86, Mode::MODE_64, Env::default())?;

        for (a, s) in [
            (RETURN_ADDRESS, PAGE),
            (HEAP_ADDRESS, HEAP_SIZE),
            (STACK_ADDRESS, STACK_SIZE),
            (STUB_ADDRESS, STUB_SIZE),
            (DATA_ADDRESS, DATA_SIZE),
            (SCRATCH_ADDRESS, SCRATCH_SIZE),
            (OBJECT_ADDRESS, OBJECT_SIZE),
        ] {
            uc.mem_map(a, s, Prot::ALL)?;
        }
        for seg in &macho.segments {
            let size = (seg.vmsize + PAGE - 1) / PAGE * PAGE;
            if size == 0 {
                continue;
            }
            uc.mem_map(seg.vmaddr, size, Prot::ALL)?;
            if seg.filesize != 0 {
                let blob = image
                    .get(seg.fileoff as usize..(seg.fileoff + seg.filesize) as usize)
                    .ok_or_else(|| Error::MachO("segment outside file".into()))?;
                uc.mem_write(seg.vmaddr, blob)?;
            }
        }
        uc.mem_write(STUB_ADDRESS, &vec![0xC3u8; STUB_SIZE as usize])?;

        let mut stub_addr: HashMap<&str, u64> = HashMap::new();
        let mut data_cell: HashMap<&str, u64> = HashMap::new();
        let mut handlers = HashMap::new();
        let (mut object_of, mut key_by_object) = (HashMap::new(), HashMap::new());
        for (i, sym) in macho.bind_symbols().into_iter().enumerate() {
            let i = i as u64;
            if DATA_SYMBOLS.contains(&norm(sym)) {
                let (cell, obj) = (DATA_ADDRESS + i * SLOT, OBJECT_ADDRESS + i * SLOT);
                uc.mem_write(cell, &obj.to_le_bytes())?;
                data_cell.insert(sym, cell);
                object_of.insert(norm(sym).to_string(), obj);
                key_by_object.insert(obj, sym.to_string());
            } else {
                let addr = STUB_ADDRESS + i * SLOT;
                stub_addr.insert(sym, addr);
                if let Some(h) = handler_for(norm(sym)) {
                    handlers.insert(addr, h);
                }
            }
        }
        for b in macho.binds() {
            let target = data_cell.get(b.symbol.as_str()).or_else(|| stub_addr.get(b.symbol.as_str()));
            let target = *target.ok_or_else(|| Error::MachO(format!("unbound symbol {}", b.symbol)))?;
            uc.mem_write(b.address, &target.wrapping_add(b.addend as u64).to_le_bytes())?;
        }

        let env = uc.get_data_mut();
        env.handlers = handlers;
        env.object_of = object_of;
        env.key_by_object = key_by_object;
        env.heap_cur = HEAP_ADDRESS;
        env.scratch_cur = SCRATCH_ADDRESS;
        env.obj_cur = OBJECT_ADDRESS;
        env.next_url = OBJECT_ADDRESS;
        env.next_fd = 3;
        env.host_uuid = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ];
        env.dirs = ["/", "/Users", "/Users/Shared", STORE_DIR].iter().map(|s| s.to_string()).collect();

        // Long-lived scratch cells (errno, getenv strings) live below the per-call scratch base.
        env.errno_addr = env.bump_scratch(8);
        let mut cells = Vec::new();
        for (k, v) in [("HOME", "/Users/aditest"), ("USER", "aditest"), ("TMPDIR", "/tmp/")] {
            let a = env.bump_scratch(v.len() as u64 + 1);
            env.getenv_addr.insert(k, a);
            cells.push((a, v));
        }
        env.scratch_base = env.scratch_cur;
        for (a, v) in cells {
            uc.mem_write(a, format!("{v}\0").as_bytes())?;
        }

        uc.add_code_hook(STUB_ADDRESS, STUB_ADDRESS + STUB_SIZE - 1, |uc, addr, _| {
            let Some(h) = uc.get_data().handlers.get(&addr).copied() else { return };
            let mut env = std::mem::take(uc.get_data_mut());
            let r = env.call(uc, h);
            *uc.get_data_mut() = env;
            if let Some(v) = r {
                let _ = uc.reg_write(RegisterX86::RAX, v);
            }
        })?;
        uc.add_mem_hook(
            HookType::MEM_READ_UNMAPPED | HookType::MEM_WRITE_UNMAPPED | HookType::MEM_FETCH_UNMAPPED,
            0,
            u64::MAX,
            |uc, kind, addr, size, _| {
                let rip = uc.reg_read(RegisterX86::RIP).unwrap_or(0);
                let k = match kind {
                    MemType::READ_UNMAPPED => "read",
                    MemType::WRITE_UNMAPPED => "write",
                    _ => "fetch",
                };
                uc.get_data_mut().fault = Some(format!("{k}-unmapped at {addr:#x} (size {size}) rip={rip:#x}"));
                false
            },
        )?;
        let mut segments = Vec::new();
        for seg in macho.segments.iter().filter(|s| s.writable && s.vmsize != 0) {
            segments.push((seg.vmaddr, uc.mem_read_as_vec(seg.vmaddr, seg.vmsize as usize)?));
        }
        let cells = uc.mem_read_as_vec(DATA_ADDRESS, PAGE as usize)?;
        let env = uc.get_data();
        let snapshot = Snapshot {
            segments,
            cells,
            heap_cur: env.heap_cur,
            obj_cur: env.obj_cur,
            next_url: env.next_url,
            next_fd: env.next_fd,
        };
        Ok(Vm { uc, snapshot, zeros: vec![0u8; STACK_SIZE as usize] })
    }

    /// Run `address(args...)` until it returns; the result is `rax`.
    pub fn invoke(&mut self, address: u64, args: &[u64]) -> Result<u64, Error> {
        let uc = &mut self.uc;
        for (i, v) in args.iter().enumerate().take(6) {
            uc.reg_write(reg(i), *v)?;
        }
        let rsp = STACK_ADDRESS + STACK_SIZE - 0x1000;
        w64(uc, rsp, RETURN_ADDRESS);
        uc.reg_write(RegisterX86::RSP, rsp)?;
        uc.reg_write(RegisterX86::RBP, 0)?;
        uc.get_data_mut().fault = None;
        let res = uc.emu_start(address, RETURN_ADDRESS, 0, 0);
        if let Some(msg) = uc.get_data_mut().fault.take() {
            return Err(Error::Emulation(msg));
        }
        match res {
            Ok(()) => Ok(uc.reg_read(RegisterX86::RAX)?),
            Err(e) => {
                let rip = uc.reg_read(RegisterX86::RIP).unwrap_or(0);
                Err(Error::Emulation(format!("emulation failed at rip={rip:#x}: {e:?}")))
            }
        }
    }

    /// Return the VM to the state it had right after loading, as if a fresh process had started.
    /// The store (`files`), host UUID and clock are kept; library memory (data segment, heap, stack,
    /// scratch), descriptors and allocator counters are not. Translated code stays cached, which is
    /// what makes this cheap, and nothing leaks because the heap restarts from empty. Call it
    /// between sessions, never inside one (a provisioning session id lives in library memory).
    pub fn reset_session(&mut self) -> Result<(), Error> {
        let uc = &mut self.uc;
        for (addr, bytes) in &self.snapshot.segments {
            uc.mem_write(*addr, bytes)?;
        }
        uc.mem_write(DATA_ADDRESS, &self.snapshot.cells)?;
        uc.mem_unmap(HEAP_ADDRESS, HEAP_SIZE)?;
        uc.mem_map(HEAP_ADDRESS, HEAP_SIZE, Prot::ALL)?;
        uc.mem_write(STACK_ADDRESS, &self.zeros)?;
        let env = uc.get_data_mut();
        let (base, dirty) = (env.scratch_base, (env.scratch_cur - env.scratch_base) as usize);
        env.heap_cur = self.snapshot.heap_cur;
        env.obj_cur = self.snapshot.obj_cur;
        env.next_url = self.snapshot.next_url;
        env.next_fd = self.snapshot.next_fd;
        env.scratch_cur = env.scratch_base;
        env.fds.clear();
        env.urls.clear();
        env.fault = None;
        let errno = env.errno_addr;
        uc.mem_write(errno, &[0u8; 8])?;
        uc.mem_write(base, &self.zeros[..dirty.min(self.zeros.len())])?;
        Ok(())
    }

    /// Per-call scratch (request buffers, out-cells). Reset between top-level calls.
    pub fn scratch(&mut self, size: usize) -> u64 {
        self.uc.get_data_mut().bump_scratch(size as u64)
    }

    pub fn scratch_reset(&mut self) {
        let env = self.uc.get_data_mut();
        env.scratch_cur = env.scratch_base;
    }

    pub fn write(&mut self, addr: u64, data: &[u8]) -> Result<(), Error> {
        Ok(self.uc.mem_write(addr, data)?)
    }

    pub fn read(&self, addr: u64, len: usize) -> Result<Vec<u8>, Error> {
        Ok(self.uc.mem_read_as_vec(addr, len)?)
    }

    pub fn read_u32(&self, addr: u64) -> Result<u32, Error> {
        Ok(u32::from_le_bytes(self.read(addr, 4)?.try_into().unwrap()))
    }

    pub fn read_u64(&self, addr: u64) -> Result<u64, Error> {
        Ok(r64(&self.uc, addr))
    }

    pub fn write_u64(&mut self, addr: u64, v: u64) -> Result<(), Error> {
        self.write(addr, &v.to_le_bytes())
    }

    pub fn write_u32(&mut self, addr: u64, v: u32) -> Result<(), Error> {
        self.write(addr, &v.to_le_bytes())
    }

    /// The virtual filesystem (the library's store lives under [`STORE_DIR`]).
    pub fn files(&self) -> &BTreeMap<String, Vec<u8>> {
        &self.uc.get_data().files
    }

    pub fn files_mut(&mut self) -> &mut BTreeMap<String, Vec<u8>> {
        &mut self.uc.get_data_mut().files
    }

    pub fn set_host_uuid(&mut self, uuid: [u8; 16]) {
        self.uc.get_data_mut().host_uuid = uuid;
    }

    /// Pin `gettimeofday` to `secs` (tests, byte-for-byte comparison); `None` restores the real clock.
    ///
    /// **Never do this in the app.** A frozen clock makes CoreADI's OTP a constant, and Apple then
    /// accepts the machine for only about 60 s (`EVIDENCE.md` sections 8 and 9). Production must leave it `None`.
    pub fn set_frozen_time(&mut self, secs: Option<u64>) {
        self.uc.get_data_mut().frozen_time = secs;
    }

    pub fn heap_used(&self) -> u64 {
        self.uc.get_data().heap_cur - HEAP_ADDRESS
    }
}
