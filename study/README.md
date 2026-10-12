# How to use the Meridian study guide

`study/index.html` is the pre-video workbook. Open it from the repository with a browser. The page is one file: its styles, diagrams, and scripts are inside it. A clone works offline. There is no CDN and no local server to start.

```bash
# macOS, from the repository root
open study/index.html

# or any browser
# file:///.../study/index.html
```

## Read it in recording order

1. Start at the map. The order is E0, E1, E2, E3, P0, then E4 through E13.
2. For the episode you are about to watch, read prerequisites, files, the command, the expected result, and the failure modes.
3. Read the logical blocks before you open the source file. Each block names the file and the line span, then walks the lines in order.
4. Do the exercise out loud. The defense box is the sentence you should be able to say without the slide.
5. Snowflake numbers that depend on your account are marked as expected results. Postgres counts and pytest are local and repeatable.

`coverage.json` is the machine-readable map. Each episode and each interview topic has an anchor in `index.html` and the repository files that prove it.

## Proofs to run with the episode

| Proof | File | What done looks like |
|---|---|---|
| Mart integrity | `03_snowflake/11_mart_integrity_and_quarantine.sql` | Demo duplicate and orphan are recorded with keys and reasons. A mart violation raises after those rows commit. Unknown member `-1` stays in the mart. |
| Referential integrity inside dbt | `04_dbt_meridian_dw/tests/assert_mart_referential_integrity.sql` | A returned row fails `dbt build` and keeps the key. |
| Slow-query order | `06_performance_lab/10_slow_query_triage_playbook.sql` | Cache off, fast and slow history, queue versus execution, widest operator, one classification, then a tagged rerun. |
| Shared tables versus physical isolation | `00_architecture/adr/0011-multitenancy-patterns.md` | You can defend isolation, versioning, cost, and blast radius. The Hong Kong proof is `RAP_COUNTRY_SCOPE`. |

ADR 0001 through ADR 0011 are files under `00_architecture/adr/`.

## Interview topics

The guide explains the warehouse, modelling, orchestration, quality, security, and tenancy defenses with Meridian evidence only. It does not contain private interview notes, employer names, compensation, or local account identifiers.

## Refreshing a public student checkout

From the instructor project that contains `tools/sync_student_repo.py`:

```bash
python3 tools/sync_student_repo.py --check
python3 tools/sync_student_repo.py --apply
```

`--check` only prints the plan. `--apply` copies the runnable folders, this `study/` directory, and the selected architecture documents. It installs `study/STUDENT_README.md` as the student `README.md`. It does not copy `.git`, `.env`, credential files, `.venv`, `Videos`, `Printouts`, `include/`, `profiles.yml`, `airflow_settings.yaml`, `target`, `dbt_packages`, `.terraform`, or tfstate, and it does not delete a nested `.git`.

Students who cloned the public repository do not run that script. They open this page and follow `setup/`.
