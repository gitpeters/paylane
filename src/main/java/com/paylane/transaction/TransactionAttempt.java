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
 * One attempt to charge a transaction through a provider. Retries and provider failover show up
 * here as multiple rows per transaction.
 */
@Entity
@Table(name = "transaction_attempts")
@Getter
public class TransactionAttempt {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "transaction_id", nullable = false)
    private UUID transactionId;

    @Column(nullable = false, length = 64)
    private String provider;

    @Column(nullable = false, length = 32)
    private String status;

    @Column(name = "latency_ms")
    private @Nullable Integer latencyMs;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    protected TransactionAttempt() {
        // for JPA
    }

    public TransactionAttempt(final UUID transactionId, final String provider, final String status,
                              final @Nullable Integer latencyMs) {
        this.transactionId = transactionId;
        this.provider = provider;
        this.status = status;
        this.latencyMs = latencyMs;
    }
}
