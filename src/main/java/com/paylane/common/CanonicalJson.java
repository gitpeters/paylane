package com.paylane.common;

import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.json.JsonMapper;

/**
 * Canonical JSON: object properties sorted alphabetically, no whitespace. The
 * same logical payload always serialises to the same bytes, which is what makes
 * a request fingerprint stable.
 */
public final class CanonicalJson {

    private static final JsonMapper MAPPER = JsonMapper.builder()
            .enable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY)
            .build();

    private CanonicalJson() {
    }

    public static String write(final Object value) {
        return MAPPER.writeValueAsString(value);
    }
}
