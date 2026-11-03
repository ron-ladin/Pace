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
- Never commit or push unless the owner explicitly asks for it in the current task, and then use only the git operations that request allows.

## Documentation Map

- `ARCHITECTURE.md`: goals, phases, requirements, NFRs, load estimates, access patterns, high-level architecture, stack, the decision log (D-numbers), open questions and order of work. Read the relevant section when you need scope or a decision.
- `docs/design/database.md`: index of the database design (schema, indexes, transactions, jobs, migrations, verification). Read when working on tables, SQL, locks or races.
- `docs/design/api.md`: index of the API design and its rationale (conventions, upload, auth, errors, limits). Read when working on HTTP behavior.
- `docs/design/classes.md`: index of the backend class design (modules, inventory, persistence, flows, traceability). Read when deciding where code goes or how a flow runs.
- `docs/api/openapi.yaml`: root of the API contract, the source of truth for the HTTP API, with `paths/` and `components/` beside it. Read the one path file or search for a schema name.
- `docs/design/verification/README.md`: how to run the database, class, Mermaid and link checks. Read before running them or after changing a design document.
- `docs/api/verification/README.md`: how to bundle the contract and run its linters and coverage check. Read before running them or after changing the contract.

## Reading Rule

1. Search first: grep for a decision ID (`D33`), an endpoint (`/me/runs`) or a table name (`competition_participants`).
2. Then read only the relevant file or section. A citation such as "database 6.3" is a section number, and each index's section map names its file.
3. Never load whole large documents "just in case".
4. Do not import large files with `@`. This file holds pointers only.
