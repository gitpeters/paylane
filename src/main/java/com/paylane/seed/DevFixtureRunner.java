package com.paylane.seed;

import com.paylane.common.ApiKeyHasher;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Creates a known dev merchant with a fixed API key and a MERCHANT_AVAILABLE NGN account, so the
 * charge endpoint can be authenticated against. Active under the {@code dev} profile; runs at
 * every boot and gives the dev merchant a clean slate without touching the bulk capacity data.
 *
 * <pre>
 * ./scripts/capacity-run.sh 100000           # reset the bulk data to 100k
 * ./mvnw spring-boot:run -Dspring-boot.run.profiles=dev
 * curl -H "X-API-Key: pk_test_paylane_dev" ... /v1/charges
 * </pre>
 *
 * <p>Ledger entries are immutable since V3 (a trigger blocks UPDATE/DELETE). Wiping the dev
 * merchant therefore runs with {@code session_replication_role='replica'} to bypass that trigger
 * — a dev-only reset, never a production path — and all of it on a SINGLE connection so the SET
 * applies to the deletes that follow. After the wipe the system-account balance caches are
 * recomputed from their remaining entries (0 in the dev database), keeping invariant (c) clean.
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
        final String dev = DEV_MERCHANT_ID.toString();
        final String keyHash = ApiKeyHasher.hash(DEV_RAW_KEY);

        final List<String> statements = new ArrayList<>();
        // Bypass the ledger immutability trigger (and FKs) for the dev-only wipe.
        statements.add("SET session_replication_role = 'replica'");
        statements.add("DELETE FROM ledger_entries WHERE transaction_id IN"
                + " (SELECT id FROM transactions WHERE merchant_id = '" + dev + "')");
        statements.add("DELETE FROM transaction_attempts WHERE transaction_id IN"
                + " (SELECT id FROM transactions WHERE merchant_id = '" + dev + "')");
        statements.add("DELETE FROM transactions WHERE merchant_id = '" + dev + "'");
        statements.add("DELETE FROM accounts WHERE merchant_id = '" + dev + "'");
        statements.add("DELETE FROM api_keys WHERE merchant_id = '" + dev + "'");
        statements.add("DELETE FROM idempotency_keys WHERE merchant_id = '" + dev + "'");
        statements.add("DELETE FROM merchants WHERE id = '" + dev + "'");
        statements.add("SET session_replication_role = 'origin'");

        statements.add("INSERT INTO merchants (id, name, status)"
                + " VALUES ('" + dev + "', 'Dev Merchant', 'ACTIVE')");
        statements.add("INSERT INTO api_keys (merchant_id, key_hash)"
                + " VALUES ('" + dev + "', '" + keyHash + "')");
        statements.add("INSERT INTO accounts (merchant_id, account_type, currency, balance)"
                + " VALUES ('" + dev + "', 'MERCHANT_AVAILABLE', 'NGN', 0)");

        // System-account caches (PROVIDER_SETTLEMENT, FEES_REVENUE) recomputed from their entries.
        statements.add("""
                UPDATE accounts a SET
                    balance = COALESCE((SELECT SUM(CASE WHEN le.direction = 'CREDIT'
                                                        THEN le.amount ELSE -le.amount END)
                                        FROM ledger_entries le WHERE le.account_id = a.id), 0),
                    updated_at = now()
                WHERE a.merchant_id IS NULL""");

        jdbc.execute((ConnectionCallback<Void>) connection -> {
            // One connection so session_replication_role persists across the deletes.
            connection.setAutoCommit(true);
            try (Statement st = connection.createStatement()) {
                for (final String sql : statements) {
                    st.execute(sql);
                }
            }
            return null;
        });

        log.info("Dev fixture ready: merchant={} apiKey={} account=MERCHANT_AVAILABLE/NGN balance=0",
                DEV_MERCHANT_ID, DEV_RAW_KEY);
    }
}
