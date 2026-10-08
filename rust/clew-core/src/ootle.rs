//! An Ootle (Tari L2) wallet, run in-process with the Ootle wallet SDK and its services: the stealth
//! UTXO scanner, the account monitor and the transaction service. Its keys come from the same
//! 24-word seed as the L1 wallet (same derivation as Ootle's own wallet), and its database is
//! encrypted with the Clew password.

use std::{path::Path, str::FromStr, time::Duration};

use anyhow::Context;
use ootle_byte_type::ToByteType;
use ootle_network::Network;
use tari_ootle_app_utilities::genesis_resources::{get_public_identity_resource, get_stealth_tari_resource};
use tari_common_types::seeds::{
    cipher_seed::CipherSeed,
    mnemonic::{Mnemonic, MnemonicLanguage},
};
use tari_crypto::tari_utilities::SafePassword;
use tari_engine_types::commit_result::RejectReason;
use tari_ootle_common_types::{Epoch, InputDeclaration, SubstateRequirement, optional::Optional};
use tari_ootle_transaction::{Transaction, args};
use tari_ootle_wallet_sdk::{
    OotleAddress,
    WalletSdk,
    WalletSdkConfig,
    WalletSdkSpec,
    apis::{
        config::{ConfigApi, ConfigKey},
        confidential_transfer::UtxoInputSelection,
        stealth_transfer::{BadgeUsage, StealthTransferParams, TransferFeeParams, TransferOutput},
    },
    cipher_seed::CipherSeedRestore,
    crypto::{memo::Memo, pay_to::PayTo},
    local_key_store::LocalKeyStore,
    models::{EpochBirthday, NewAccountData, TransactionContext, TransactionContextKind, WalletEvent},
    network::WalletNetworkInterface,
};
use tari_ootle_wallet_sdk_services::{
    Shutdown,
    account_monitor::{AccountMonitor, AccountMonitorHandle},
    account_recovery::AccountRecoveryService,
    indexer_rest_api::IndexerRestApiNetworkInterface,
    notify::Notify,
    transaction_service::{TransactionService, TransactionServiceHandle},
    utxo_scanner::{StealthUtxoScannerWorker, UtxoRecovery, UtxoScannerHandle},
};
use tari_ootle_wallet_storage_sqlite::SqliteWalletStore;
use tari_template_lib::types::{
    Amount,
    ComponentAddress,
    constants::{
        STEALTH_TARI_RESOURCE_ADDRESS,
        XTR_FAUCET_CLAIM_RESOURCE_ADDRESS,
        XTR_FAUCET_COMPONENT_ADDRESS,
        XTR_FAUCET_VAULT_ADDRESS,
    },
};
use tokio::{runtime::Runtime, sync::broadcast};
use url::Url;
use zeroize::Zeroizing;

mod bridge;

pub struct ClewSpec;

impl WalletSdkSpec for ClewSpec {
    type KeyStore = LocalKeyStore;
    type NetworkInterface = IndexerRestApiNetworkInterface;
    type Store = SqliteWalletStore;
}

type Sdk = WalletSdk<ClewSpec>;

/// How many empty account indexes recovery checks before it stops looking (Ootle's default).
const RECOVERY_ABANDON_COUNT: usize = 10;

/// How many epochs ahead a transaction stays valid (Ootle's wallet default).
const TRANSACTION_VALIDITY_EPOCHS: u64 = 3;

/// The most a faucet claim may spend on fees, in µT. It creates the account and its vault, so it costs
/// more than a transfer; Ootle's own wallet uses the same figure. Unused fee is refunded.
const FAUCET_MAX_FEE: u64 = 50_000;

/// How many trial runs a fee estimate may take before giving up (Ootle's wallet daemon allows the same).
const MAX_FEE_ESTIMATE_ROUNDS: usize = 5;

/// How long to wait for a submitted transaction to be finalised.
const FINALISE_TIMEOUT: Duration = Duration::from_secs(180);

