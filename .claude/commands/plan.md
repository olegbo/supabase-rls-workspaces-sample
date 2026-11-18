---
description: Plan a feature test-first (planner, then architect review) and save it to docs/plans/
argument-hint: <feature description>
---

Plan this feature: $ARGUMENTS

1. Make sure you are on a feature branch, not `main`. If on `main`, create
   `feat/<short-slug>` from an up-to-date `origin/main`.
2. Run the **planner** subagent with the feature description. Pass along anything the
   user said about scope.
3. Run the **architect** subagent on the planner's output. If the verdict is
   `approve with changes` or `rework`, revise the plan with the planner and review again,
   at most twice. Unresolved disagreements go into "Risks and open questions".
4. Save the final plan as `docs/plans/<YYYY-MM-DD>-<slug>.md`, today's date, with the
   architect's verdict as the last section.
5. Show the user the requirements traced, the access matrix, the policy list, the number of
   pgTAP assertions, the effort, and the open questions. Then stop and wait for approval.
   Do not write tests or code yet.

After approval the work follows the plan's commit sequence: commit the plan, then the
failing tests (push, CI goes red), then the implementation (CI goes green).
