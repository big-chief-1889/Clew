//! C functions for the Ootle wallet. Errors are reported through `error_out` (0 = none), with a
//! human-readable description from `clew_last_error`. Strings returned to the caller are freed with
//! `clew_string_destroy`. A panic inside a call is caught and reported as an error, never unwound
//! into the caller.

use std::{
    any::Any,
    cell::RefCell,
    ffi::{CStr, CString, c_char, c_int},
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr,
    str::FromStr,
};

use minotari_wallet_ffi::TariWallet;
use ootle_network::Network;
use url::Url;

use crate::ootle::{BurnSnapshot, OotleWallet, SendOutcome};

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

const ERR_ARGUMENT: c_int = 1;
const ERR_FAILED: c_int = 2;

/// Why a call failed.
enum Failure {
    Argument(&'static str),
    Failed(anyhow::Error),
}

impl From<anyhow::Error> for Failure {
    fn from(e: anyhow::Error) -> Self {
        Self::Failed(e)
    }
}

unsafe fn report(error_out: *mut c_int, code: c_int, message: impl ToString) {
    if !error_out.is_null() {
        unsafe { *error_out = code };
    }
    let text = message.to_string().replace('\0', " ");
    LAST_ERROR.with(|e| *e.borrow_mut() = CString::new(text).ok());
}

/// Runs a call's `body`, reporting its failure (or a panic) through `error_out` and returning
/// `on_error` then.
fn guarded<T>(error_out: *mut c_int, on_error: T, body: impl FnOnce() -> Result<T, Failure>) -> T {
    if !error_out.is_null() {
        unsafe { *error_out = 0 };
    }
    LAST_ERROR.with(|e| *e.borrow_mut() = None);
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => value,
        Ok(Err(Failure::Argument(message))) => {
            unsafe { report(error_out, ERR_ARGUMENT, message) };
            on_error
        },
        Ok(Err(Failure::Failed(e))) => {
            unsafe { report(error_out, ERR_FAILED, format!("{e:#}")) };
            on_error
        },
        Err(panic) => {
            unsafe { report(error_out, ERR_FAILED, format!("internal error in the wallet library: {}", panic_text(&panic))) };
            on_error
        },
    }
}

fn panic_text(panic: &Box<dyn Any + Send>) -> &str {
    panic
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("unknown")
}

unsafe fn text<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() { None } else { unsafe { CStr::from_ptr(value) }.to_str().ok() }
}

fn owned(text: &str) -> *mut c_char {
    CString::new(text.replace('\0', " ")).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

unsafe fn ootle<'a>(wallet: *mut OotleWallet) -> Result<&'a OotleWallet, Failure> {
    unsafe { wallet.as_ref() }.ok_or(Failure::Argument("no Ootle wallet"))
}

unsafe fn l1<'a>(wallet: *mut TariWallet) -> Result<&'a TariWallet, Failure> {
    unsafe { wallet.as_ref() }.ok_or(Failure::Argument("no L1 wallet"))
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

/// Routes Ootle indexer connections made after this call through `proxy` (a `socks5h://` URL, e.g.
/// Tor's), or directly when null. Until this is called they go nowhere. Open Ootle wallets keep their
/// route, so reopen them after changing it.
///
/// # Safety
/// `proxy` must be null or a valid C string; `error_out` may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_set_proxy(proxy: *const c_char, error_out: *mut c_int) -> bool {
    guarded(error_out, false, || {
        let proxy = if proxy.is_null() {
            None
        } else {
            Some(unsafe { text(proxy) }.ok_or(Failure::Argument("proxy is not valid UTF-8"))?.to_string())
        };
        tari_indexer_client::proxy::set_http_proxy(proxy).map_err(|e| Failure::Failed(e.into()))?;
        Ok(true)
    })
}

/// Opens the Ootle wallet for an open L1 wallet, using its seed. `directory` is the wallet's folder;
/// `network` e.g. "esmeralda"; `password` the Clew password (it encrypts the stored seed).
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
    guarded(error_out, ptr::null_mut(), || {
        let (Some(directory), Some(network), Some(indexer_url), Some(password)) =
            (unsafe { text(directory) }, unsafe { text(network) }, unsafe { text(indexer_url) }, unsafe { text(password) })
        else {
            return Err(Failure::Argument("missing or invalid argument"));
        };
        let l1 = unsafe { l1(l1_wallet) }?;
        let network = Network::from_str(network).map_err(|e| anyhow::anyhow!("{e}"))?;
        let indexer = Url::parse(indexer_url).map_err(anyhow::Error::from)?;
        let seed = l1
            .wallet
            .db
            .get_master_seed()
            .map_err(anyhow::Error::from)?
            .ok_or_else(|| anyhow::anyhow!("the L1 wallet has no seed"))?;
        let wallet = OotleWallet::open(&seed, Path::new(directory), network, indexer, password)?;
        Ok(Box::into_raw(Box::new(wallet)))
    })
}

