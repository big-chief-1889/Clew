//! The one-way bridge from Tari's base layer: XTM burnt on L1 to this wallet's Ootle account is
//! claimed as TARI on Ootle once the burn is buried deep enough for Ootle to accept it.
//!
//! The claim follows Ootle's wallet daemon (`execute_claim_burn` and the auto-claim service), which
//! isn't available as a library.

use std::iter;

use anyhow::Context;
use minotari_wallet::{WalletSqlite, output_manager_service::UtxoSelectionCriteria};
use ootle_byte_type::{FromByteType, ToByteType};
use tari_common_types::types::CompressedPublicKey;
use tari_crypto::{keys::PublicKey as _, ristretto::RistrettoPublicKey, tari_utilities::ByteArray};
use tari_engine_types::{
    commit_result::{ExecutionFailureCode, RejectReason},
    confidential::{ClaimBurnOutputData, MinotariBurnClaimProof},
    substate::SubstateId,
};
use tari_ootle_app_utilities::burn_claim_proof::claim_proof_from_l1;
use tari_ootle_common_types::optional::Optional;
use tari_ootle_wallet_sdk::{
    crypto::{OutputWitness, StealthInputWitness, StealthOutputWitness, memo::Memo},
    models::{KeyBranch, TransactionContext},
};
use tari_sidechain::BurnClaimProof;
use tari_template_lib_types::{
    Amount,
    ClaimedOutputTombstoneAddress,
    EncryptedData,
    constants::{STEALTH_TARI_RESOURCE_ADDRESS, TARI_TOKEN},
    stealth::{RevealedOutput, SpendAuthorization},
};
use tari_transaction_components::{
    MicroMinotari,
    consensus::ConsensusManager,
    transaction_components::{MemoField, memo_field::TxType},
};

use super::{FINALISE_TIMEOUT, OotleWallet, wait_for_account_update};

/// What a pass over the wallet's burns did.
#[derive(Debug, Default)]
pub struct ClaimSummary {
    /// Burns claimed as TARI just now.
    pub claimed: u32,
    /// Burns not claimable yet: still being confirmed on L1, or not yet synced into Ootle.
    pub waiting: u32,
}

impl OotleWallet {
    /// Burns `amount` µT of XTM from `l1` to this wallet's Ootle account. Burnt XTM can't be
    /// recovered on L1; it can only be claimed as TARI on Ootle. Returns the L1 transaction id.
    pub fn burn_from_l1(&self, l1: &WalletSqlite, amount: u64, fee_per_gram: u64) -> anyhow::Result<u64> {
        // A burn made out to an account on another network could never be claimed.
        let l1_network = l1.network.as_network();
        anyhow::ensure!(
            l1_network.as_byte() == self.network.as_byte(),
            "the base layer wallet is on {l1_network} but the Ootle wallet is on {}, so the burn could never be claimed",
            self.network
        );
        anyhow::ensure!(amount > 0, "the amount must be more than zero");

        // L1 makes the burn out to a one-time key derived from this account key, so only this account
        // can claim it and the burn can't be linked to the account on chain.
        let account = self.sdk.accounts_api().get_account_by_address(&self.account)?;
        let claim_key = CompressedPublicKey::from_canonical_bytes(account.account.owner_public_key.as_bytes())
            .map_err(|e| anyhow::anyhow!("account key: {e}"))?;
        let memo = MemoField::new_open_from_string("", TxType::Burn).map_err(anyhow::Error::msg)?;
        let mut transactions = l1.transaction_service.clone();
        let (tx_id, _proof) = self.runtime.block_on(transactions.burn_tari(
            MicroMinotari::from(amount),
            UtxoSelectionCriteria::default(),
            MicroMinotari::from(fee_per_gram),
            memo,
            Some(claim_key),
            None,
        ))?;
        Ok(tx_id.as_u64())
    }

