//! The ADI dispatcher call framing (`_vdfut768ig(function_code, CoreADIParameters*)`), after
//! Dadoum/apple-crates `adi/src/{core_adi,calls}.rs`. Requests are big-endian bincode; pointers
//! inside a message are 8-byte big-endian addresses *inside the emulated process*.

use crate::vm::{Vm, STORE_DIR};
use crate::{identify_build, Error};
use std::collections::BTreeMap;

fn discard_legacy_blob(files: &mut BTreeMap<String, Vec<u8>>) {
    files.remove(&format!("{STORE_DIR}/adi.pb"));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn legacy_machine_blob_is_discarded_without_losing_per_user_store() {
        let mut files = BTreeMap::from([
            (format!("{STORE_DIR}/adi.pb"), vec![1, 2, 3]),
            (format!("{STORE_DIR}/user-blob"), vec![4, 5, 6]),
        ]);
        discard_legacy_blob(&mut files);
        assert!(!files.contains_key(&format!("{STORE_DIR}/adi.pb")));
        assert_eq!(files[&format!("{STORE_DIR}/user-blob")], [4, 5, 6]);
    }
}

fn code(name: &str) -> u32 {
    match name {
        "Initialize" => 0x12DB_31C5,
        "TearDown" => 0x08C0_FE9E,
        "IsMachineProvisioned" => 0xB0ED_A7AF,
        "ProvisioningStart" => 0x716B_D86C,
        "ProvisioningEnd" => 0x0B2B_3196,
        "SetIDMSRouting" => 0x632B_8D6E,
        "GetIDMSRouting" => 0x85FE_63B0,
        "Synchronize" => 0xA549_51EC,
        "Erase" => 0x7715_488C,
        "RequestOTP" => 0xCFE0_B46A,
        "StorageDispose" => 0x3E58_E7F9,
        _ => unreachable!("unknown ADI call {name}"),
    }
}

/// Dispatcher status (`rc`) and the operation's own status (`ret`, negative on failure).
#[derive(Debug, Clone, Copy)]
pub struct Reply {
    pub rc: i32,
    pub ret: i32,
}

impl Reply {
    pub fn ok(&self) -> bool {
        self.rc >= 0 && self.ret >= 0
    }
}

#[derive(Debug)]
pub struct Otp {
    pub reply: Reply,
    pub mid: Vec<u8>,
    pub otp: Vec<u8>,
}

#[derive(Debug)]
pub struct ProvisioningStart {
    pub reply: Reply,
    pub cpim: Vec<u8>,
    pub session: u32,
}

#[derive(Debug)]
pub struct Sync {
    pub reply: Reply,
    pub mid: Vec<u8>,
    pub srm: Vec<u8>,
}

/// What Apple's login and Find My services want from a machine, for one request.
#[derive(Debug)]
pub struct Headers {
    /// `X-Apple-I-MD-M`, raw bytes (base64 it for the header).
    pub mid: Vec<u8>,
    /// `X-Apple-I-MD`, raw bytes.
    pub otp: Vec<u8>,
    /// `X-Apple-I-MD-RINFO`.
    pub routing: u64,
}

pub struct CoreAdi {
    vm: Vm,
    dispatch: u64,
    build: &'static str,
}

fn be32(v: u32) -> [u8; 4] {
    v.to_be_bytes()
}

fn be64(v: u64) -> [u8; 8] {
    v.to_be_bytes()
}

impl CoreAdi {
    /// Load a registered CoreADI build (identified by sha256).
    pub fn new(image: &[u8]) -> Result<CoreAdi, Error> {
        let (build, dispatch) = identify_build(image)?;
        let mut a = Self::with_dispatch(image, dispatch)?;
        a.build = build;
        Ok(a)
    }

    /// Load an unlisted build whose `_vdfut768ig` offset is known.
    pub fn with_dispatch(image: &[u8], dispatch: u64) -> Result<CoreAdi, Error> {
        Ok(CoreAdi {
            vm: Vm::new(image)?,
            dispatch,
            build: "unlisted build",
        })
    }

