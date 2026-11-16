//! C ABI over [`CoreAdi`], for JNI (see `jni.rs`) or any C host. Every function returns 0 on success
//! and a negative value on failure, with the message available from `adi_last_error` (per thread).
//! Output buffers are allocated here and must be released with `adi_buf_free`.
//!
//! A handle may be used from one thread at a time (calls are serialised by a mutex); prefer a
//! single-threaded executor, because each call is one 20 ms emulated session.

use std::cell::RefCell;
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

use crate::{CoreAdi, Error};

pub const ADI_OK: i32 = 0;
pub const ADI_ERR: i32 = -1;
pub const ADI_ERR_NOT_PROVISIONED: i32 = -2;
pub const ADI_ERR_ALREADY_PROVISIONED: i32 = -3;
pub const ADI_ERR_BAD_ARGUMENT: i32 = -4;

/// Wrapper so the handle can sit behind a mutex: the engine is used by one thread at a time.
pub struct Handle(Mutex<CoreAdi>);
impl Handle {
    pub fn new(adi: CoreAdi) -> Handle {
        Handle(Mutex::new(adi))
    }

    pub fn lock(&self) -> std::sync::LockResult<std::sync::MutexGuard<'_, CoreAdi>> {
        self.0.lock()
    }
}

unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}

#[repr(C)]
pub struct AdiBuf {
    pub ptr: *mut u8,
    pub len: usize,
}

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

fn set_error(msg: impl Into<String>) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg.into());
}

fn code(e: &Error) -> i32 {
    match e {
        Error::NotProvisioned => ADI_ERR_NOT_PROVISIONED,
        Error::AlreadyProvisioned => ADI_ERR_ALREADY_PROVISIONED,
        _ => ADI_ERR,
    }
}

/// Run `f`, mapping errors and panics to status codes.
fn guard(f: impl FnOnce() -> Result<(), Error>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => ADI_OK,
        Ok(Err(e)) => {
            set_error(e.to_string());
            code(&e)
        }
        Err(_) => {
            set_error("internal panic");
            ADI_ERR
        }
    }
}

unsafe fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, len)
    }
}

unsafe fn put(out: *mut AdiBuf, v: Vec<u8>) {
    let b = v.into_boxed_slice();
    let len = b.len();
    (*out).ptr = Box::into_raw(b) as *mut u8;
    (*out).len = len;
}

unsafe fn with<'a>(h: *mut Handle) -> Result<std::sync::MutexGuard<'a, CoreAdi>, Error> {
    if h.is_null() {
        return Err(Error::Emulation("null handle".into()));
    }
    (*h).0.lock().map_err(|_| Error::Emulation("handle poisoned".into()))
}

