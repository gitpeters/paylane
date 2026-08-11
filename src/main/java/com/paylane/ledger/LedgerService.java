package com.paylane.ledger;

import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Writes the ledger for a settled charge as real double-entry: exactly two rows, to two
 * different accounts.
 *
 * <pre>
 *   DEBIT  PROVIDER_SETTLEMENT   amount     (system-owned, merchant_id IS NULL)
 *   CREDIT MERCHANT_AVAILABLE    amount     (the merchant's balance)
 * </pre>
 *
 * <p>The two {@code accounts.balance} caches are updated in the SAME transaction as the entries,
 * so an account's balance always equals the signed sum of its ledger rows (invariant c). The
 * balance is a cache; the entries are the truth. Ledger rows are immutable — enforced by a
 * trigger (see {@code V3__real_double_entry.sql}), so this class only ever inserts.
 */
@Service
public class LedgerService {

    private final JdbcTemplate db;

    public LedgerService(final JdbcTemplate db) {
        this.db = db;
    }

    @Transactional
    public void recordSuccessfulCharge(final UUID merchantId, final UUID transactionId,
                                       final long amount, final String currency) {
        final Long merchantAccountId = db.queryForObject("""
                SELECT id FROM accounts
                WHERE merchant_id = ? AND account_type = 'MERCHANT_AVAILABLE' AND currency = ?
                """, Long.class, merchantId, currency);
        final Long settlementAccountId = db.queryForObject("""
                SELECT id FROM accounts
                WHERE merchant_id IS NULL AND account_type = 'PROVIDER_SETTLEMENT' AND currency = ?
                """, Long.class, currency);

        db.update("""
                INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency)
                VALUES (?, ?, 'DEBIT', ?, ?)
                """, transactionId, settlementAccountId, amount, currency);
        db.update("""
                INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency)
                VALUES (?, ?, 'CREDIT', ?, ?)
                """, transactionId, merchantAccountId, amount, currency);

        // Balance caches: credit the merchant, debit settlement. Same transaction as the entries.
        db.update("UPDATE accounts SET balance = balance + ?, updated_at = now() WHERE id = ?",
                amount, merchantAccountId);
        db.update("UPDATE accounts SET balance = balance - ?, updated_at = now() WHERE id = ?",
                amount, settlementAccountId);
    }
}
