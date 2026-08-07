package com.paylane.charge;

import com.paylane.common.ApiKeyHasher;
import com.paylane.provider.ProviderClient;
import com.paylane.provider.ProviderResult;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
public class ChargeService {

    private final JdbcTemplate db;
    private final ProviderClient provider;

    public ChargeService(JdbcTemplate db, ProviderClient provider) {
        this.db = db;
        this.provider = provider;
    }

    public ChargeResponse charge(String apiKey, ChargeRequest req) {
        UUID merchantId = db.queryForObject("""
                SELECT merchant_id FROM api_keys WHERE key_hash = ?
                """, UUID.class, ApiKeyHasher.hash(apiKey));
        UUID txId = db.queryForObject("""
                INSERT INTO transactions
                    (merchant_id, reference, amount, currency, status, provider)
                VALUES (?, ?, ?, ?, 'PENDING', 'stub')
                RETURNING id
                """, UUID.class, merchantId, req.merchantReference(),
                req.amount(), req.currency());
        ProviderResult result = provider.charge(req);
        db.update("""
                INSERT INTO transaction_attempts
                    (transaction_id, provider, status, latency_ms)
                VALUES (?, 'stub', ?, ?)
                """, txId, result.status(), result.latencyMs());
        if (result.status().equals("SUCCESS")) {
            creditMerchant(merchantId, txId, req);
        }
        db.update("""
                UPDATE transactions SET status = ? WHERE id = ?
                """, result.status(), txId);
        return new ChargeResponse(txId.toString(), req.merchantReference(),
                req.amount(), req.currency(), result.status());
    }

    private void creditMerchant(UUID merchantId, UUID txId, ChargeRequest req) {
        db.update("""
                INSERT INTO ledger_entries
                    (transaction_id, account_id, direction, amount, currency)
                SELECT ?, a.id, d.direction, ?, ?
                FROM accounts a
                CROSS JOIN (VALUES ('DEBIT'), ('CREDIT')) AS d(direction)
                WHERE a.merchant_id = ? AND a.currency = ?
                """, txId, req.amount(), req.currency(), merchantId,
                req.currency());
        db.update("""
                UPDATE accounts SET balance = balance + ?
                WHERE merchant_id = ? AND currency = ?
                """, req.amount(), merchantId, req.currency());
    }
}