/// Load a registered CoreADI build from its file bytes. The image is copied.
#[no_mangle]
pub unsafe extern "C" fn adi_open(image: *const u8, len: usize, out: *mut *mut Handle) -> i32 {
    guard(|| {
        let adi = CoreAdi::new(bytes(image, len))?;
        *out = Box::into_raw(Box::new(Handle(Mutex::new(adi))));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn adi_close(h: *mut Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

/// Name of the loaded build, written (NUL-terminated, truncated) into `buf`; returns its length.
#[no_mangle]
pub unsafe extern "C" fn adi_build_name(h: *mut Handle, buf: *mut c_char, cap: usize) -> usize {
    let Ok(g) = with(h) else { return 0 };
    copy_str(g.build(), buf, cap)
}

unsafe fn copy_str(s: &str, buf: *mut c_char, cap: usize) -> usize {
    if buf.is_null() || cap == 0 {
        return s.len();
    }
    let n = s.len().min(cap - 1);
    std::ptr::copy_nonoverlapping(s.as_ptr(), buf as *mut u8, n);
    *buf.add(n) = 0;
    s.len()
}

/// The last error message of this thread, as for `adi_build_name`.
#[no_mangle]
pub unsafe extern "C" fn adi_last_error(buf: *mut c_char, cap: usize) -> usize {
    LAST_ERROR.with(|e| copy_str(&e.borrow(), buf, cap))
}

#[no_mangle]
pub unsafe extern "C" fn adi_buf_free(b: AdiBuf) {
    if !b.ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(b.ptr, b.len)));
    }
}

/// The machine's `gethostuuid` (16 bytes). It is part of what the MID is derived from: keep it with
/// the store and never change it.
#[no_mangle]
pub unsafe extern "C" fn adi_set_host_uuid(h: *mut Handle, uuid: *const u8) -> i32 {
    guard(|| {
        let u: [u8; 16] = bytes(uuid, 16).try_into().map_err(|_| Error::Emulation("host uuid needs 16 bytes".into()))?;
        with(h)?.set_host_uuid(u);
        Ok(())
    })
}

/// Pin the emulated clock (seconds since the epoch) for tests; a negative value restores the real clock.
#[no_mangle]
pub unsafe extern "C" fn adi_set_frozen_time(h: *mut Handle, secs: i64) -> i32 {
    guard(|| {
        with(h)?.set_frozen_time(u64::try_from(secs).ok());
        Ok(())
    })
}

/// Put one store file into the virtual store (`adi.pb` is ignored, see `CoreAdi::store_put`).
#[no_mangle]
pub unsafe extern "C" fn adi_store_put(h: *mut Handle, name: *const c_char, data: *const u8, len: usize) -> i32 {
    guard(|| {
        if name.is_null() {
            return Err(Error::Emulation("null name".into()));
        }
        let name = CStr::from_ptr(name).to_string_lossy();
        with(h)?.store_put(&name, bytes(data, len));
        Ok(())
    })
}

/// The store as one buffer: for each file `u16 name length (BE), name, u32 data length (BE), data`.
/// Persist it after every call that can change it (`adi_headers`, provisioning, sync).
#[no_mangle]
pub unsafe extern "C" fn adi_store_export(h: *mut Handle, out: *mut AdiBuf) -> i32 {
    guard(|| {
        let mut v = Vec::new();
        for (name, data) in with(h)?.store_files() {
            v.extend((name.len() as u16).to_be_bytes());
            v.extend(name.as_bytes());
            v.extend((data.len() as u32).to_be_bytes());
            v.extend(data);
        }
        put(out, v);
        Ok(())
    })
}

/// Restore what `adi_store_export` produced.
#[no_mangle]
pub unsafe extern "C" fn adi_store_import(h: *mut Handle, data: *const u8, len: usize) -> i32 {
    guard(|| {
        let (mut d, mut g) = (bytes(data, len), with(h)?);
        let bad = || Error::Emulation("malformed store export".into());
        while !d.is_empty() {
            let nl = u16::from_be_bytes(d.get(..2).ok_or_else(bad)?.try_into().unwrap()) as usize;
            let name = std::str::from_utf8(d.get(2..2 + nl).ok_or_else(bad)?).map_err(|_| bad())?;
            let dl = u32::from_be_bytes(d.get(2 + nl..6 + nl).ok_or_else(bad)?.try_into().unwrap()) as usize;
            let body = d.get(6 + nl..6 + nl + dl).ok_or_else(bad)?;
            g.store_put(name, body);
            d = &d[6 + nl + dl..];
        }
        Ok(())
    })
}

/// One session: `mid` (`X-Apple-I-MD-M`), `otp` (`X-Apple-I-MD`) and the routing value
/// (`X-Apple-I-MD-RINFO`). Returns `ADI_ERR_NOT_PROVISIONED` for an unprovisioned machine.
#[no_mangle]
pub unsafe extern "C" fn adi_headers(h: *mut Handle, ds_id: i64, mid: *mut AdiBuf, otp: *mut AdiBuf, routing: *mut u64) -> i32 {
    guard(|| {
        let r = with(h)?.headers(ds_id)?;
        put(mid, r.mid);
        put(otp, r.otp);
        *routing = r.routing;
        Ok(())
    })
}

/// Provisioning, step 1: Apple's `spim` in, `cpim` and a session id out. Call
/// `adi_provisioning_finish` next with nothing in between.
#[no_mangle]
pub unsafe extern "C" fn adi_provisioning_begin(
    h: *mut Handle,
    ds_id: i64,
    spim: *const u8,
    spim_len: usize,
    cpim: *mut AdiBuf,
    session: *mut u32,
) -> i32 {
    guard(|| {
        let (c, s) = with(h)?.provisioning_begin(ds_id, bytes(spim, spim_len))?;
        put(cpim, c);
        *session = s;
        Ok(())
    })
}

/// Provisioning, step 2: Apple's `ptm` and `tk`, and the routing value from the same reply.
#[no_mangle]
pub unsafe extern "C" fn adi_provisioning_finish(
    h: *mut Handle,
    ds_id: i64,
    session: u32,
    ptm: *const u8,
    ptm_len: usize,
    tk: *const u8,
    tk_len: usize,
    routing: u64,
) -> i32 {
    guard(|| {
        let mut adi = with(h)?;
        adi.provisioning_finish(ds_id, session, bytes(ptm, ptm_len), bytes(tk, tk_len), routing)?;
        // Match Jimpactor: the whole-machine adi.pb masks the per-user store
        // that ProvisioningEnd just created. Clear it before exporting state
        // or starting the next headers session.
        // Store (SP) provisioning of DSID -1 lives in that whole-machine blob.
        if ds_id != -1 {
            adi.discard_legacy_blob();
        }
        Ok(())
    })
}

/// Answer a resync request: the `sim` from Apple's 434 reply in, `mid` and `srm` out.
#[no_mangle]
pub unsafe extern "C" fn adi_sync(
    h: *mut Handle,
    ds_id: i64,
    sim: *const u8,
    sim_len: usize,
    mid: *mut AdiBuf,
    srm: *mut AdiBuf,
) -> i32 {
    guard(|| {
        let (m, s) = with(h)?.sync(ds_id, bytes(sim, sim_len))?;
        put(mid, m);
        put(srm, s);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn adi_update_routing(h: *mut Handle, ds_id: i64, routing: u64) -> i32 {
    guard(|| with(h)?.update_routing(ds_id, routing))
}

/// Drop one DSID's provisioning (e.g. a stale Store -1 identity before Store SP).
#[no_mangle]
pub unsafe extern "C" fn adi_erase(h: *mut Handle, ds_id: i64) -> i32 {
    guard(|| {
        let mut adi = with(h)?;
        adi.begin_session()?;
        adi.erase(ds_id)?;
        Ok(())
    })
}
