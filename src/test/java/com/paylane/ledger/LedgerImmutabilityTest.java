package com.paylane.ledger;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.jdbc.core.JdbcTemplate;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Proves the V3 immutability trigger: a ledger is append-only, so any UPDATE or DELETE on
 * {@code ledger_entries} is refused by the database itself (invariant I4). Real Postgres via
 * Testcontainers — the trigger only exists after Flyway applies V3.
 */
@SpringBootTest
@Testcontainers
class LedgerImmutabilityTest {

    @Container
    @ServiceConnection
    static PostgreSQLContainer postgres = new PostgreSQLContainer("postgres:15-alpine");

    private final JdbcTemplate jdbc;

    @Autowired
    LedgerImmutabilityTest(final JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Test
    void update_onLedgerEntry_isRejectedByImmutabilityTrigger() {
        final Long entryId = insertLedgerEntry();

        assertThatThrownBy(() ->
                jdbc.update("UPDATE ledger_entries SET amount = amount + 1 WHERE id = ?", entryId))
                .hasMessageContaining("append-only");
    }

    @Test
    void delete_onLedgerEntry_isRejectedByImmutabilityTrigger() {
        final Long entryId = insertLedgerEntry();

        assertThatThrownBy(() ->
                jdbc.update("DELETE FROM ledger_entries WHERE id = ?", entryId))
                .hasMessageContaining("append-only");
    }

    /** Its own merchant/account/transaction, then one appended ledger entry. Returns its id. */
    private Long insertLedgerEntry() {
        final UUID merchantId = jdbc.queryForObject(
                "INSERT INTO merchants (name, status) VALUES ('Immutability Test', 'ACTIVE') RETURNING id",
                UUID.class);
        final Long accountId = jdbc.queryForObject("""
                INSERT INTO accounts (merchant_id, account_type, currency, balance)
                VALUES (?, 'MERCHANT_AVAILABLE', 'NGN', 0) RETURNING id
                """, Long.class, merchantId);
        final UUID transactionId = jdbc.queryForObject("""
                INSERT INTO transactions (merchant_id, reference, amount, currency, status, provider)
                VALUES (?, 'txn_immutable', 4500000, 'NGN', 'SUCCESS', 'stub') RETURNING id
                """, UUID.class, merchantId);
        return jdbc.queryForObject("""
                INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, currency)
                VALUES (?, ?, 'CREDIT', 4500000, 'NGN') RETURNING id
                """, Long.class, transactionId, accountId);
    }
}
