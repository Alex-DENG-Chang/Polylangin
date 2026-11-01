# Security & privacy

Polylangin is a local input method. It does not send network requests and has no
telemetry.

## Reporting

Please open a private security advisory or email the maintainer for:

- memory-safety issues in the C shim / Rime integration;
- accidental logging of secure-input fields;
- any path that could leak typed text off the machine.

## Logs

The typing journal is local and may contain typed text. Do not attach raw
`*.jsonl` logs to public issues; redact or aggregate them first.
