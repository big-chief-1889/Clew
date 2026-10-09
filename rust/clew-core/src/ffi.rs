//! C functions for the Ootle wallet. Errors are reported through `error_out` (0 = none), with a
//! human-readable description from `clew_last_error`. Strings returned to the caller are freed with
//! `clew_string_destroy`.

use std::{
    cell::RefCell,
    ffi::{CStr, CString, c_char, c_int},
    path::Path,
    ptr,
    str::FromStr,
};

use minotari_wallet_ffi::TariWallet;
use ootle_network::Network;
use url::Url;

use crate::ootle::OotleWallet;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

const ERR_ARGUMENT: c_int = 1;
const ERR_FAILED: c_int = 2;

unsafe fn report(error_out: *mut c_int, code: c_int, message: impl ToString) {
    if !error_out.is_null() {
        unsafe { *error_out = code };
    }
    let text = message.to_string().replace('\0', " ");
    LAST_ERROR.with(|e| *e.borrow_mut() = CString::new(text).ok());
}

unsafe fn clear(error_out: *mut c_int) {
    if !error_out.is_null() {
        unsafe { *error_out = 0 };
    }
}

unsafe fn text<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() { None } else { unsafe { CStr::from_ptr(value) }.to_str().ok() }
}

fn owned(text: &str) -> *mut c_char {
    CString::new(text.replace('\0', " ")).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

/// The description of the last error on this thread, or null. Free with `clew_string_destroy`.
#[unsafe(no_mangle)]
pub extern "C" fn clew_last_error() -> *mut c_char {
    LAST_ERROR.with(|e| e.borrow().as_ref().map(|m| m.clone().into_raw()).unwrap_or(ptr::null_mut()))
}

/// # Safety
/// `value` must come from this library and not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_string_destroy(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

/// Routes Ootle indexer connections made after this call through `proxy` (e.g. a Tor SOCKS URL), or
/// directly when null. Open Ootle wallets keep their route, so reopen them after changing it.
///
/// # Safety
/// `proxy` must be null or a valid C string; `error_out` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_set_proxy(proxy: *const c_char, error_out: *mut c_int) -> bool {
    unsafe { clear(error_out) };
    let proxy = if proxy.is_null() {
        None
    } else {
        match unsafe { text(proxy) } {
            Some(p) => Some(p.to_string()),
            None => {
                unsafe { report(error_out, ERR_ARGUMENT, "proxy is not valid UTF-8") };
                return false;
            },
        }
    };
    match tari_indexer_client::proxy::set_http_proxy(proxy) {
        Ok(()) => true,
        Err(e) => {
            unsafe { report(error_out, ERR_ARGUMENT, e) };
            false
        },
    }
}

/// Opens the Ootle wallet for an open L1 wallet, using its seed. `directory` is the wallet's folder;
/// `network` e.g. "esmeralda"; `password` the Clew password (it encrypts the Ootle database).
/// Returns null on error. Close with `clew_ootle_close`.
///
/// # Safety
/// `l1_wallet` must be a live TariWallet; string arguments valid C strings; `error_out` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_open(
    l1_wallet: *mut TariWallet,
    directory: *const c_char,
    network: *const c_char,
    indexer_url: *const c_char,
    password: *const c_char,
    error_out: *mut c_int,
) -> *mut OotleWallet {
    unsafe { clear(error_out) };
    let (Some(directory), Some(network), Some(indexer_url), Some(password)) =
        (unsafe { text(directory) }, unsafe { text(network) }, unsafe { text(indexer_url) }, unsafe { text(password) })
    else {
        unsafe { report(error_out, ERR_ARGUMENT, "missing or invalid argument") };
        return ptr::null_mut();
    };
    if l1_wallet.is_null() {
        unsafe { report(error_out, ERR_ARGUMENT, "no L1 wallet") };
        return ptr::null_mut();
    }
    let result = (|| -> anyhow::Result<OotleWallet> {
        let network = Network::from_str(network).map_err(|e| anyhow::anyhow!("{e}"))?;
        let indexer = Url::parse(indexer_url)?;
        let seed = unsafe { &(*l1_wallet).wallet }
            .db
            .get_master_seed()?
            .ok_or_else(|| anyhow::anyhow!("the L1 wallet has no seed"))?;
        OotleWallet::open(&seed, Path::new(directory), network, indexer, password)
    })();
    match result {
        Ok(wallet) => Box::into_raw(Box::new(wallet)),
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            ptr::null_mut()
        },
    }
}

/// # Safety
/// `wallet` must come from `clew_ootle_open` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_close(wallet: *mut OotleWallet) {
    if !wallet.is_null() {
        drop(unsafe { Box::from_raw(wallet) });
    }
}

/// The wallet's Ootle address (`otl_…`). Free with `clew_string_destroy`.
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_address(wallet: *mut OotleWallet, error_out: *mut c_int) -> *mut c_char {
    unsafe { clear(error_out) };
    match unsafe { wallet.as_ref() } {
        Some(w) => owned(w.address()),
        None => {
            unsafe { report(error_out, ERR_ARGUMENT, "no Ootle wallet") };
            ptr::null_mut()
        },
    }
}

/// Spendable TARI in µT (1 TARI = 1,000,000 µT).
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_balance(wallet: *mut OotleWallet, error_out: *mut c_int) -> u64 {
    unsafe { clear(error_out) };
    let Some(w) = (unsafe { wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "no Ootle wallet") };
        return 0;
    };
    match w.tari_balance() {
        Ok(v) => v,
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            0
        },
    }
}

