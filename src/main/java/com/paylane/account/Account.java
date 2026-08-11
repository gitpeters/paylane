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
 * An account in one currency. {@code account_type} distinguishes a merchant's balance
 * ({@code MERCHANT_AVAILABLE}) from the system-owned accounts a charge posts against
 * ({@code PROVIDER_SETTLEMENT}, {@code FEES_REVENUE}), which have no {@code merchant_id}.
 *
 * <p>Since topic 04, {@code balance} is a <em>cache</em> of the ledger — the signed sum of this
 * account's entries — written in the same transaction as those entries, not the source of truth.
 * See the column comment in {@code V3__real_double_entry.sql}.
 */
@Entity
@Table(name = "accounts")
@Getter
public class Account {

    public static final String MERCHANT_AVAILABLE = "MERCHANT_AVAILABLE";
    public static final String PROVIDER_SETTLEMENT = "PROVIDER_SETTLEMENT";
    public static final String FEES_REVENUE = "FEES_REVENUE";

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    /** Null for system-owned accounts (PROVIDER_SETTLEMENT, FEES_REVENUE). */
    @Column(name = "merchant_id")
    private UUID merchantId;

    @Column(name = "account_type", nullable = false, length = 32)
    private String accountType;

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

    /** A merchant's available-balance account. */
    public Account(final UUID merchantId, final String currency, final long balance) {
        this(merchantId, MERCHANT_AVAILABLE, currency, balance);
    }

    public Account(final UUID merchantId, final String accountType, final String currency,
                   final long balance) {
        this.merchantId = merchantId;
        this.accountType = accountType;
        this.currency = currency;
        this.balance = balance;
    }
}