    pub fn set_host_uuid(&mut self, uuid: [u8; 16]) {
        self.vm.set_host_uuid(uuid);
    }

    /// Pin the emulated clock to `secs` since the epoch (tests); `None` is the real clock.
    pub fn set_frozen_time(&mut self, secs: Option<u64>) {
        self.vm.set_frozen_time(secs);
    }

    /// Start a session the way a fresh process would: reset the VM to its post-load snapshot (the
    /// store, host UUID and clock are kept) and call `Initialize`. One session is, for example, one
    /// Anisette header set (`is_machine_provisioned`, `request_otp`, `get_routing`), or one
    /// provisioning (`provisioning_start` then `provisioning_end`, which must share a session).
    /// This replaces the heap management a long-lived library would need: nothing accumulates.
    pub fn begin_session(&mut self) -> Result<Reply, Error> {
        self.vm.reset_session()?;
        self.initialize()
    }

    pub fn build(&self) -> &'static str {
        self.build
    }

    pub fn vm(&mut self) -> &mut Vm {
        &mut self.vm
    }

    fn call(&mut self, name: &str, message: &[u8]) -> Result<(Reply, u64), Error> {
        let vm = &mut self.vm;
        let mut buf = vec![0u8; 0x800.max(8 + message.len())];
        buf[3] = 1; // encryption type: clear
        buf[7] = 1;
        buf[8..8 + message.len()].copy_from_slice(message);
        let buf_addr = vm.scratch(buf.len());
        vm.write(buf_addr, &buf)?;

        let params = vm.scratch(0x20);
        vm.write(params, &[0u8; 0x20])?;
        vm.write_u64(params, buf_addr)?;
        vm.write_u32(params + 0x08, (8 + message.len()) as u32)?;
        vm.write_u32(params + 0x0C, 4)?;
        vm.write_u32(params + 0x10, 0)?;

        let rc = vm.invoke(self.dispatch, &[u64::from(code(name)), params])? as u32 as i32;
        let ret = i32::from_be_bytes(vm.read(buf_addr, 4)?.try_into().unwrap());
        vm.write(buf_addr + 4, &[0u8; 4])?;
        Ok((Reply { rc, ret }, buf_addr))
    }

    /// A fresh 8-byte cell, optionally holding a value, whose address goes into a request.
    fn cell(&mut self, v: u64) -> Result<u64, Error> {
        let a = self.vm.scratch(8);
        self.vm.write_u64(a, v)?;
        Ok(a)
    }

    fn slice(&self, ptr: u64, len: u64) -> Result<Vec<u8>, Error> {
        let (p, n) = (self.vm.read_u64(ptr)?, self.vm.read_u32(len)?);
        if p == 0 || n == 0 {
            return Ok(Vec::new());
        }
        self.vm.read(p, n as usize)
    }

    fn input(&mut self, data: &[u8]) -> Result<u64, Error> {
        let a = self.vm.scratch(data.len().max(16));
        if !data.is_empty() {
            self.vm.write(a, data)?;
        }
        Ok(a)
    }

    pub fn initialize(&mut self) -> Result<Reply, Error> {
        self.vm.scratch_reset();
        Ok(self.call("Initialize", &[])?.0)
    }

    pub fn teardown(&mut self) -> Result<Reply, Error> {
        self.vm.scratch_reset();
        Ok(self.call("TearDown", &[])?.0)
    }

    /// `ret == 0` means provisioned.
    pub fn is_machine_provisioned(&mut self, ds_id: i64) -> Result<Reply, Error> {
        self.vm.scratch_reset();
        Ok(self.call("IsMachineProvisioned", &ds_id.to_be_bytes())?.0)
    }

    pub fn request_otp(&mut self, ds_id: i64) -> Result<Otp, Error> {
        self.vm.scratch_reset();
        let (mid_p, mid_l, otp_p, otp_l) = (self.cell(0)?, self.cell(0)?, self.cell(0)?, self.cell(0)?);
        let mut m = ds_id.to_be_bytes().to_vec();
        for v in [mid_p, mid_l, otp_p, otp_l] {
            m.extend(be64(v));
        }
        let (reply, _) = self.call("RequestOTP", &m)?;
        let (mid, otp) = (self.slice(mid_p, mid_l)?, self.slice(otp_p, otp_l)?);
        // The library hands back pointers into its own storage; release them.
        if !mid.is_empty() && !otp.is_empty() {
            let p = self.vm.read_u64(mid_p)?;
            self.storage_dispose(p)?;
        }
        Ok(Otp { reply, mid, otp })
    }

    pub fn provisioning_start(&mut self, ds_id: i64, spim: &[u8]) -> Result<ProvisioningStart, Error> {
        self.vm.scratch_reset();
        let spim_buf = self.input(spim)?;
        let (cpim_p, cpim_l, session) = (self.cell(0)?, self.cell(0)?, self.cell(0)?);
        let mut m = ds_id.to_be_bytes().to_vec();
        m.extend(be64(spim_buf));
        m.extend(be32(spim.len() as u32));
        for v in [cpim_p, cpim_l, session] {
            m.extend(be64(v));
        }
        let (reply, _) = self.call("ProvisioningStart", &m)?;
        Ok(ProvisioningStart { reply, cpim: self.slice(cpim_p, cpim_l)?, session: self.vm.read_u32(session)? })
    }

    pub fn provisioning_end(&mut self, session: u32, ptm: &[u8], tk: &[u8]) -> Result<Reply, Error> {
        self.vm.scratch_reset();
        let (ptm_buf, tk_buf) = (self.input(ptm)?, self.input(tk)?);
        let mut m = be32(session).to_vec();
        m.extend(be64(ptm_buf));
        m.extend(be32(ptm.len() as u32));
        m.extend(be64(tk_buf));
        m.extend(be32(tk.len() as u32));
        Ok(self.call("ProvisioningEnd", &m)?.0)
    }

    pub fn synchronize(&mut self, ds_id: i64, sim: &[u8]) -> Result<Sync, Error> {
        self.vm.scratch_reset();
        let sim_buf = self.input(sim)?;
        let (mid_p, mid_l, srm_p, srm_l) = (self.cell(0)?, self.cell(0)?, self.cell(0)?, self.cell(0)?);
        let mut m = ds_id.to_be_bytes().to_vec();
        m.extend(be64(sim_buf));
        m.extend(be32(sim.len() as u32));
        for v in [mid_p, mid_l, srm_p, srm_l] {
            m.extend(be64(v));
        }
        let (reply, _) = self.call("Synchronize", &m)?;
        Ok(Sync { reply, mid: self.slice(mid_p, mid_l)?, srm: self.slice(srm_p, srm_l)? })
    }

    pub fn storage_dispose(&mut self, ptr: u64) -> Result<Reply, Error> {
        Ok(self.call("StorageDispose", &be64(ptr))?.0)
    }

    pub fn erase(&mut self, ds_id: i64) -> Result<Reply, Error> {
        self.vm.scratch_reset();
        Ok(self.call("Erase", &ds_id.to_be_bytes())?.0)
    }

    pub fn set_routing(&mut self, ds_id: i64, routing: u64) -> Result<Reply, Error> {
        self.vm.scratch_reset();
        let mut m = ds_id.to_be_bytes().to_vec();
        m.extend(be64(routing));
        Ok(self.call("SetIDMSRouting", &m)?.0)
    }

    pub fn get_routing(&mut self, ds_id: i64) -> Result<(Reply, u64), Error> {
        self.vm.scratch_reset();
        let cell = self.cell(0)?;
        let mut m = ds_id.to_be_bytes().to_vec();
        m.extend(be64(cell));
        let (reply, _) = self.call("GetIDMSRouting", &m)?;
        Ok((reply, self.vm.read_u64(cell)?))
    }

    // -- high level: one call is one session --------------------------------------------------

    /// Put one store file (as saved by [`CoreAdi::store_files`]) into the virtual store. The legacy
    /// whole-machine `adi.pb` is ignored: when it is present the library reports the machine
    /// unprovisioned without reading the per-user blob (see `mac_anisette.py`).
    pub fn store_put(&mut self, name: &str, data: &[u8]) {
        if name != "adi.pb" {
            self.vm.files_mut().insert(format!("{STORE_DIR}/{name}"), data.to_vec());
        }
    }

    /// Mac CoreADI writes an obsolete whole-machine adi.pb during provisioning.
    /// It masks the per-user store until removed (Jimpactor mac_anisette.rs).
    pub fn discard_legacy_blob(&mut self) {
        discard_legacy_blob(self.vm.files_mut());
    }

    /// The store as `(file name, bytes)`; persist it after every call that can change it.
    pub fn store_files(&self) -> Vec<(String, Vec<u8>)> {
        let prefix = format!("{STORE_DIR}/");
        self.vm
            .files()
            .iter()
            .filter_map(|(k, v)| k.strip_prefix(&prefix).map(|n| (n.to_string(), v.clone())))
            .collect()
    }

    fn check(op: &'static str, r: Reply) -> Result<(), Error> {
        if r.rc < 0 || r.ret < 0 {
            return Err(Error::Adi { op, ret: if r.ret < 0 { r.ret } else { r.rc } });
        }
        Ok(())
    }

    /// One session: the headers a machine puts on a request. Persist [`CoreAdi::store_files`] after.
    pub fn headers(&mut self, ds_id: i64) -> Result<Headers, Error> {
        self.begin_session()?;
        if self.is_machine_provisioned(ds_id)?.ret != 0 {
            return Err(Error::NotProvisioned);
        }
        let otp = self.request_otp(ds_id)?;
        Self::check("RequestOTP", otp.reply)?;
        let (r, routing) = self.get_routing(ds_id)?;
        Self::check("GetIDMSRouting", r)?;
        Ok(Headers { mid: otp.mid, otp: otp.otp, routing })
    }

    /// Start provisioning with Apple's `spim`; returns `(cpim, session)`. Finish with
    /// [`CoreAdi::provisioning_finish`] and nothing else in between: they share one session.
    pub fn provisioning_begin(&mut self, ds_id: i64, spim: &[u8]) -> Result<(Vec<u8>, u32), Error> {
        self.begin_session()?;
        if self.is_machine_provisioned(ds_id)?.ret == 0 {
            return Err(Error::AlreadyProvisioned);
        }
        let s = self.provisioning_start(ds_id, spim)?;
        Self::check("ProvisioningStart", s.reply)?;
        Ok((s.cpim, s.session))
    }

    pub fn provisioning_finish(
        &mut self,
        ds_id: i64,
        session: u32,
        ptm: &[u8],
        tk: &[u8],
        routing: u64,
    ) -> Result<(), Error> {
        Self::check("ProvisioningEnd", self.provisioning_end(session, ptm, tk)?)?;
        Self::check("SetIDMSRouting", self.set_routing(ds_id, routing)?)
    }

    /// Answer Apple's resync request: `(mid, srm)` for a `sim` taken from the 434 reply.
    pub fn sync(&mut self, ds_id: i64, sim: &[u8]) -> Result<(Vec<u8>, Vec<u8>), Error> {
        self.begin_session()?;
        let s = self.synchronize(ds_id, sim)?;
        Self::check("Synchronize", s.reply)?;
        Ok((s.mid, s.srm))
    }

    /// Store the routing value Apple returns (`X-Apple-I-MD-RINFO`) after a resync.
    pub fn update_routing(&mut self, ds_id: i64, routing: u64) -> Result<(), Error> {
        self.begin_session()?;
        Self::check("SetIDMSRouting", self.set_routing(ds_id, routing)?)
    }
}
