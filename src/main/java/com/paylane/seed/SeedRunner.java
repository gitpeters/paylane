package com.paylane.seed;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Generates a realistically large, skewed dataset for capacity work. Active only under the
 * {@code seed} profile:
 *
 * <pre>./mvnw spring-boot:run -Dspring-boot.run.profiles=seed</pre>
 *
 * <p>All inserts are set-based ({@code generate_series}) so millions of rows load in one
 * statement per table. The transactions are skewed: one "whale" merchant owns ~{@code whaleShare}
 * of them, the rest follow a decaying distribution — the shape real payment traffic has, and the
 * shape the capacity analysis needs to be interesting. The runner shuts the app down when done.
 */
@Component
@Profile("seed")
public class SeedRunner implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(SeedRunner.class);

    /** Transactions spread uniformly across this window, ending now. ~14 months. */
    private static final String SPREAD = "425 days";

    private final JdbcTemplate jdbc;
    private final SeedProperties props;
    private final ConfigurableApplicationContext context;

    public SeedRunner(final JdbcTemplate jdbc, final SeedProperties props,
                      final ConfigurableApplicationContext context) {
        this.jdbc = jdbc;
        this.props = props;
        this.context = context;
    }

    @Override
    public void run(final String... args) {
        log.info("Seeding: merchants={} transactions={} whaleShare={} currency={}",
                props.merchantCount(), props.transactionCount(), props.whaleShare(), props.currency());

        truncateAll();
        seedProviders();
        seedMerchants(props.merchantCount());
        seedTransactions(props.transactionCount(), props.merchantCount());
        logCounts();

        log.info("Seed complete. Shutting down.");
        System.exit(SpringApplication.exit(context, () -> 0));
    }

    private void truncateAll() {
        jdbc.execute("""
                TRUNCATE transactions, transaction_attempts, ledger_entries, accounts,
                         api_keys, provider_routes, providers, merchants
                RESTART IDENTITY CASCADE
                """);
    }

    private void seedProviders() {
        jdbc.update("INSERT INTO providers (name, enabled) VALUES "
                + "('paystack', true), ('stripe', true), ('monnify', true)");
        jdbc.update("""
                INSERT INTO provider_routes (provider_id, currency, priority, enabled)
                SELECT id, ?, row_number() OVER (ORDER BY id), true FROM providers
                """, props.currency());
    }

    private void seedMerchants(final int merchants) {
        jdbc.update("""
                INSERT INTO merchants (id, name, status, created_at)
                SELECT gen_random_uuid(), 'Merchant ' || g, 'ACTIVE',
                       now() - (random() * interval '%s')
                FROM generate_series(1, ?) AS g
                """.formatted(SPREAD), merchants);
        jdbc.update("""
                INSERT INTO api_keys (merchant_id, key_hash, created_at)
                SELECT id, md5(random()::text || id::text), now() FROM merchants
                """);
        jdbc.update("""
                INSERT INTO accounts (merchant_id, currency, balance, created_at, updated_at)
                SELECT id, ?, 0, now(), now() FROM merchants
                """, props.currency());
    }

    private void seedTransactions(final long count, final int merchants) {
        // Bulk-load pattern: drop the index, load, rebuild it, then refresh planner stats.
        log.info("Dropping idx_transactions_merchant_id for bulk load");
        jdbc.execute("DROP INDEX IF EXISTS idx_transactions_merchant_id");

        // Merchant assignment is an array subscript, not a join: `ids` holds the merchant ids
        // ordered by (created_at, id), so ids[1] is the earliest merchant — the whale, and the
        // one capacity.sql targets. The subscript is computed per row in the SELECT list, where
        // random() is evaluated once per generated row. (A LATERAL subquery here gets collapsed
        // to a single evaluation by the planner, sending every row to one merchant.)
        final long startNanos = System.nanoTime();
        final int inserted = jdbc.update("""
                WITH m AS (
                    SELECT array_agg(id ORDER BY created_at, id) AS ids FROM merchants
                )
                INSERT INTO transactions
                    (id, merchant_id, reference, amount, currency, status, provider, created_at)
                SELECT gen_random_uuid(),
                       m.ids[CASE WHEN random() < ? THEN 1
                                  ELSE 2 + floor(power(random(), 2) * ?)::int END],
                       'txn_' || g,
                       (10000 + floor(random() * 49990000))::bigint,
                       ?,
                       (ARRAY['SUCCESS','SUCCESS','SUCCESS','FAILED','PENDING'])[1 + floor(random() * 5)::int],
                       (ARRAY['paystack','stripe','monnify'])[1 + floor(random() * 3)::int],
                       now() - (random() * interval '%s')
                FROM generate_series(1, ?) AS g CROSS JOIN m
                """.formatted(SPREAD), props.whaleShare(), merchants - 1, props.currency(), count);
        final long ms = (System.nanoTime() - startNanos) / 1_000_000;
        log.info("Inserted {} transactions in {} ms", inserted, ms);

        log.info("Rebuilding idx_transactions_merchant_id and analyzing");
        jdbc.execute("CREATE INDEX idx_transactions_merchant_id ON transactions (merchant_id)");
        jdbc.execute("ANALYZE transactions");
    }

    private void logCounts() {
        final String[] tables = {"merchants", "api_keys", "accounts", "transactions",
                "providers", "provider_routes"};
        for (final String table : tables) {
            final Long count = jdbc.queryForObject("SELECT count(*) FROM " + table, Long.class);
            log.info("  {} = {} rows", table, count);
        }
    }
}