/// # Safety
/// `wallet` must come from `clew_ootle_open` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_close(wallet: *mut OotleWallet) {
    guarded(ptr::null_mut(), (), || {
        if !wallet.is_null() {
            drop(unsafe { Box::from_raw(wallet) });
        }
        Ok(())
    })
}

/// The wallet's Ootle address (`otl_…`). Free with `clew_string_destroy`.
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_address(wallet: *mut OotleWallet, error_out: *mut c_int) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || Ok(owned(unsafe { ootle(wallet) }?.address())))
}

/// Spendable TARI in µT (1 TARI = 1,000,000 µT).
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_balance(wallet: *mut OotleWallet, error_out: *mut c_int) -> u64 {
    guarded(error_out, 0, || Ok(unsafe { ootle(wallet) }?.tari_balance()?))
}

/// Re-checks the account with the indexer and waits for a scan for private payments. Returns how many
/// new payments it found, or -1 on failure (see `error_out`).
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_refresh(wallet: *mut OotleWallet, error_out: *mut c_int) -> i64 {
    guarded(error_out, -1, || Ok(unsafe { ootle(wallet) }?.refresh()? as i64))
}

/// Claims the test network's free 1,000 tTARI into the account. Blocks until the transaction is
/// finalised (up to a few minutes). Returns the fee paid in µT, or 0 on failure (see `error_out`).
///
/// # Safety
/// `wallet` must be a live Ootle wallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_claim_faucet(wallet: *mut OotleWallet, error_out: *mut c_int) -> u64 {
    guarded(error_out, 0, || Ok(unsafe { ootle(wallet) }?.claim_faucet()?))
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
    guarded(error_out, 0, || {
        let address = unsafe { text(address) }.ok_or(Failure::Argument("missing address"))?;
        Ok(unsafe { ootle(wallet) }?.estimate_send_fee(address, amount)?)
    })
}

/// Sends `amount` µT of TARI privately to `address`, paying at most `max_fee` µT. Blocks until the
/// network finalises it and returns the fee charged in µT. If that's taking longer, returns 0 with
/// `pending_out` set: the wallet keeps trying and the funds stay locked, so it must not be sent again.
/// Returns 0 with `error_out` set if it failed.
///
/// # Safety
/// `wallet` must be a live Ootle wallet, `address` a C string, `pending_out` null or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_send(
    wallet: *mut OotleWallet,
    address: *const c_char,
    amount: u64,
    max_fee: u64,
    pending_out: *mut bool,
    error_out: *mut c_int,
) -> u64 {
    if let Some(pending) = unsafe { pending_out.as_mut() } {
        *pending = false;
    }
    guarded(error_out, 0, || {
        let address = unsafe { text(address) }.ok_or(Failure::Argument("missing address"))?;
        match unsafe { ootle(wallet) }?.send(address, amount, max_fee)? {
            SendOutcome::Confirmed { fee } => Ok(fee),
            SendOutcome::Pending => {
                if let Some(pending) = unsafe { pending_out.as_mut() } {
                    *pending = true;
                }
                Ok(0)
            },
        }
    })
}

