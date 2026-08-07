package com.paylane.apikey;

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

/**
 * An API credential for a merchant. Only the hash of the key is ever stored — never the raw key.
 */
@Entity
@Table(name = "api_keys")
@Getter
public class ApiKey {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "merchant_id", nullable = false)
    private UUID merchantId;

    @Column(name = "key_hash", nullable = false)
    private String keyHash;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    protected ApiKey() {
        // for JPA
    }

    public ApiKey(final UUID merchantId, final String keyHash) {
        this.merchantId = merchantId;
        this.keyHash = keyHash;
    }
}
