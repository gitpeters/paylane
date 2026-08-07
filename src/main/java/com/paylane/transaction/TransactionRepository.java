package com.paylane.transaction;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;

public interface TransactionRepository extends JpaRepository<Transaction, UUID> {

    List<Transaction> findByMerchantId(UUID merchantId);

    /**
     * The tenant's recent transactions. This is the query the capacity analysis targets: with only
     * {@code idx_transactions_merchant_id} it fetches every matching row for the merchant, then
     * sorts by {@code created_at} — cheap here, expensive for a high-volume tenant at scale.
     * See analysis/capacity.sql.
     */
    List<Transaction> findTop50ByMerchantIdAndCreatedAtAfterOrderByCreatedAtDesc(
            UUID merchantId, OffsetDateTime createdAt);
}