/// Burns `amount` µT of XTM (at least `CLEW_MIN_BURN`) from `l1_wallet` to this Ootle account, at
/// `fee_per_gram` µT. The XTM can't be recovered; it is claimed as TARI with `clew_ootle_claim_burns`
/// once confirmed. Refused if the two wallets are on different networks. Returns the L1 transaction
/// id, or 0 on failure.
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
    guarded(error_out, 0, || {
        Ok(unsafe { ootle(wallet) }?.burn_from_l1(&unsafe { l1(l1_wallet) }?.wallet, amount, fee_per_gram)?)
    })
}

/// The smallest burn `clew_ootle_burn_from_l1` makes, in µT.
#[unsafe(no_mangle)]
pub extern "C" fn clew_ootle_min_burn() -> u64 {
    crate::ootle::MIN_BURN
}

/// Reads `l1_wallet`'s burns, a quick local step, for `clew_ootle_burns` and `clew_ootle_claim_burns`
/// (which needn't hold the L1 wallet while they wait on the network). Null on failure. Free with
/// `clew_burn_snapshot_destroy`.
///
/// # Safety
/// `l1_wallet` must be a live TariWallet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_burn_snapshot(l1_wallet: *mut TariWallet, error_out: *mut c_int) -> *mut BurnSnapshot {
    guarded(error_out, ptr::null_mut(), || {
        Ok(Box::into_raw(Box::new(BurnSnapshot::of(&unsafe { l1(l1_wallet) }?.wallet)?)))
    })
}

/// # Safety
/// `snapshot` must come from `clew_burn_snapshot` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_burn_snapshot_destroy(snapshot: *mut BurnSnapshot) {
    guarded(ptr::null_mut(), (), || {
        if !snapshot.is_null() {
            drop(unsafe { Box::from_raw(snapshot) });
        }
        Ok(())
    })
}

/// Claims every confirmed burn in `snapshot` to this account that Ootle accepts now. Sets
/// `waiting_out` (may be null) to how many aren't claimable yet. Returns how many were claimed, or
/// -1 on failure. If one burn couldn't be claimed, `error_out` says why even though the others were
/// tried (and the count is still returned).
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `snapshot` from `clew_burn_snapshot`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_claim_burns(
    wallet: *mut OotleWallet,
    snapshot: *const BurnSnapshot,
    waiting_out: *mut u32,
    error_out: *mut c_int,
) -> i64 {
    let mut problem = None;
    let claimed = guarded(error_out, -1, || {
        let snapshot = unsafe { snapshot.as_ref() }.ok_or(Failure::Argument("no burn snapshot"))?;
        let summary = unsafe { ootle(wallet) }?.claim_burns(snapshot)?;
        if let Some(waiting) = unsafe { waiting_out.as_mut() } {
            *waiting = summary.waiting;
        }
        problem = summary.problem;
        Ok(i64::from(summary.claimed))
    });
    // Claims that went through still count; a problem with another burn is reported too.
    if let Some(problem) = problem {
        unsafe { report(error_out, ERR_FAILED, problem) };
    }
    claimed
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
    guarded(error_out, ptr::null_mut(), || {
        Ok(owned(&unsafe { ootle(wallet) }?.history_json(offset as usize, limit as usize)?))
    })
}

/// This account's burns in `snapshot` and how far each has got, newest first, as JSON
/// (`[{"amount","time","status"}]`, status "confirming", "waiting" or "claimed"). Local data only.
/// Free with `clew_string_destroy`; null on failure.
///
/// # Safety
/// `wallet` must be a live Ootle wallet and `snapshot` from `clew_burn_snapshot`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clew_ootle_burns(
    wallet: *mut OotleWallet,
    snapshot: *const BurnSnapshot,
    error_out: *mut c_int,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let snapshot = unsafe { snapshot.as_ref() }.ok_or(Failure::Argument("no burn snapshot"))?;
        Ok(owned(&unsafe { ootle(wallet) }?.burns_json(snapshot)?))
    })
}