pub struct OotleWallet {
    runtime: Runtime,
    shutdown: Shutdown,
    sdk: Sdk,
    transactions: TransactionServiceHandle,
    notify: Notify<WalletEvent>,
    account_monitor: AccountMonitorHandle,
    scanner: UtxoScannerHandle,
    account: ComponentAddress,
    address: String,
    network: Network,
}

impl OotleWallet {
    /// Opens (or creates) the Ootle wallet in `directory` for `seed`, the L1 wallet's seed.
    pub fn open(l1_seed: &CipherSeed, directory: &Path, network: Network, indexer: Url, password: &str) -> anyhow::Result<Self> {
        let seed = &seed_for_network(l1_seed, network)?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("clew-ootle")
            .build()?;
        // The SDK's services spawn onto the ambient runtime.
        let _guard = runtime.enter();

        let store = SqliteWalletStore::try_open(directory.join("ootle.sqlite")).context("opening the Ootle database")?;
        store.run_migrations()?;
        // The stored seed is the L1 wallet's seed, encrypted with the Clew password. Re-encrypt it with
        // the current password each time, so a password change made while this wallet was closed
        // carries over. (A first open has no stored seed yet; the SDK stores it below.)
        let config_api = ConfigApi::new(&store);
        if config_api.get::<Zeroizing<Box<[u8]>>>(ConfigKey::CipherSeed).optional()?.is_some() {
            config_api.set(ConfigKey::CipherSeed, &seed.encipher(Some(SafePassword::from(password)))?)?;
        }
        let interface = IndexerRestApiNetworkInterface::init(vec![indexer])?;
        let config = WalletSdkConfig {
            network,
            // The SDK would otherwise keep this password in the OS keyring.
            override_keyring_password: Some(SafePassword::from(password)),
        };
        let mut sdk = Sdk::initialize_with_local_key_store(store, interface, config, EpochBirthday::far_future())?;
        let words = seed.to_mnemonic(MnemonicLanguage::English, None)?;
        let needs_recovery = sdk.initialize_cipher_seed(CipherSeedRestore::FromSeedWords(&words))?;

        for (address, resource) in [get_stealth_tari_resource(network), get_public_identity_resource(network)] {
            sdk.resources_api().upsert_resource(&address, &resource)?;
        }

        let shutdown = Shutdown::new();
        let notify = Notify::new(100);
        let (transaction_service, transactions) =
            TransactionService::new(notify.clone(), sdk.clone(), shutdown.to_signal());
        runtime.spawn(transaction_service.run());
        let (_scanner_task, scanner) = StealthUtxoScannerWorker::new(sdk.clone(), notify.clone()).spawn();
        runtime.spawn(UtxoRecovery::new(sdk.clone()).with_notify(notify.clone()).run(scanner.subscribe_notifications()));
        let (account_monitor_service, account_monitor) =
            AccountMonitor::new(notify.clone(), sdk.clone(), scanner.clone(), shutdown.to_signal());
        runtime.spawn(account_monitor_service.run());

        // Clew uses the first account (key index 0), as Ootle's own wallet does for its default account.
        let keys = sdk.key_manager_api().derive_account_address(0)?;
        let accounts = sdk.accounts_api();
        let account = if accounts.any_accounts_exist()? {
            let account = accounts.get_default()?;
            anyhow::ensure!(
                account.account.owner_public_key == keys.address.account_key().to_byte_type(),
                "this Ootle wallet was made from a different seed"
            );
            account
        } else {
            accounts.create_account(Some("Clew"), true, keys)?
        };

        if needs_recovery {
            let birthday = sdk.key_manager_api().get_cipher_seed_birthday_epoch()?;
            let recovery = AccountRecoveryService::new(
                sdk.clone(),
                account_monitor.clone(),
                scanner.clone(),
                RECOVERY_ABANDON_COUNT,
                birthday,
            );
            let signal = shutdown.to_signal();
            runtime.spawn(async move {
                let scan = std::pin::pin!(recovery.scan());
                signal.select(scan).await;
            });
        }

        Ok(Self {
            account: *account.account.component_address(),
            address: account.address.to_string(),
            runtime,
            shutdown,
            sdk,
            transactions,
            notify,
            account_monitor,
            scanner,
            network,
        })
    }

