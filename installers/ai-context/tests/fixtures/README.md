The Windows strict v2 sample was produced by the unmodified Windows central
engine from Toolkit source `55354cb37ef0ee289a5db2dd868a274bce0501b5` using
disposable installed repositories and a local bare remote. The Python verifier
independently accepted the actual published Windows receipt, and fingerprint-v2
matched the Windows producer. Only the temporary member root and its derived
paths/ID were normalized to `C:\fixture\member` for this portable fixture.
Producer source hashes bind the sample to the Windows implementations.

`templates/common/central/tests/fixtures/member-1.2.9/context.py` is the exact
member launcher from that source revision, frozen solely to test installed
1.2.9 consumer compatibility against the current legacy central engine. It is
installed under central tests, never as the new member launcher. New member
strict behavior has separate contract, installed integration and Bash E2E gates.
