package com.paylane.provider;

/** Outcome of a provider charge call. {@code status} is SUCCESS or FAILED. */
public record ProviderResult(String status, int latencyMs) {
}