    /// Claims every burn from `l1` to this account that Ootle will now accept, skipping ones already
    /// claimed. The L1 wallet completes a burn's proof once it is confirmed; Ootle accepts the claim
    /// once its own view of L1 has moved past the epoch the burn was mined in.
    pub fn claim_burns(&self, l1: &WalletSqlite) -> anyhow::Result<ClaimSummary> {
        let account = self.sdk.accounts_api().get_account_by_address(&self.account)?;
        let owner_key = account.account.owner_public_key;
        let consensus = ConsensusManager::builder(l1.network.as_network()).build();
        let mut summary = ClaimSummary::default();

        for burn in l1.db.get_all_burn_proofs()? {
            if burn.burn_proof.claim_public_key.as_bytes() != owner_key.as_bytes() {
                continue;
            }
            let (Some(output_proof), Some(encrypted_data), Some(value)) =
                (burn.burn_output_proof, burn.encrypted_data, burn.value)
            else {
                summary.waiting += 1;
                continue;
            };
            let height = output_proof.block_height;
            let mined_in_epoch = consensus.consensus_constants(height).block_height_to_epoch(height).as_u64();
            let claim = claim_proof_from_l1(&BurnClaimProof {
                burn_public_key: burn.burn_proof.claim_public_key,
                ownership_proof: burn.burn_proof.ownership_proof,
                output_proof,
                value: value.as_u64(),
            })
            .map_err(anyhow::Error::msg)?;
            let encrypted_data = EncryptedData::try_from(encrypted_data.into_vec())
                .map_err(|len| anyhow::anyhow!("burn encrypted data has the wrong length ({len})"))?;

            if self.is_claimed(&claim)? {
                continue;
            }
            let current_epoch = self.runtime.block_on(self.current_epoch())?;
            if current_epoch <= mined_in_epoch {
                summary.waiting += 1;
                continue;
            }
            if self.claim_burn(claim, encrypted_data)? {
                summary.claimed += 1;
            } else {
                summary.waiting += 1;
            }
        }
        Ok(summary)
    }

    /// Whether Ootle already has the tombstone a claim of this burn leaves.
    fn is_claimed(&self, claim: &MinotariBurnClaimProof) -> anyhow::Result<bool> {
        let tombstone = SubstateId::from(ClaimedOutputTombstoneAddress::from_commitment(claim.commitment));
        let found = self
            .runtime
            .block_on(self.sdk.substate_api().fetch_substate_from_network(&tombstone, None))
            .optional()?;
        Ok(found.is_some())
    }

    /// Claims one burn: a trial run to price it, then the claim, waiting for it to be finalised.
    /// Returns false if Ootle doesn't accept the burn yet.
    fn claim_burn(&self, claim: MinotariBurnClaimProof, encrypted_data: EncryptedData) -> anyhow::Result<bool> {
        let trial = self.build_claim(claim.clone(), encrypted_data.clone(), 1, true)?;
        let result = self.runtime.block_on(self.transactions.submit_dry_run_transaction(trial))?.finalize;
        if let Some(reason) = result.any_reject() {
            if is_not_yet_claimable(reason) {
                return Ok(false);
            }
            anyhow::bail!("Ootle won't accept the claim: {reason}");
        }

        let transaction = self.build_claim(claim, encrypted_data, result.required_fees(), false)?;
        self.runtime.block_on(async {
            let mut events = self.notify.subscribe();
            let id = self
                .transactions
                .submit_transaction_with_opts(transaction, Some(TransactionContext::with_accounts([self.account])), None)
                .await?;
            let finalised = tokio::time::timeout(FINALISE_TIMEOUT, wait_for_account_update(&mut events, &id, &self.account))
                .await
                .context("the network hasn't confirmed the claim yet")??;
            match finalised.finalize.any_reject() {
                None => Ok(true),
                Some(reason) if is_not_yet_claimable(reason) => Ok(false),
                Some(reason) => anyhow::bail!("The claim was rejected: {reason}"),
            }
        })
    }

