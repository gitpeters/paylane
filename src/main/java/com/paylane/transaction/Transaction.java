package com.paylane.transaction;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import java.util.UUID;
import lombok.Getter;
import org.hibernate.annotations.CreationTimestamp;
import org.jspecify.annotations.Nullable;

/**
 * A payment a merchant is trying to collect.
 *
 * <p>NAIVE BASELINE: this is a plain, non-partitioned table. {@code reference} is not unique, and
 * the only index is on {@code merchant_id}. Both are deliberate before-states for later topics
 * (idempotency, partitioning, composite indexing).
 */
@Entity
@Table(name = "transactions")
@Getter
public class Transaction {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "merchant_id", nullable = false)
    private UUID merchantId;

    @Column(nullable = false)
    private String reference;

    /** Minor units (kobo/cents). Never a decimal. */
    @Column(nullable = false)
    private long amount;

    @Column(nullable = false, length = 3)
    private String currency;

    @Column(nullable = false, length = 32)
    private String status;

    @Column(length = 64)
    private @Nullable String provider;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    protected Transaction() {
        // for JPA
    }

    public Transaction(final UUID merchantId, final String reference, final long amount,
                       final String currency, final String status, final @Nullable String provider) {
        this.merchantId = merchantId;
        this.reference = reference;
        this.amount = amount;
        this.currency = currency;
        this.status = status;
        this.provider = provider;
    }
}
