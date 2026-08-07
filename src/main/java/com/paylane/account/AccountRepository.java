package com.paylane.account;

import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;

public interface AccountRepository extends JpaRepository<Account, Long> {

    List<Account> findByMerchantId(UUID merchantId);

    Optional<Account> findByMerchantIdAndCurrency(UUID merchantId, String currency);
}