    /// Builds and signs a claim transaction: mint the burnt value as a stealth output, then move it
    /// to a fresh output for this account less the fee, which is revealed and paid.
    fn build_claim(
        &self,
        claim: MinotariBurnClaimProof,
        claimed_encrypted_data: EncryptedData,
        max_fee: u64,
        is_dry_run: bool,
    ) -> anyhow::Result<tari_ootle_transaction::Transaction> {
        let network = self.network;
        let sdk = &self.sdk;
        let account = sdk.accounts_api().get_account_by_address(&self.account)?;
        let owner_key_id = account.owner_key_id().context("the account has no owner key")?;
        let owner_key = sdk.key_manager_api().get_key(owner_key_id)?;

        let sender_offset: RistrettoPublicKey = claim
            .output
            .sender_offset_public_key
            .try_from_byte_type()
            .map_err(|e| anyhow::anyhow!("burn sender offset key: {e}"))?;
        // Spend secret s = H(R·p) + p for the burn's one-time claim key S = s·G.
        let stealth_secret = sdk
            .stealth_crypto_api()
            .derive_burn_claim_stealth_secret(owner_key.secret(), &sender_offset);
        let stealth_claim_key = RistrettoPublicKey::from_secret_key(&stealth_secret).to_byte_type();
        anyhow::ensure!(
            stealth_claim_key == claim.output.features.claim_public_key,
            "this burn wasn't made out to this wallet"
        );
        anyhow::ensure!(
            sdk.stealth_crypto_api().validate_burn_claim_ownership_proof(
                network,
                &claim.ownership_proof,
                &claim.commitment,
                claim.value,
                &stealth_claim_key,
            ),
            "the burn's ownership proof doesn't check out"
        );

        let decrypted = sdk.stealth_crypto_api().decrypt_utxo_data(
            &claimed_encrypted_data,
            &claim.commitment,
            owner_key.secret(),
            &sender_offset,
            true,
        )?;
        let final_amount = decrypted
            .value()
            .checked_sub(max_fee)
            .filter(|v| *v > 0)
            .context("the fee is more than the amount burnt")?;

        let mask = sdk.key_manager_api().next_key(KeyBranch::StealthMask)?;
        let (nonce, public_nonce) = RistrettoPublicKey::random_keypair(&mut rand::rng());
        let owner = sdk.key_manager_api().get_public_key(owner_key_id)?;
        let view_only = sdk.key_manager_api().get_public_key(account.view_only_key_id())?;
        let memo = Memo::new_message("Claimed from the base layer").expect("valid memo");
        let encrypted_data = sdk.stealth_crypto_api().encrypt_value_and_mask(
            final_amount,
            &mask.key,
            view_only.public_key(),
            &nonce,
            Some(&memo),
        )?;
        let tag = sdk.stealth_crypto_api().derive_stealth_output_tag(
            network,
            &nonce,
            view_only.public_key(),
            &STEALTH_TARI_RESOURCE_ADDRESS,
        );
        let owner_stealth_key = sdk
            .stealth_crypto_api()
            .derive_stealth_owner_public_key(network, owner.public_key(), &nonce);
        let output = StealthOutputWitness {
            witness: OutputWitness {
                amount: final_amount,
                mask: mask.key,
                sender_public_nonce: public_nonce,
                minimum_value_promise: 0,
                encrypted_data,
                resource_view_key: None,
            },
            auth: SpendAuthorization::Key(owner_stealth_key.to_byte_type()),
            tag,
        };
        let statement = sdk.stealth_crypto_api().generate_transfer_statement(
            iter::once(StealthInputWitness::new(decrypted.into_mask_and_value())),
            Amount::zero(),
            iter::once(&output),
            // The claim key signs this transaction, so it is the badge in scope to take the revealed fee.
            Some(RevealedOutput::new(Amount::from(max_fee), stealth_claim_key)),
        )?;

        let max_epoch = self.runtime.block_on(self.max_epoch())?;
        let transaction = tari_ootle_transaction::Transaction::builder(network.as_byte(), max_epoch)
            .with_fee_instructions_builder(|fee| {
                fee.claim_burn(claim, ClaimBurnOutputData {
                    encrypted_data: claimed_encrypted_data,
                })
                .stealth_transfer(TARI_TOKEN, statement)
                .put_last_instruction_output_on_workspace("fee")
                .pay_fee_from_bucket("fee")
            })
            .with_dry_run(is_dry_run)
            .finish();
        Ok(sdk.signer_api().sign_with_explicit_key(&stealth_secret, transaction)?)
    }
}

/// Ootle rejects a claim it can't verify yet (the burn's L1 block isn't in an epoch it has synced)
/// with this code, as opposed to a claim that is invalid.
fn is_not_yet_claimable(reason: &RejectReason) -> bool {
    reason.execution_failure_code() == Some(ExecutionFailureCode::NotYetValid)
}
