// Clew's Ootle (Tari L2) wallet functions, in libclew_core.a alongside Tari's wallet.h.
// Errors: error_out is set to non-zero; clew_last_error() describes the last one on this thread.
#pragma once
#include <stdbool.h>
#include <stdint.h>

struct TariWallet;
typedef struct OotleWallet OotleWallet;

char *clew_last_error(void);
void clew_string_destroy(char *value);

bool clew_ootle_set_proxy(const char *proxy, int *error_out);
OotleWallet *clew_ootle_open(struct TariWallet *l1_wallet, const char *directory, const char *network,
                             const char *indexer_url, const char *password, int *error_out);
void clew_ootle_close(OotleWallet *wallet);
char *clew_ootle_address(OotleWallet *wallet, int *error_out);
uint64_t clew_ootle_balance(OotleWallet *wallet, int *error_out);
// Waits for a scan; returns new payments found, or -1 on failure.
int64_t clew_ootle_refresh(OotleWallet *wallet, int *error_out);
// Blocks until finalised; returns the fee paid in µT.
uint64_t clew_ootle_claim_faucet(OotleWallet *wallet, int *error_out);
// Trial runs only, nothing is sent; returns the fee in µT.
uint64_t clew_ootle_estimate_send_fee(OotleWallet *wallet, const char *address, uint64_t amount, int *error_out);
// Private transfer; blocks until finalised; returns the fee charged in µT.
uint64_t clew_ootle_send(OotleWallet *wallet, const char *address, uint64_t amount, uint64_t max_fee,
                         int *error_out);
// One-way: burns XTM on L1 to this Ootle account; refused across networks. Returns the L1 tx id.
uint64_t clew_ootle_burn_from_l1(OotleWallet *wallet, struct TariWallet *l1_wallet, uint64_t amount,
                                 uint64_t fee_per_gram, int *error_out);
// Claims confirmed burns Ootle accepts now; returns how many, or -1. waiting_out may be NULL.
// error_out can be set alongside a count: one burn failed, the others were still tried.
int64_t clew_ootle_claim_burns(OotleWallet *wallet, struct TariWallet *l1_wallet, uint32_t *waiting_out,
                               int *error_out);
// TARI history as JSON, newest first; free with clew_string_destroy.
char *clew_ootle_history(OotleWallet *wallet, uint32_t offset, uint32_t limit, int *error_out);
// This account's burns and their progress as JSON ([{"amount","time","status"}]); local data only.
char *clew_ootle_burns(OotleWallet *wallet, struct TariWallet *l1_wallet, int *error_out);
