package com.paylane.provider;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * Stub provider tuning, bound from {@code paylane.provider.stub.*}.
 *
 * @param delayMs      how long the provider call is held open (set to 30000 to reproduce a
 *                     client timeout against a call that still succeeds)
 * @param failureRate  fraction of calls that return FAILED (0.0 = always succeeds)
 */
@ConfigurationProperties(prefix = "paylane.provider.stub")
public record ProviderStubProperties(@DefaultValue("0") long delayMs,
                                     @DefaultValue("0.0") double failureRate) {
}
