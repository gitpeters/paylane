package com.paylane.charge;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/charges")
public class ChargeController {

    private final IdempotentChargeHandler handler;

    public ChargeController(IdempotentChargeHandler handler) {
        this.handler = handler;
    }

    // Idempotency-Key is required; a missing header is a 400 before this.
    @PostMapping
    public ResponseEntity<String> create(
            @RequestHeader("X-API-Key") String apiKey,
            @RequestHeader("Idempotency-Key") String key,
            @RequestBody ChargeRequest req,
            HttpServletRequest http) {
        return handler.handle(apiKey, key, req, http.getRequestURI());
    }
}
