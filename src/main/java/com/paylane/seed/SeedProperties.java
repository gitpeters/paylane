package com.paylane.seed;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * Tuning for the {@code seed} profile data generator. Bound from {@code paylane.seed.*}.
 *
 * @param transactionCount total transactions to generate (default 4,000,000)
 * @param merchantCount    number of merchants (default 500)
 * @param whaleShare       fraction of transactions owned by a single "whale" merchant (0..1)
 * @param currency         ISO currency code used for all generated money
 */
@ConfigurationProperties(prefix = "paylane.seed")
public record SeedProperties(
        @DefaultValue("4000000") long transactionCount,
        @DefaultValue("500") int merchantCount,
        @DefaultValue("0.40") double whaleShare,
        @DefaultValue("NGN") String currency) {
}
