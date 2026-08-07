package com.paylane.provider;

import com.paylane.charge.ChargeRequest;
import java.util.concurrent.ThreadLocalRandom;
import org.springframework.stereotype.Component;

/**
 * In-process provider stub. Holds the call open for {@code delayMs} then approves or declines by
 * {@code failureRate}. There is no timeout here by design — a slow provider blocks the request
 * thread, which is exactly what makes the caller time out and retry.
 */
@Component
public class ProviderStub implements ProviderClient {

    private final ProviderStubProperties properties;

    public ProviderStub(final ProviderStubProperties properties) {
        this.properties = properties;
    }

    @Override
    public ProviderResult charge(final ChargeRequest request) {
        final long delayMs = properties.delayMs();
        sleepQuietly(delayMs);
        String status = "SUCCESS";
        if (ThreadLocalRandom.current().nextDouble() < properties.failureRate()) {
            status = "FAILED";
        }
        return new ProviderResult(status, (int) delayMs);
    }

    private void sleepQuietly(final long ms) {
        try {
            Thread.sleep(ms);
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
