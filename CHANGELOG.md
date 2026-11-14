# Changelog

## 0.4.2

- Added admin-only personnel deactivation and reactivation.
- Refused deactivation for personnel who are inside, have an active loan, have a
  pending transaction, or are referenced by an active loan record.
- Preserved personnel PINs, readings, loan records, and audit history while
  deactivated.
- Blocked new check-ins for deactivated personnel.
- Changed the GitHub updater to resolve `main` to an immutable commit before
  downloading the release manifest, avoiding stale cached manifests.

## 0.4.1

- Protected personnel registration with the administrator PIN.
- Added a required 4-12 digit PIN for each registered person at check-in and
  check-out.
- Added an administrator workflow to assign or reset a personnel PIN.
- Preserved older personnel records while requiring an administrator to assign
  their first PIN after upgrading.
- Kept PIN values out of the persistent event log and state database.

## 0.4.0

- Added read-only RACS/1 wireless protocol and dashboard client.
- Added startup recovery using recorded stock counts and public-chest evidence.
- Added administrative lockdown and persistent alerts.
- Added persistent personnel, quantity-based equipment loans, accountability,
  and free-form self-reported radiation readings.
- Added Transposer issue/return, idle chest validation, and unexpected-item blocking.

