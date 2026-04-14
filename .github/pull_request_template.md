## Description

<!-- What does this PR do? Be specific. "Fixes stuff" is not helpful. -->

Summary:


Related Issue:
Fixes #(issue number)
<!-- Or: Relates to #(issue), Closes #(issue) -->


## Type of Change

<!-- Mark the relevant option with an 'x' -->

- [ ] Bug fix (fixes an issue without changing existing functionality)
- [ ] New device or container (adds a host to the topology)
- [ ] New zone or CTF scenario (new network segment or exercise)
- [ ] Breaking change (config schema or compose structure changes existing behaviour)
- [ ] Documentation update (no config or code changes)
- [ ] Refactoring (structure improvements, no functional changes)
- [ ] Protocol or service addition (new protocol support or service wiring)
- [ ] Security feature (detection, logging, or defensive capability)


## Testing

<!-- How did you verify this works? Be specific. -->

What I tested:
-

Test results:
```
# Paste relevant output, e.g.:
# ./ctl up && ./ctl verify
# All containers healthy
```

Manual testing:
<!-- If applicable: commands run, expected output, observed behaviour -->


## Checklist

<!-- Tick these off before submitting. If you cannot tick something, explain why in a comment. -->

Stack verification:
- [ ] `./ctl up` completes without errors
- [ ] `./ctl verify` passes for affected zones
- [ ] `generate.py` produces valid compose files (`python orchestrator/generate.py`)
- [ ] All affected containers build cleanly
- [ ] Zone routing behaves as expected (spot-checked with `./ctl ssh` or `docker exec`)

Documentation:
- [ ] Updated relevant documentation (README, docs/PLAN.md, etc.)
- [ ] Updated `ctf-config.yaml` comments if config schema changed
- [ ] Noted any new credentials or access paths in the appropriate docs

Architecture:
- [ ] Follows topology conventions (correct zone, IP range, network attachment)
- [ ] No credentials or sensitive data baked into images or compose files
- [ ] Vulnerabilities are device properties, not config toggles
- [ ] New containers include syslog or logging wiring where appropriate

Security and research:
- [ ] No unintended attack surfaces introduced in the platform itself
- [ ] Simulated vulnerabilities are clearly documented as intentional
- [ ] New attack paths are exercisable end-to-end (if adding a scenario)


## Breaking Changes

<!-- Does this change existing behaviour? Will users need to update their config or re-generate? -->

- [ ] Yes, this introduces breaking changes (describe below)
- [ ] No breaking changes

If yes, describe what breaks and how to migrate:


## Additional Context

<!-- Anything else relevant? -->

Implementation notes:


Known limitations:


Output or logs:
<!-- If relevant, paste command output, container logs, or network trace snippets -->


## Review Notes

<!-- For the maintainer -->

*"A misconfigured VLAN in a CTF is good realism. A misconfigured VLAN in the reviewer's head is how bugs ship. Check the network attachments carefully."*

Maintainer checklist:
- [ ] Topology compliance verified
- [ ] Test coverage adequate
- [ ] Documentation clear and accurate
- [ ] No unintended security exposure
- [ ] Commit messages follow convention