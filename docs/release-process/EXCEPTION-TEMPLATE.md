# Exception (accepted limitation) template

An exception lets a release ship with a known S2 or S3 finding, or with a specific unverified requirement. S1 findings of the data-loss, cross-account, consent, financial-correctness and store-requirement kinds cannot be excepted.

An exception is only valid when the owner has filled in the approval block. Anyone may propose; nobody may approve for the owner.

```
Exception ID:        EXC-<release>-NN
Linked finding(s):   <issue IDs>
Proposed by:         <name or agent role>            Date:
Platforms / scope:

What is being accepted (one or two plain sentences):

User impact if it occurs:
How likely, and on what evidence:
Who is affected:

Why not fix now (cost, risk of the fix, dependency):

Mitigation in place for this release:
How we will detect it in production (signal, threshold):
What we will do if it occurs (containment, forward fix):

Expiry:              <release or date by which it must be fixed or re-approved>
Follow-up item:      <tracker reference>

--- Owner approval ---
Decision:            APPROVED | REJECTED
Owner name:
Date:
Conditions:
```

Rules:

- An exception without an expiry is invalid.
- An exception does not carry over to the next release. Re-propose it or fix the finding.
- The release decision lists every exception by ID. If the list is empty, the decision can be READY; otherwise at best READY WITH DOCUMENTED ACCEPTED LIMITATIONS.
- Rejected exceptions leave the finding open.
