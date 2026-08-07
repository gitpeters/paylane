package com.paylane.charge;

/** Charge request body. {@code amount} is in minor units (kobo). */
public record ChargeRequest(String merchantReference, long amount, String currency,
                            String customerEmail) {
}
