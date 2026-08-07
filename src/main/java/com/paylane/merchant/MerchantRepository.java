package com.paylane.merchant;

import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;

/**
 * The merchant is the tenant root, so lookups are by primary key. Listing all merchants is an
 * admin operation; per-tenant data lives behind the repositories in the other feature packages.
 */
public interface MerchantRepository extends JpaRepository<Merchant, UUID> {
}
