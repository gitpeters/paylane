package com.paylane.idempotency;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Deletes expired idempotency keys on a timer. Single instance only for now —
 * running this on exactly one node in a cluster (a scheduling lock) is a later
 * topic, so there is no lock here.
 */
@Component
public class IdempotencyCleanupJob {

    private static final Logger log =
            LoggerFactory.getLogger(IdempotencyCleanupJob.class);

    private final IdempotencyService idempotency;

    public IdempotencyCleanupJob(IdempotencyService idempotency) {
        this.idempotency = idempotency;
    }

    @Scheduled(fixedDelayString =
            "${paylane.idempotency.cleanup-interval-ms:3600000}")
    public void purgeExpired() {
        int deleted = idempotency.purgeExpired();
        if (deleted > 0) {
            log.info("Purged {} expired idempotency keys", deleted);
        }
    }
}
