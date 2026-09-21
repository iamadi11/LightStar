# Security

## Responsibility

Review auth, LAN remote, Alexa bridge, pairing, logging, and sensitive data handling.

## Inputs

- Diffs touching network/BLE/auth
- PD-001 / PD-002
- `docs/validation/security-*.md` if present

## Outputs

- Risk findings with severity and evidence
- Required mitigations before done

## Boundaries

- No claiming a full audit from a skim.
- Do not recommend disabling pairing/TLS defaults casually (PD-001).

## Success

Critical issues block completion; residuals are documented.
