package com.paylane.seed;

import com.paylane.common.ApiKeyHasher;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Creates a known dev merchant with a fixed API key and an NGN account, so the charge endpoint
 * can be authenticated against. Active under the {@code dev} profile; runs at every boot and
 * gives the dev merchant a clean slate without touching the bulk capacity data.
 *
 * <pre>
 * ./scripts/capacity-run.sh 100000           # reset the bulk data to 100k
 * ./mvnw spring-boot:run -Dspring-boot.run.profiles=dev
 * curl -H "X-API-Key: pk_test_paylane_dev" ... /v1/charges
 * </pre>
 *
 * <p>Unlike {@link SeedRunner}, this does not shut the app down — it leaves it serving requests.
 */
@Component
@Profile("dev")
public class DevFixtureRunner implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(DevFixtureRunner.class);

    private static final UUID DEV_MERCHANT_ID =
            UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final String DEV_RAW_KEY = "pk_test_paylane_dev";

    private final JdbcTemplate jdbc;

    public DevFixtureRunner(final JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public void run(final String... args) {
        // Clean slate for the dev merchant only. Order respects the foreign keys.
        jdbc.update("DELETE FROM ledger_entries WHERE transaction_id IN"
                + " (SELECT id FROM transactions WHERE merchant_id = ?)", DEV_MERCHANT_ID);
        jdbc.update("DELETE FROM transaction_attempts WHERE transaction_id IN"
                + " (SELECT id FROM transactions WHERE merchant_id = ?)", DEV_MERCHANT_ID);
        jdbc.update("DELETE FROM transactions WHERE merchant_id = ?", DEV_MERCHANT_ID);
        jdbc.update("DELETE FROM accounts WHERE merchant_id = ?", DEV_MERCHANT_ID);
        jdbc.update("DELETE FROM api_keys WHERE merchant_id = ?", DEV_MERCHANT_ID);
        jdbc.update("DELETE FROM idempotency_keys WHERE merchant_id = ?",
                DEV_MERCHANT_ID);
        jdbc.update("DELETE FROM merchants WHERE id = ?", DEV_MERCHANT_ID);

        jdbc.update("INSERT INTO merchants (id, name, status)"
                + " VALUES (?, 'Dev Merchant', 'ACTIVE')", DEV_MERCHANT_ID);
        jdbc.update("INSERT INTO api_keys (merchant_id, key_hash) VALUES (?, ?)",
                DEV_MERCHANT_ID, ApiKeyHasher.hash(DEV_RAW_KEY));
        jdbc.update("INSERT INTO accounts (merchant_id, currency, balance)"
                + " VALUES (?, 'NGN', 0)", DEV_MERCHANT_ID);

        log.info("Dev fixture ready: merchant={} apiKey={} account=NGN balance=0",
                DEV_MERCHANT_ID, DEV_RAW_KEY);
    }
}
