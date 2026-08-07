package com.paylane.seed;

import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Generates a realistically large, skewed, complete dataset for capacity work. Active only under
 * the {@code seed} profile:
 *
 * <pre>./mvnw spring-boot:run -Dspring-boot.run.profiles=seed</pre>
 *
 * <p>This is the same seed as {@code scripts/capacity-run.sh}, kept in sync so either path
 * produces an identical dataset. The whole thing runs on a <em>single JDBC connection</em> so
 * {@code setseed(0.42)} persists across every statement — without that, each JdbcTemplate call
 * could take a different pooled connection and the seed would not be reproducible.
 *
 * <ul>
 *   <li>Whale merchant {@value #WHALE_ID} is pinned and holds ~40% of transactions. Its id is a
 *       literal because {@code gen_random_uuid()} ignores {@code setseed()}.</li>
 *   <li>Status is ~90% SUCCESS / ~7% FAILED / ~3% PENDING, in one {@code random()} draw.</li>
 *   <li>Every transaction gets 1..2 attempts (~15% retry after a failed first try).</li>
 *   <li>Every SUCCESS transaction gets a balanced DEBIT/CREDIT ledger pair.</li>
 * </ul>
 *
 * <p>Parallel workers are disabled for the session — for stable {@code random()} ordering and to
 * avoid parallel-worker DSM segments overflowing a container's small default {@code /dev/shm}.
 * The runner shuts the app down when done.
 */
@Component
@Profile("seed")
public class SeedRunner implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(SeedRunner.class);

    /** Pinned whale merchant id — stable across runs. See class javadoc. */
    private static final String WHALE_ID = "96444bf1-5cb9-4cf4-8efd-00cc01aafa9c";

    /** Transactions spread uniformly across this window, ending now. ~14 months. */
    private static final String SPREAD = "425 days";

    private static final String[] SEEDED_TABLES = {
            "merchants", "api_keys", "accounts", "transactions",
            "transaction_attempts", "ledger_entries", "providers", "provider_routes"};

    private static final String ATTEMPTS_SQL = """
            INSERT INTO transaction_attempts (transaction_id, provider, status, latency_ms, created_at)
            SELECT t.id,
                   t.provider,
                   CASE WHEN a.attempt_no = 1 AND (t.h % 100) < 15 THEN 'FAILED' ELSE t.status END,
                   CASE WHEN a.attempt_no = 1 AND (t.h % 100) < 15 THEN (2000 + floor(random() * 4000))::int
                        ELSE (50 + floor(random() * 450))::int END,
                   t.created_at + (a.attempt_no - 1) * interval '3 seconds'
            FROM (SELECT id, provider, status, created_at,
                         (hashtext(id::text) & 2147483647) AS h FROM transactions) t
            CROSS JOIN LATERAL (
                SELECT gs AS attempt_no
                FROM generate_series(1, CASE WHEN (t.h % 100) < 15 THEN 2 ELSE 1 END) AS gs
            ) a
            """;

    private static final String LEDGER_SQL = """
            INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency, created_at)
            SELECT t.id, acc.id, d.direction, t.amount, t.currency, t.created_at
            FROM transactions t
            JOIN accounts acc ON acc.merchant_id = t.merchant_id AND acc.currency = t.currency
            CROSS JOIN (VALUES ('DEBIT'), ('CREDIT')) AS d(direction)
            WHERE t.status = 'SUCCESS'
            """;

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
        final int merchants = props.merchantCount();
        final long count = props.transactionCount();
        final String currency = props.currency();
        if (!currency.matches("[A-Z]{3}")) {
            throw new IllegalArgumentException("currency must be a 3-letter ISO code: " + currency);
        }
        log.info("Seeding: merchants={} transactions={} whaleShare={} currency={} (single connection, setseed)",
                merchants, count, props.whaleShare(), currency);

        final long startNanos = System.nanoTime();
        final List<String> statements = seedStatements(count, merchants, currency);
        jdbc.execute((ConnectionCallback<Void>) connection -> {
            // One connection so setseed() persists across every statement; autocommit so VACUUM runs.
            connection.setAutoCommit(true);
            try (Statement st = connection.createStatement()) {
                for (final String sql : statements) {
                    st.execute(sql);
                }
            }
            return null;
        });
        final long ms = (System.nanoTime() - startNanos) / 1_000_000;
        log.info("Seeded {} transactions (+ attempts + ledger) in {} ms", count, ms);

        logCounts();
        log.info("Seed complete. Shutting down.");
        System.exit(SpringApplication.exit(context, () -> 0));
    }

    private List<String> seedStatements(final long count, final int merchants, final String currency) {
        final int others = merchants - 1;
        final String whaleShare = String.valueOf(props.whaleShare());
        final List<String> sql = new ArrayList<>();

        sql.add("""
                TRUNCATE merchants, api_keys, accounts, transactions, transaction_attempts, ledger_entries
                RESTART IDENTITY CASCADE""");

        // Disable all parallel workers: stable random() ordering + no DSM /dev/shm overflow.
        sql.add("SET max_parallel_workers_per_gather = 0");
        sql.add("SET max_parallel_maintenance_workers = 0");
        sql.add("SET max_parallel_workers = 0");
        sql.add("SELECT setseed(0.42)");

        // Reference data is not truncated; insert only if empty.
        sql.add("""
                INSERT INTO providers (name, enabled)
                SELECT v.name, true FROM (VALUES ('paystack'), ('stripe'), ('monnify')) AS v(name)
                WHERE NOT EXISTS (SELECT 1 FROM providers)""");
        sql.add("""
                INSERT INTO provider_routes (provider_id, currency, priority, enabled)
                SELECT id, '%s', row_number() OVER (ORDER BY id), true FROM providers
                WHERE NOT EXISTS (SELECT 1 FROM provider_routes)""".formatted(currency));

        // Whale merchant with the pinned id, then the rest.
        sql.add("""
                INSERT INTO merchants (id, name, status, created_at)
                VALUES ('%s', 'Merchant 1 (whale)', 'ACTIVE', now() - (random() * interval '%s'))"""
                .formatted(WHALE_ID, SPREAD));
        sql.add("""
                INSERT INTO merchants (id, name, status, created_at)
                SELECT gen_random_uuid(), 'Merchant ' || (g + 1), 'ACTIVE',
                       now() - (random() * interval '%s')
                FROM generate_series(1, %d) AS g""".formatted(SPREAD, others));

        sql.add("""
                INSERT INTO api_keys (merchant_id, key_hash, created_at)
                SELECT id, md5(random()::text || id::text), now() FROM merchants""");
        sql.add("""
                INSERT INTO accounts (merchant_id, currency, balance, created_at, updated_at)
                SELECT id, '%s', 0, now(), now() FROM merchants""".formatted(currency));

        sql.add(transactionsSql(count, others, currency, whaleShare));
        sql.add(ATTEMPTS_SQL);
        sql.add(LEDGER_SQL);

        for (final String table : SEEDED_TABLES) {
            sql.add("VACUUM ANALYZE " + table);
        }
        return sql;
    }

    private String transactionsSql(final long count, final int others, final String currency,
                                   final String whaleShare) {
        // Whale is ids[1] (pinned, forced first); the rest decay via power(random(),2). One
        // random() draw per column so the merchant-assignment draws stay unperturbed.
        return """
                WITH m AS (
                    SELECT array_agg(id ORDER BY (id = '%s'::uuid) DESC, created_at, id) AS ids
                    FROM merchants
                )
                INSERT INTO transactions
                    (id, merchant_id, reference, amount, currency, status, provider, created_at)
                SELECT gen_random_uuid(),
                       m.ids[CASE WHEN random() < %s THEN 1
                                  ELSE 2 + floor(power(random(), 2) * %d)::int END],
                       'txn_' || g,
                       (10000 + floor(random() * 49990000))::bigint,
                       '%s',
                       (ARRAY['SUCCESS','FAILED','PENDING'])[width_bucket(random(), ARRAY[0.90, 0.97]) + 1],
                       (ARRAY['paystack','stripe','monnify'])[1 + floor(random() * 3)::int],
                       now() - (random() * interval '%s')
                FROM generate_series(1, %d) AS g CROSS JOIN m
                """.formatted(WHALE_ID, whaleShare, others, currency, SPREAD, count);
    }

    private void logCounts() {
        for (final String table : SEEDED_TABLES) {
            final Long count = jdbc.queryForObject("SELECT count(*) FROM " + table, Long.class);
            log.info("  {} = {} rows", table, count);
        }
    }
}
