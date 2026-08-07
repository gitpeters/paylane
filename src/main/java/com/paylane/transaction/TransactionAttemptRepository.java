package com.paylane.transaction;

import java.util.List;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;

public interface TransactionAttemptRepository extends JpaRepository<TransactionAttempt, Long> {

    /** Scoped by parent transaction — the caller obtains the id via a tenant-scoped query. */
    List<TransactionAttempt> findByTransactionId(UUID transactionId);
}
