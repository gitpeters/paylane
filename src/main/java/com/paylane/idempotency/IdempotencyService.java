package com.paylane.idempotency;

import com.paylane.charge.ChargeRequest;
import com.paylane.common.ApiKeyHasher;
import com.paylane.common.CanonicalJson;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
public class IdempotencyService {

    private final JdbcTemplate db;

    public IdempotencyService(JdbcTemplate db) {
        this.db = db;
    }

    public UUID merchantFor(String apiKey) {
        return db.queryForObject("""
                SELECT merchant_id FROM api_keys WHERE key_hash = ?
                """, UUID.class, ApiKeyHasher.hash(apiKey));
    }

    /** SHA-256 over merchant id + request path + the canonical JSON body. */
    public String fingerprint(UUID merchantId, String path, ChargeRequest req) {
        return ApiKeyHasher.hash(merchantId + path + CanonicalJson.write(req));
    }

    /**
     * Claim the key atomically, in its own committed statement. True if this
     * request owns the key; false means another request got there first.
     */
    public boolean claim(UUID merchantId, String key, String fingerprint) {
        return db.update("""
                INSERT INTO idempotency_keys
                    (merchant_id, idempotency_key, request_fingerprint,
                     status, expires_at)
                VALUES (?, ?, ?, 'IN_FLIGHT', now() + interval '24 hours')
                ON CONFLICT (merchant_id, idempotency_key) DO NOTHING
                """, merchantId, key, fingerprint) == 1;
    }

    public IdempotencyRecord find(UUID merchantId, String key) {
        return db.queryForObject("""
                SELECT request_fingerprint, status, response_status,
                       response_body
                FROM idempotency_keys
                WHERE merchant_id = ? AND idempotency_key = ?
                """, IdempotencyService::map, merchantId, key);
    }

    public void complete(UUID merchantId, String key, int responseStatus,
                         String body) {
        db.update("""
                UPDATE idempotency_keys
                SET status = 'COMPLETED', response_status = ?,
                    response_body = ?::jsonb
                WHERE merchant_id = ? AND idempotency_key = ?
                """, responseStatus, body, merchantId, key);
    }

    public int purgeExpired() {
        return db.update(
                "DELETE FROM idempotency_keys WHERE expires_at < now()");
    }

    private static IdempotencyRecord map(ResultSet rs, int rowNum)
            throws SQLException {
        return new IdempotencyRecord(
                rs.getString("request_fingerprint").trim(),
                rs.getString("status"),
                rs.getObject("response_status", Integer.class),
                rs.getString("response_body"));
    }
}
