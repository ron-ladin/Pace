# Pace: Running Competitions App

A running app where users upload GPX runs, create and join time-boxed competitions among friends or groups, and follow leaderboards. It is both a way to learn backend and distributed-systems engineering and a real product for hundreds to a few thousand users. The backend is the focus.

Stack: Java 21+ with Spring Boot (modular monolith), PostgreSQL, MinIO and a PWA client. Status: detailed design is agreed for the database, API and classes. No application code exists yet, and a thin vertical slice is next.

## Working Agreement (for Claude and other assistants)

- The project owner is a third-year CS student with limited industry experience. The assistant acts as **tech lead**: it gives its honest opinion, challenges decisions with reasoning (even when it disagrees with the owner), and makes decisions jointly with the owner.
- **Learning is a primary goal**, equal to shipping the product. Explain trade-offs and why, not just what.
- **Work top-down:** requirements -> non-functional requirements -> load estimates -> access patterns -> high-level architecture -> detailed design per topic -> implementation. Do **not** jump to detailed design or code before the previous level is agreed.
- Every significant decision gets a short ADR entry (see the decision log). Do not silently change an agreed decision; propose the change and explain why.
- Prefer **measure first, then add complexity**. Distributed components (cache, queue, replicas, service splits) must be justified by measurements from load tests, not by intuition.
- **Zero-cost constraint:** only free and open-source tools and free tiers.
- Language: conversation replies are in **English**. All repository artifacts (code, docs, comments, commit messages) are also in **English**.

## Safety Rules

- Never use `rm -rf` or any other recursive or forced deletion (`del /s`, `Remove-Item -Recurse`). List what needs deleting, and the owner deletes it.
- Never enter payment details or create accounts on external services.
- Follow the git rules in "How we work". Commit only on a work branch, and never push.
- Use a task list for multi-step work, if one is available; otherwise post short progress messages.

## How we work

**Session start checklist**

1. Run `git status` and `git branch --show-current`, and tell the owner the branch and whether the tree is clean.
2. If the task will change files and you are on main or develop, stop. Create the right work branch from an up-to-date develop (`git fetch origin`, then `git switch -c <branch> --no-track origin/develop`), or ask. Never work on main or develop.
3. Read only what the task needs, using the Documentation Map and grep, never whole large documents.
4. Before finishing, run the verification that applies, and report honestly what was and was not verified.

**Branches and merging**

- `main` is released state. `develop` is integration and the default branch. Nobody commits to either directly.
- `feature/`, `fix/`, `docs/`, `chore/` and `test/` branches start from develop and return to it. `hotfix/` starts from main and returns to main and develop. One task is one branch.
- Work branch to develop: pull request, squash merge. develop to main: pull request, merge commit, then a tag.
- Commits and pull request titles use Conventional Commits, with a module as optional scope (`feat(runs): add GPX upload endpoint`). Releases use SemVer annotated tags on main (`vX.Y.Z`).

**Git: what you may do**

- Without asking in chat: `git status`, `diff`, `log`, `show`, `fetch origin`, `switch`; create a work branch; `git add` with explicit paths; commit on a work branch. Permission prompts may still appear, and the owner approves them.
- Before every commit: show `git status`, `git diff --stat` and exactly what is staged, and run the secret check.
- Only when the owner explicitly asks in the current task: merge, pull, stash, restore, revert, cherry-pick, any `gh` command.
- Denied by `.claude/settings.json`, so the owner runs these personally: push, reset, rebase, `commit --amend`, `--no-verify`, force forms, deleting or renaming branches, tags, git config, `git add -A` or `.` or `-f`, remote changes, clean, history rewriting, recursive deletion. Never work around a deny rule; report it.
- "Never commit on main or develop" has no local technical block. Procedure and GitHub rulesets (no direct pushes) enforce it, and the deny rules stop Claude from pushing, though they match command text and are not a security boundary.
- If something looks wrong (unexpected or large files, conflicts, a detached HEAD, a missing git identity), stop and tell the owner.

**Secrets: hard rules**

- Never commit, write, print or ask the owner to paste keys, tokens, passwords, private keys, certificates, credentials or real personal data.
- Configuration comes from environment variables or untracked files. Only a placeholder `.env.example` is committed.
- Run the staged-diff secret check before every commit. It prints file names only.
- If a secret is ever found, stop and tell the owner without printing it. Never rewrite history on your own.

Details, exact commands and incident procedures: `docs/process/git-workflow.md`.

## Documentation Map

- `ARCHITECTURE.md`: goals, phases, requirements, NFRs, load estimates, access patterns, high-level architecture, stack, the decision log (D-numbers), open questions and order of work. Read the relevant section when you need scope or a decision.
- `docs/design/database.md`: index of the database design (schema, indexes, transactions, jobs, migrations, verification). Read when working on tables, SQL, locks or races.
- `docs/design/api.md`: index of the API design and its rationale (conventions, upload, auth, errors, limits). Read when working on HTTP behavior.
- `docs/design/classes.md`: index of the backend class design (modules, inventory, persistence, flows, traceability). Read when deciding where code goes or how a flow runs.
- `docs/api/openapi.yaml`: root of the API contract, the source of truth for the HTTP API, with `paths/` and `components/` beside it. Read the one path file or search for a schema name.
- `docs/process/git-workflow.md`: branch model, merging, commits, versioning, exact commands, the secrets policy and incident procedure, enforcement and the GitHub settings. Read when branching, committing, releasing or handling a suspected leak.
- `docs/design/verification/README.md`: how to run the database, class, Mermaid and link checks. Read before running them or after changing a design document.
- `docs/api/verification/README.md`: how to bundle the contract and run its linters and coverage check. Read before running them or after changing the contract.

## Reading Rule

1. Search first: grep for a decision ID (`D33`), an endpoint (`/me/runs`) or a table name (`competition_participants`).
2. Then read only the relevant file or section. A citation such as "database 6.3" is a section number, and each index's section map names its file.
3. Never load whole large documents "just in case".
4. Do not import large files with `@`. This file holds pointers only.