/// Re-checks the account with the indexer and waits for a scan for private payments. Returns how many
/// new payments it found, or -1 on failure (see `error_out`).
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_refresh(wallet: *mut OotleWallet, error_out: *mut c_int) -> i64 {
    unsafe { clear(error_out) };
    let Some(w) = (unsafe { wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "no Ootle wallet") };
        return -1;
    };
    match w.refresh() {
        Ok(found) => found as i64,
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            -1
        },
    }
}

/// Claims the test network's free 1,000 tTARI into the account. Blocks until the transaction is
/// finalised (up to a few minutes). Returns the fee paid in µT, or 0 on failure (see `error_out`).
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_claim_faucet(wallet: *mut OotleWallet, error_out: *mut c_int) -> u64 {
    unsafe { clear(error_out) };
    let Some(w) = (unsafe { wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "no Ootle wallet") };
        return 0;
    };
    match w.claim_faucet() {
        Ok(fee) => fee,
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            0
        },
    }
}

/// The fee in µT for sending `amount` µT of TARI to `address`. Makes trial runs over the network
/// (nothing is sent). Returns 0 on failure (see `error_out`).
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `address` a C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_estimate_send_fee(
    wallet: *mut OotleWallet,
    address: *const c_char,
    amount: u64,
    error_out: *mut c_int,
) -> u64 {
    unsafe { clear(error_out) };
    let (Some(w), Some(address)) = (unsafe { wallet.as_ref() }, unsafe { text(address) }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "missing wallet or address") };
        return 0;
    };
    match w.estimate_send_fee(address, amount) {
        Ok(fee) => fee,
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            0
        },
    }
}

/// Sends `amount` µT of TARI privately to `address`, paying at most `max_fee` µT. Blocks until the
/// network finalises it. Returns the fee charged in µT, or 0 on failure (see `error_out`).
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `address` a C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_send(
    wallet: *mut OotleWallet,
    address: *const c_char,
    amount: u64,
    max_fee: u64,
    error_out: *mut c_int,
) -> u64 {
    unsafe { clear(error_out) };
    let (Some(w), Some(address)) = (unsafe { wallet.as_ref() }, unsafe { text(address) }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "missing wallet or address") };
        return 0;
    };
    match w.send(address, amount, max_fee) {
        Ok(fee) => fee,
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            0
        },
    }
}

/// Burns `amount` µT of XTM from `l1_wallet` to this Ootle account, at `fee_per_gram` µT. The XTM
/// can't be recovered; it is claimed as TARI with `clew_ootle_claim_burns` once confirmed. Refused
/// if the two wallets are on different networks. Returns the L1 transaction id, or 0 on failure.
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `l1_wallet` a live TariWallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_burn_from_l1(
    wallet: *mut OotleWallet,
    l1_wallet: *mut TariWallet,
    amount: u64,
    fee_per_gram: u64,
    error_out: *mut c_int,
) -> u64 {
    unsafe { clear(error_out) };
    let (Some(w), Some(l1)) = (unsafe { wallet.as_ref() }, unsafe { l1_wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "missing wallet") };
        return 0;
    };
    match w.burn_from_l1(&l1.wallet, amount, fee_per_gram) {
        Ok(tx_id) => tx_id,
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            0
        },
    }
}

/// Claims every confirmed burn from `l1_wallet` to this account that Ootle accepts now. Sets
/// `waiting_out` (may be null) to how many aren't claimable yet. Returns how many were claimed, or
/// -1 on failure. If one burn couldn't be claimed, `error_out` says why even though the others were
/// tried (and the count is still returned).
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `l1_wallet` a live TariWallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_claim_burns(
    wallet: *mut OotleWallet,
    l1_wallet: *mut TariWallet,
    waiting_out: *mut u32,
    error_out: *mut c_int,
) -> i64 {
    unsafe { clear(error_out) };
    let (Some(w), Some(l1)) = (unsafe { wallet.as_ref() }, unsafe { l1_wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "missing wallet") };
        return -1;
    };
    match w.claim_burns(&l1.wallet) {
        Ok(summary) => {
            if let Some(waiting) = unsafe { waiting_out.as_mut() } {
                *waiting = summary.waiting;
            }
            // Claims that went through still count; a problem with another burn is reported too.
            if let Some(problem) = summary.problem {
                unsafe { report(error_out, ERR_FAILED, problem) };
            }
            i64::from(summary.claimed)
        },
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            -1
        },
    }
}

/// The account's TARI history as JSON (`{"total":…, "entries":[{"id","change","fee","kind",
/// "transaction_id","time"}]}`), newest first. Free with `clew_string_destroy`; null on failure.
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_history(
    wallet: *mut OotleWallet,
    offset: u32,
    limit: u32,
    error_out: *mut c_int,
) -> *mut c_char {
    unsafe { clear(error_out) };
    let Some(w) = (unsafe { wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "no Ootle wallet") };
        return ptr::null_mut();
    };
    match w.history_json(offset as usize, limit as usize) {
        Ok(json) => owned(&json),
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            ptr::null_mut()
        },
    }
}

/// This account's burns from `l1_wallet` and how far each has got, newest first, as JSON
/// (`[{"amount","time","status"}]`, status "confirming", "waiting" or "claimed"). Local data only.
/// Free with `clew_string_destroy`; null on failure.
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `l1_wallet` a live TariWallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_burns(
    wallet: *mut OotleWallet,
    l1_wallet: *mut TariWallet,
    error_out: *mut c_int,
) -> *mut c_char {
    unsafe { clear(error_out) };
    let (Some(w), Some(l1)) = (unsafe { wallet.as_ref() }, unsafe { l1_wallet.as_ref() }) else {
        unsafe { report(error_out, ERR_ARGUMENT, "missing wallet") };
        return ptr::null_mut();
    };
    match w.burns_json(&l1.wallet) {
        Ok(json) => owned(&json),
        Err(e) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            ptr::null_mut()
        },
    }
}
