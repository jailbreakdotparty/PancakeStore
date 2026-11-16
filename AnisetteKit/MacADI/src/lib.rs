//! Mac CoreADI under Unicorn, as a small library: load a registered build, give it a store and a
//! host UUID, and ask it for Anisette (MID/OTP), provisioning and synchronization messages.

mod adi;
pub mod capi;
mod macho;
mod sap;
mod vm;

pub use adi::{CoreAdi, Headers, Otp, ProvisioningStart, Reply, Sync};
pub use vm::{Vm, STORE_DIR};

use sha2::{Digest, Sha256};

#[derive(Debug)]
pub enum Error {
    MachO(String),
    Emulation(String),
    Unicorn(unicorn_engine::unicorn_const::uc_error),
    UnknownBuild(String),
    /// The library answered with a negative status (`op` is the ADI call).
    Adi { op: &'static str, ret: i32 },
    NotProvisioned,
    AlreadyProvisioned,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::MachO(m) => write!(f, "mach-o: {m}"),
            Error::Emulation(m) => write!(f, "emulation: {m}"),
            Error::Unicorn(e) => write!(f, "unicorn: {e:?}"),
            Error::Adi { op, ret } => write!(f, "{op} failed: {ret}"),
            Error::NotProvisioned => write!(f, "machine is not provisioned"),
            Error::AlreadyProvisioned => write!(f, "machine is already provisioned"),
            Error::UnknownBuild(h) => {
                write!(f, "unknown CoreADI build sha256 {h}; pass its _vdfut768ig offset explicitly")
            }
        }
    }
}

impl std::error::Error for Error {}

impl From<unicorn_engine::unicorn_const::uc_error> for Error {
    fn from(e: unicorn_engine::unicorn_const::uc_error) -> Self {
        Error::Unicorn(e)
    }
}

/// Builds whose dispatcher (`_vdfut768ig`) offset is known: (sha256 of the file, name, offset).
pub const BUILDS: [(&str, &str, u64); 2] = [
    (
        "2eafc3c79c7f41a8afbfbeaaf23ee5dab5ad5bda55ec8e54dbc0ddf1d20ce630",
        "iTunes 12.8.3, CoreADI 4.19 (x86_64 slice)",
        0x979A0,
    ),
    (
        "6fe4b27f2d75b5f365917a92389bed75542f3ba08197f136262be3b34d19cb5c",
        "macOS 15.8.1 24H32",
        0x17BF60,
    ),
];

/// `(name, dispatcher offset)` of a CoreADI image, by the sha256 of its bytes.
pub fn identify_build(image: &[u8]) -> Result<(&'static str, u64), Error> {
    let digest: String = Sha256::digest(image).iter().map(|b| format!("{b:02x}")).collect();
    BUILDS
        .iter()
        .find(|(h, _, _)| *h == digest)
        .map(|(_, n, o)| (*n, *o))
        .ok_or(Error::UnknownBuild(digest))
}
