package com.paylane.provider;

import com.paylane.charge.ChargeRequest;

/** A payment provider. The naive charge path calls this with no timeout and no retry. */
public interface ProviderClient {

    ProviderResult charge(ChargeRequest request);
}
