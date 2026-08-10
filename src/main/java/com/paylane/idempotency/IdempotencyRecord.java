package com.paylane.idempotency;

import org.jspecify.annotations.Nullable;

/**
 * The stored idempotency row, as needed to branch a duplicate request.
 * {@code responseStatus} and {@code responseBody} are null while IN_FLIGHT.
 */
public record IdempotencyRecord(String fingerprint, String status,
                                @Nullable Integer responseStatus,
                                @Nullable String responseBody) {
}
