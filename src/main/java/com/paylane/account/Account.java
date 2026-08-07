package com.paylane.account;

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
import org.hibernate.annotations.UpdateTimestamp;

/**
 * A merchant's balance in one currency.
 *
 * <p>NAIVE BASELINE: {@code balance} is a mutable minor-units column treated as the source of
 * truth. A future topic makes the ledger the truth and turns this into a derived cache — until
 * then this column is written directly. Do not add a version/optimistic-lock column here.
 */
@Entity
@Table(name = "accounts")
@Getter
public class Account {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "merchant_id", nullable = false)
    private UUID merchantId;

    @Column(nullable = false, length = 3)
    private String currency;

    @Column(nullable = false)
    private long balance;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    @UpdateTimestamp
    @Column(name = "updated_at", nullable = false)
    private OffsetDateTime updatedAt;

    protected Account() {
        // for JPA
    }

    public Account(final UUID merchantId, final String currency, final long balance) {
        this.merchantId = merchantId;
        this.currency = currency;
        this.balance = balance;
    }
}
