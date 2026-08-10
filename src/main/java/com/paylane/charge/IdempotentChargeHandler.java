package com.paylane.charge;

import static org.springframework.http.MediaType.APPLICATION_JSON;

import com.paylane.common.CanonicalJson;
import com.paylane.idempotency.IdempotencyRecord;
import com.paylane.idempotency.IdempotencyService;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;

/**
 * Wraps the charge flow with idempotency: claim the key in its own committed
 * statement, then branch on the outcome. Claiming BEFORE the provider call is
 * what makes an in-flight duplicate get a 409 instead of a second charge.
 */
@Component
public class IdempotentChargeHandler {

    private final ChargeService chargeService;
    private final IdempotencyService idempotency;

    public IdempotentChargeHandler(ChargeService chargeService,
                                   IdempotencyService idempotency) {
        this.chargeService = chargeService;
        this.idempotency = idempotency;
    }

    public ResponseEntity<String> handle(String apiKey, String key,
                                         ChargeRequest req, String path) {
        UUID merchantId = idempotency.merchantFor(apiKey);
        String fingerprint = idempotency.fingerprint(merchantId, path, req);
        if (idempotency.claim(merchantId, key, fingerprint)) {
            ChargeResponse charged = chargeService.charge(apiKey, req);
            String body = CanonicalJson.write(charged);
            idempotency.complete(merchantId, key, 201, body);
            return json(201, body);
        }
        IdempotencyRecord prior = idempotency.find(merchantId, key);
        if (!prior.fingerprint().equals(fingerprint)) {
            return problem(422,
                    "Idempotency-Key reused with a different request payload");
        }
        if (prior.status().equals("IN_FLIGHT")) {
            return ResponseEntity.status(409).header("Retry-After", "5")
                    .contentType(APPLICATION_JSON)
                    .body(problemBody("Original request is still in flight"));
        }
        return ResponseEntity.status(prior.responseStatus())
                .header("Idempotency-Replayed", "true")
                .contentType(APPLICATION_JSON).body(prior.responseBody());
    }

    private static ResponseEntity<String> json(int status, String body) {
        return ResponseEntity.status(status)
                .contentType(APPLICATION_JSON).body(body);
    }

    private static ResponseEntity<String> problem(int status, String message) {
        return json(status, problemBody(message));
    }

    private static String problemBody(String message) {
        return CanonicalJson.write(Map.of("error", message));
    }
}
