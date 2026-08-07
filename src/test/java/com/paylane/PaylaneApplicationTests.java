package com.paylane;

import static org.assertj.core.api.Assertions.assertThat;

import com.paylane.account.Account;
import com.paylane.account.AccountRepository;
import com.paylane.merchant.Merchant;
import com.paylane.merchant.MerchantRepository;
import com.paylane.transaction.Transaction;
import com.paylane.transaction.TransactionRepository;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Foundation integration test. Real Postgres via Testcontainers (no H2 — see docs/testing.md);
 * {@code @ServiceConnection} points the datasource at the container, so Flyway applies V1 and
 * Hibernate runs its {@code validate} check against the same schema the migration produced.
 */
@SpringBootTest
@Testcontainers
class PaylaneApplicationTests {

    @Container
    @ServiceConnection
    static PostgreSQLContainer postgres = new PostgreSQLContainer("postgres:15-alpine");

    private final MerchantRepository merchants;
    private final AccountRepository accounts;
    private final TransactionRepository transactions;

    @Autowired
    PaylaneApplicationTests(final MerchantRepository merchants, final AccountRepository accounts,
                            final TransactionRepository transactions) {
        this.merchants = merchants;
        this.accounts = accounts;
        this.transactions = transactions;
    }

    @Test
    void contextLoads_flywayMigratesAndHibernateValidates() {
        // Reaching a working query proves the container started, Flyway applied V1, and every
        // entity passed ddl-auto=validate against it.
        assertThat(transactions.count()).isGreaterThanOrEqualTo(0);
    }

    @Test
    void transactionRepository_findByMerchantId_returnsOnlyThatTenantsRows() {
        final Merchant a = merchants.save(new Merchant("Merchant A", "ACTIVE"));
        final Merchant b = merchants.save(new Merchant("Merchant B", "ACTIVE"));
        accounts.save(new Account(a.getId(), "NGN", 0));

        transactions.save(new Transaction(a.getId(), "txn_a1", 4_500_000L, "NGN", "SUCCESS", "paystack"));
        transactions.save(new Transaction(b.getId(), "txn_b1", 9_900_000L, "NGN", "SUCCESS", "stripe"));

        final List<Transaction> forA = transactions.findByMerchantId(a.getId());

        assertThat(forA).hasSize(1);
        assertThat(forA.get(0).getMerchantId()).isEqualTo(a.getId());
        assertThat(forA.get(0).getAmount()).isEqualTo(4_500_000L);

        final Optional<Account> accountA = accounts.findByMerchantIdAndCurrency(a.getId(), "NGN");
        assertThat(accountA).isPresent();
        assertThat(accountA.get().getBalance()).isZero();
    }
}
