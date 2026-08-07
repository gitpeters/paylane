package com.paylane.charge;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/charges")
public class ChargeController {

    private final ChargeService chargeService;

    public ChargeController(ChargeService chargeService) {
        this.chargeService = chargeService;
    }

    @PostMapping
    public ResponseEntity<ChargeResponse> create(
            @RequestHeader("X-API-Key") String apiKey,
            @RequestBody ChargeRequest request) {
        ChargeResponse response = chargeService.charge(apiKey, request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }
}
