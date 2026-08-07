package com.paylane.provider;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;

/**
 * Routing config: which provider handles a currency, and in what priority order. Global config.
 */
@Entity
@Table(name = "provider_routes")
@Getter
public class ProviderRoute {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "provider_id", nullable = false)
    private Long providerId;

    @Column(nullable = false, length = 3)
    private String currency;

    @Column(nullable = false)
    private int priority;

    @Column(nullable = false)
    private boolean enabled;

    protected ProviderRoute() {
        // for JPA
    }

    public ProviderRoute(final Long providerId, final String currency, final int priority,
                         final boolean enabled) {
        this.providerId = providerId;
        this.currency = currency;
        this.priority = priority;
        this.enabled = enabled;
    }
}
