# Potential problems

## Common failure modes

* Over-complex Docker environments
* Inconsistent startup behaviour
* Reliance on timing or race conditions
* Incomplete or noisy PCAPs
* Multiple unintended solution paths

Tend to appear after submission, hardly ever before.

## Dependencies

| Dependency      | Notes                             |
|:----------------|:----------------------------------|
| Linux           | Tested on modern distributions    |
| Docker Engine   | Required for dynamic environments |
| Docker Compose  | For orchestration where used      |
| Python          | For determinism                   |
| git, make, bash | For setup                         |

Fewer runtime dependencies increase acceptance probability.

## Way out :-)

```commandline
docker rm -f $(docker ps -aq) 2>/dev/null
docker system prune -a --volumes -f
```