    /// The address others pay TARI to (`otl_…`).
    pub fn address(&self) -> &str {
        &self.address
    }

    /// TARI in µT: the account vault's revealed balance (where faucet and claimed-burn funds land) plus
    /// the unspent stealth outputs the scanner has found for the account.
    pub fn tari_balance(&self) -> anyhow::Result<u64> {
        let outputs = self.sdk.stealth_outputs_api().get_unspent_outputs_by_account(&self.account, false)?;
        let stealth: u64 = outputs
            .iter()
            .filter(|o| o.resource_address == STEALTH_TARI_RESOURCE_ADDRESS)
            .map(|o| o.value)
            .sum();
        let revealed = self
            .sdk
            .accounts_api()
            .get_vaults_by_account(&self.account)?
            .iter()
            .filter(|v| v.resource_address == STEALTH_TARI_RESOURCE_ADDRESS)
            .map(|v| v.revealed_balance.to_u64_checked().unwrap_or(0))
            .sum::<u64>();
        Ok(stealth.saturating_add(revealed))
    }

    /// Claims the test network's one-off 1,000 tTARI. The same transaction creates the account on chain
    /// if it isn't yet. Returns the fee paid, in µT.
    pub fn claim_faucet(&self) -> anyhow::Result<u64> {
        let account = self.sdk.accounts_api().get_account_by_address(&self.account)?;
        let owner_key = account.owner_key_id().context("the account has no owner key")?;

        let mut inputs = vec![
            SubstateRequirement::unversioned(XTR_FAUCET_COMPONENT_ADDRESS),
            SubstateRequirement::unversioned(XTR_FAUCET_VAULT_ADDRESS),
            SubstateRequirement::unversioned(XTR_FAUCET_CLAIM_RESOURCE_ADDRESS),
        ];
        if account.is_confirmed_on_chain() {
            let substates = self.sdk.substate_api();
            inputs.push(substates.get_substate(&self.account.into())?.substate_id.into());
            inputs.extend(substates.load_dependent_substates(&[&self.account.into()])?);
        }

        let network = self.sdk.network();
        let public_key = *account.address.account_public_key();
        self.runtime.block_on(async {
            let max_epoch = self.max_epoch().await?;
            let transaction = Transaction::builder(network.as_byte(), max_epoch)
                .with_nonce(rand::random())
                .with_fee_instructions_builder(|fee| {
                    fee.create_account(public_key)
                        .put_last_instruction_output_on_workspace("new_account")
                        .call_method(XTR_FAUCET_COMPONENT_ADDRESS, "take", args![Workspace("new_account")])
                        .call_method("new_account", "pay_fee", args![FAUCET_MAX_FEE])
                })
                .with_inputs(inputs.into_iter().map(|i| InputDeclaration::write(i.into_substate_id())))
                .finish();
            let transaction = self.sdk.signer_api().sign(owner_key, transaction)?;

            let mut context = TransactionContext::with_accounts([self.account]);
            if account.is_confirmed_on_chain() {
                context = context.with_kind(TransactionContextKind::NewAccount(NewAccountData { address: self.account }));
            }
            let mut events = self.notify.subscribe();
            let id = self
                .transactions
                .submit_transaction_with_opts(transaction, Some(context), None)
                .await?;
            let finalised = tokio::time::timeout(FINALISE_TIMEOUT, wait_for_account_update(&mut events, &id, &self.account))
                .await
                .context("timed out waiting for the faucet transaction")??;

            match finalised.finalize.any_reject() {
                None => Ok(finalised.final_fee),
                Some(RejectReason::ExecutionFailure { message, .. }) if message.contains("Duplicate NFT token id") => {
                    anyhow::bail!("This wallet has already claimed its free test TARI.")
                },
                // The faucet records a claim before paying it out, so this comes after the check above.
                Some(RejectReason::ExecutionFailure { message, .. }) if message.contains("insufficient") => {
                    anyhow::bail!("The testnet faucet has run out of free TARI for now. Try again later.")
                },
                Some(RejectReason::FailedToLockOutputs(r) | RejectReason::FailedToLockInputs(r))
                    if r.contains("is already UP and conflicts with an existing output") =>
                {
                    anyhow::bail!("This wallet has already claimed its free test TARI.")
                },
                Some(reason) => anyhow::bail!("The faucet transaction was rejected: {reason}"),
            }
        })
    }

