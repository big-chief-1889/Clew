//! Clew's wallet library: Tari's L1 wallet FFI and an Ootle (L2) wallet in one static library, so
//! the app links a single Rust runtime. The L1 C functions come from `minotari_wallet_ffi` as they
//! are; the Ootle ones are in `ffi`.

pub use minotari_wallet_ffi;

mod ffi;
mod ootle;
