package com.paylane.charge;

/** Charge response body — the resulting transaction. {@code amount} is in minor units. */
public record ChargeResponse(String id, String merchantReference, long amount, String currency,
                             String status) {
}