    /// The fee in µT that sending `amount` µT of TARI to `address` will cost, found the way Ootle's own
    /// wallet finds it: trial runs (nothing is submitted) at increasing fees until one covers itself.
    /// The fee decides which of the wallet's funds are spent, so it has to be settled before sending.
    pub fn estimate_send_fee(&self, address: &str, amount: u64) -> anyhow::Result<u64> {
        let output = self.transfer_output(address, amount)?;
        self.runtime.block_on(async {
            let mut fee = 1;
            let mut verified = false;
            for _ in 0..MAX_FEE_ESTIMATE_ROUNDS {
                let (lock, transaction) = self.build_transfer(output.clone(), fee, true).await?;
                lock.release();
                let result = self.transactions.submit_dry_run_transaction(transaction).await?.finalize;
                // A fee a previous run named that also covers this run's cost is settled.
                if verified && result.charged_fees() <= fee {
                    if let Some(reason) = result.any_reject() {
                        anyhow::bail!("The transfer would be rejected: {reason}");
                    }
                    return Ok(fee);
                }
                fee = result.required_fees();
                verified = true;
            }
            anyhow::bail!("The network fee didn't settle; try again")
        })
    }

    /// Sends `amount` µT of TARI to `address` privately, paying at most `max_fee` µT (from
    /// `estimate_send_fee`). Blocks until the network finalises it. Returns the fee charged in µT.
    pub fn send(&self, address: &str, amount: u64, max_fee: u64) -> anyhow::Result<u64> {
        let output = self.transfer_output(address, amount)?;
        let mut linked = vec![self.account];
        if let Ok(own) = self.sdk.accounts_api().get_account_by_public_key(output.address.account_public_key()) {
            linked.push(own.account.component_address);
        }
        self.runtime.block_on(async {
            let (lock, transaction) = self.build_transfer(output, max_fee, false).await?;
            let mut events = self.notify.subscribe();
            let id = self
                .transactions
                .submit_transaction_with_opts(transaction, Some(TransactionContext::with_accounts(linked)), Some(lock.id()))
                .await?;
            // The transaction service now owns the lock and releases it when the transaction resolves.
            lock.keep_locked();
            let finalised = tokio::time::timeout(FINALISE_TIMEOUT, wait_for_account_update(&mut events, &id, &self.account))
                .await
                .context("the network hasn't confirmed the transfer yet")??;
            match finalised.finalize.any_reject() {
                None => Ok(finalised.final_fee),
                Some(reason) => anyhow::bail!("The transfer was rejected: {reason}"),
            }
        })
    }

    fn transfer_output(&self, address: &str, amount: u64) -> anyhow::Result<TransferOutput> {
        let address = OotleAddress::from_str(address.trim()).context("that isn't a valid Ootle address")?;
        anyhow::ensure!(amount > 0, "the amount must be more than zero");
        // A payment reference in the address (as exchanges use) travels in the encrypted memo, as Ootle's
        // own wallet sends it.
        let memo = address
            .pay_ref()
            .map(|r| Memo::new_pay_ref_and_bytes_truncate(r.as_bytes(), b"").context("payment reference too long"))
            .transpose()?;
        Ok(TransferOutput {
            address,
            revealed_amount: Amount::zero(),
            blinded_amount: amount,
            memo,
            pay_to: PayTo::StealthPublicKey,
        })
    }

