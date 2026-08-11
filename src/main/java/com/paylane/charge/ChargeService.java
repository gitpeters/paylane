package com.paylane.charge;

import com.paylane.common.ApiKeyHasher;
import com.paylane.ledger.LedgerService;
import com.paylane.provider.ProviderClient;
import com.paylane.provider.ProviderResult;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
public class ChargeService {

    private final JdbcTemplate db;
    private final ProviderClient provider;
    private final LedgerService ledger;

    public ChargeService(JdbcTemplate db, ProviderClient provider, LedgerService ledger) {
        this.db = db;
        this.provider = provider;
        this.ledger = ledger;
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
            // Real double-entry: DEBIT PROVIDER_SETTLEMENT, CREDIT MERCHANT_AVAILABLE, both
            // balance caches updated atomically. See LedgerService.
            ledger.recordSuccessfulCharge(merchantId, txId, req.amount(), req.currency());
        }
        db.update("""
                UPDATE transactions SET status = ? WHERE id = ?
                """, result.status(), txId);
        return new ChargeResponse(txId.toString(), req.merchantReference(),
                req.amount(), req.currency(), result.status());
    }
}
