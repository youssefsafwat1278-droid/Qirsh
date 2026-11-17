# Evidence template

One record per checklist item per release. Records go in the release's coverage matrix or test-evidence file, not here.

## Checklist item record

```
ID:                 <stable ID from MASTER-CHECKLIST, e.g. DATA-05>
Applicability:      APPLICABLE | NOT APPLICABLE — <reason if not applicable>
Risk:               C | H | M
Acceptance:         <copied from the checklist, or the release's tightened version>
Method:             A | I | R | D | P | S  (automated / inspection / simulator-emulator / device / production read-only / store console)
Status:             PASS | FAIL | NOT TESTED | NOT APPLICABLE
Evidence:           <command and result, log path, file:line, screenshot path — synthetic data only>
Evidence date:      <YYYY-MM-DD>
Commit / build:     <full or 8-char SHA> / <version (build)> or "source only"
Configuration:      <flags, dart-defines, backend environment, consent state that mattered>
Environment:        <device model + OS, or simulator/emulator + OS, or machine + toolchain>
Reviewer:           <person, or "AI agent: <role>, model <id>">
Linked finding:     <issue ID, or "none">
Reuse justification:<only if evidence predates the candidate: why it still applies>
```

## Rules

- `PASS` requires that the stated method was actually performed at the stated commit. Code inspection is a legitimate method for some items but it is never a device test; say `I`, not `D`.
- `NOT TESTED` needs the reason and what is required to test it (device, credential, service).
- A `FAIL` links to a finding in the issues register.
- Screenshots that could show personal or financial data are taken with synthetic data, or kept outside the repository and referenced by description.
- Never paste secrets, tokens, real message text, phone numbers or account numbers.
- An automated-gate record quotes the gate script's summary block and the exit code, plus the log location.

## Coverage matrix row

```
| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
```

`Result` uses the four statuses. `Evidence` points at a record or log. `Issue` is an ID from the issues register or `—`.

## Finding record

```
ID:            <AREA-NN>
Title:
Severity:      S1 | S2 | S3 | S4
Class:         REPRODUCED | CODE-SUPPORTED | SUSPECTED | PRODUCT-DECISION | ENV-LIMITATION
Platforms:
User impact:
Evidence / reproduction:
Root cause:    <or "not established">
Proposed fix and compatibility implications:
Verification required:
Status:        OPEN | FIXED (commit) | VERIFIED (evidence) | ACCEPTED (exception ID) | DEFERRED | NOT A DEFECT
Residual uncertainty:
```