    /// Builds and signs a private TARI transfer, mirroring Ootle's wallet daemon. The returned lock
    /// holds the funds it spends.
    async fn build_transfer(
        &self,
        output: TransferOutput,
        max_fee: u64,
        is_dry_run: bool,
    ) -> anyhow::Result<(tari_ootle_wallet_sdk::models::WalletLockDropGuard<'_, SqliteWalletStore>, Transaction)> {
        let account = self.sdk.accounts_api().get_account_by_address(&self.account)?;
        let params = StealthTransferParams {
            fee_params: TransferFeeParams::new(UtxoInputSelection::PreferRevealed),
            input_selection: UtxoInputSelection::PreferRevealed,
            outputs: vec![output],
            badge_usage: BadgeUsage::None,
            resource_address: STEALTH_TARI_RESOURCE_ADDRESS,
            max_fee,
            max_epoch: self.max_epoch().await?,
            is_dry_run,
        };
        let (lock, transfer) = self.sdk.stealth_transfer_api().transfer(account, params).await?;

        let main_key = transfer.main_signer.public_key().to_byte_type();
        let signer = self.sdk.signer_api().with_context(&main_key);
        let transaction = match transfer.additional_signer.as_ref() {
            Some(s) => signer.sign(s.key_id, transfer.transaction)?,
            None => transfer.transaction.finish(),
        };
        let transaction = transfer
            .utxo_spend_keys
            .iter()
            .try_fold(transaction, |tx, key| signer.sign_with_stealth_key(key, tx))?;
        let transaction = self.sdk.signer_api().sign(transfer.main_signer.key_id, transaction)?;
        Ok((lock, transaction))
    }

    async fn current_epoch(&self) -> anyhow::Result<u64> {
        Ok(self.sdk.get_network_interface().get_current_epoch().await?.as_u64())
    }

    async fn max_epoch(&self) -> anyhow::Result<Epoch> {
        Ok(Epoch(self.current_epoch().await?.saturating_add(TRANSACTION_VALIDITY_EPOCHS)))
    }

    /// The account's TARI history, newest first: each change to its balance (in µT, negative when
    /// funds left, fees included), as JSON for the app.
    pub fn history_json(&self, offset: usize, limit: usize) -> anyhow::Result<String> {
        let page = self.sdk.accounts_api().get_balance_changes(
            &self.account,
            offset,
            limit,
            Some(&STEALTH_TARI_RESOURCE_ADDRESS),
            None,
            None,
        )?;
        let transactions = self.sdk.transaction_api();
        let entries = page
            .changes
            .iter()
            .map(|c| {
                let before = c.revealed_before.to_u128() as i128 + c.confidential_before.to_u128() as i128;
                let after = c.revealed_after.to_u128() as i128 + c.confidential_after.to_u128() as i128;
                let fee = c
                    .transaction_id
                    .and_then(|id| transactions.get(id).ok())
                    .and_then(|t| t.final_fee)
                    .filter(|_| after < before);
                HistoryEntry {
                    id: c.id,
                    change: i64::try_from(after - before).unwrap_or(0),
                    fee,
                    kind: c.source.as_key_str(),
                    transaction_id: c.transaction_id.map(|id| id.to_string()),
                    time: c.created_at.assume_utc().unix_timestamp(),
                }
            })
            .collect::<Vec<_>>();
        Ok(serde_json::to_string(&History { total: page.total, entries })?)
    }

    /// Re-checks the account with the indexer and scans for private payments to it, waiting for both.
    /// Returns how many new payments the scan found (they count towards the balance once checked,
    /// which happens in the background straight after).
    pub fn refresh(&self) -> anyhow::Result<usize> {
        self.runtime.block_on(async {
            // The scan doesn't depend on the account check, so a failed check doesn't skip it.
            let checked = self.account_monitor.refresh_account(self.account).await;
            let stats = self.scanner.scan(self.account, STEALTH_TARI_RESOURCE_ADDRESS).await?;
            checked?;
            Ok(stats.num_potential_recoveries)
        })
    }
}

#[derive(serde::Serialize)]
struct History {
    total: u64,
    entries: Vec<HistoryEntry>,
}

