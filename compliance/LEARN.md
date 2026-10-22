# Read a CIS crosswalk

A benchmark is a published security checklist. A control ID belongs to one exact benchmark version, not to every Linux distribution.

Run `python3 compliance/report.py` to see every hk check and its mapping. Blank IDs mean unmapped, not compliant. Partial means our check does less than the benchmark audit. Even a PASS is not proof of compliance. SSH Match blocks, live effective configuration, persistent settings and site policy need separate review.

This crosswalk uses the actual Ubuntu 22.04 LTS v2.0.0 PDF, dated 2024-03-28. It is a study reference, not the latest benchmark and not certification. Our CI targets Ubuntu 24.04 and other distros, not Ubuntu 22.04 compliance validation. Do not reuse these numbers as RHEL/Debian control IDs. The benchmark PDF is not redistributed. Source URLs and printed page numbers are recorded per mapped row.

Exercise: compare SSH-001 with control 5.1.20 page 550. hk accepts prohibit-password; the benchmark requires no. Explain why a green check is not sufficient evidence.
