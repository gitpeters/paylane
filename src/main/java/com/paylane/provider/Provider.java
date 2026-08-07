package com.paylane.provider;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;

/**
 * A payment provider we can route charges through (Paystack, Stripe, Monnify). Global config,
 * not tenant data.
 */
@Entity
@Table(name = "providers")
@Getter
public class Provider {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 64)
    private String name;

    @Column(nullable = false)
    private boolean enabled;

    protected Provider() {
        // for JPA
    }

    public Provider(final String name, final boolean enabled) {
        this.name = name;
        this.enabled = enabled;
    }
}
