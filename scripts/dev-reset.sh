#!/usr/bin/env bash
#
# scripts/dev-reset.sh — reset the DB to a 100k baseline for the dev loop, so charges are not
# exercised against the full 4M-row dataset.
#
# The known dev merchant + api key (pk_test_paylane_dev) + NGN account are (re)created by
# DevFixtureRunner when you then boot with the dev profile:
#
#     ./scripts/dev-reset.sh
#     ./mvnw spring-boot:run -Dspring-boot.run.profiles=dev
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/capacity-run.sh" 100000
