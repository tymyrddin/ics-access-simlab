# Root-me requirements and constraints

## Submission process

Root-Me challenges go through three stages: category selection, moderator quality review, then publication. Rewards are
reserved for foundation members.

[A Root-Me account is required to submit](https://www.root-me.org/?page=rubrique&id_rubrique=176&objet=challenge#creations_recompensees).

## Submission form fields

| Field                | Required | Notes                                                                       |
|:---------------------|:---------|:----------------------------------------------------------------------------|
| Title                | Yes      | Relates to the vulnerability or attack technique                            |
| Subtitle             | Yes      | A clue, or something playful                                                |
| Description          | Yes      | Includes the challenge goal                                                 |
| Associated resources | No       | Tags separated by semicolons: words, sets `{a, b}`, directories, file globs |
| Score                | No       | Points awarded on validation                                                |
| Validation password  | No       | The flag                                                                    |

Challenge files are uploaded via a second form presented after initial submission. There is a known platform bug
where this second form does not appear. If so, a moderator will contact you separately for the files.

## Technical requirements

Docker-based setups run on Root-Me infrastructure. Images need to be self-contained with no runtime internet
dependency.

Python 3 is required for deterministic simulator components.

For the full list of per-challenge dependencies, see the problems page.
