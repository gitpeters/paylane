package com.paylane.provider;

import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

public interface ProviderRouteRepository extends JpaRepository<ProviderRoute, Long> {

    List<ProviderRoute> findByProviderId(Long providerId);

    List<ProviderRoute> findByCurrencyAndEnabledTrueOrderByPriority(String currency);
}