#[derive(serde::Serialize)]
struct HistoryEntry {
    id: i32,
    /// µT; negative when funds left the account.
    change: i64,
    /// µT, on outgoing changes made by this wallet's own transactions.
    fee: Option<u64>,
    /// "transaction" (this wallet's), "scan" (found on chain, e.g. a payment received) or "recovery".
    kind: &'static str,
    transaction_id: Option<String>,
    /// Unix seconds.
    time: i64,
}

/// The seed the Ootle wallet uses on `network`. On mainnet it is the L1 wallet's seed, as in Tari's
/// own wallets, so the 24 words restore it anywhere. Ootle's keys don't depend on the network, so on a
/// test network it is a separate seed derived one-way from it: testnet activity then shares no key or
/// account address with the real account.
fn seed_for_network(seed: &CipherSeed, network: Network) -> anyhow::Result<CipherSeed> {
    use blake2::{Blake2b512, Digest};
    if network == Network::MainNet {
        return Ok(seed.clone());
    }
    let digest = Zeroizing::new(
        Blake2b512::new()
            .chain_update(b"clew.ootle.test_network_seed.v1")
            .chain_update([network.as_byte()])
            .chain_update(seed.entropy())
            .finalize(),
    );
    // CipherSeed can only be built from its parts through serde. 2 is Tari's current seed version.
    #[derive(serde::Serialize)]
    struct Parts<'a> {
        version: u8,
        birthday: u16,
        entropy: &'a [u8],
        salt: &'a [u8],
    }
    let json = Zeroizing::new(serde_json::to_vec(&Parts {
        version: 2,
        birthday: seed.birthday(),
        entropy: &digest[..16],
        salt: &digest[16..21],
    })?);
    Ok(serde_json::from_slice(&json)?)
}

/// Waits until `transaction` is finalised and, if it was accepted, until the account monitor has seen
/// the change to `account`, so balances read afterwards include it. Mirrors Ootle's wallet daemon.
async fn wait_for_account_update(
    events: &mut broadcast::Receiver<WalletEvent>,
    transaction: &tari_ootle_transaction::TransactionId,
    account: &ComponentAddress,
) -> anyhow::Result<tari_ootle_wallet_sdk::models::TransactionFinalizedEvent> {
    let mut result = None;
    let mut account_seen = false;
    loop {
        match events.recv().await {
            Ok(WalletEvent::TransactionFinalized(e)) if e.transaction_id == *transaction => result = Some(e),
            Ok(WalletEvent::TransactionInvalid(e)) if e.transaction_id == *transaction => {
                anyhow::bail!("The transaction was invalid ({})", e.status)
            },
            Ok(WalletEvent::AccountCreatedOnChain(e)) if e.account.component_address == *account => account_seen = true,
            Ok(WalletEvent::AccountChangedOnChain(e)) if e.account_address == *account => account_seen = true,
            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {},
            Err(broadcast::error::RecvError::Closed) => anyhow::bail!("the wallet is shutting down"),
        }
        if let Some(r) = &result {
            if r.finalize.result.is_reject() || (r.finalize.result.is_any_accept() && account_seen) {
                return Ok(result.unwrap());
            }
        }
    }
}

impl Drop for OotleWallet {
    fn drop(&mut self) {
        self.shutdown.trigger();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_network_seed_is_separate_and_stable() {
        let seed = CipherSeed::random();
        let test = seed_for_network(&seed, Network::Esmeralda).unwrap();
        assert_ne!(test.entropy(), seed.entropy());
        assert_eq!(test.birthday(), seed.birthday());
        assert_eq!(seed_for_network(&seed, Network::Esmeralda).unwrap(), test);
        assert_ne!(seed_for_network(&seed, Network::Igor).unwrap(), test);
        assert_eq!(seed_for_network(&seed, Network::MainNet).unwrap(), seed);

        // The SDK stores the seed through its 24 words.
        let words = test.to_mnemonic(MnemonicLanguage::English, None).unwrap();
        assert_eq!(CipherSeed::from_mnemonic(&words, None).unwrap(), test);
    }
}
