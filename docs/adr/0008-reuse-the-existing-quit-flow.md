# Reuse the quit UI with segment-specific durability ordering

Status: accepted.

Reuse the existing status/wait/cancel/override presentation with one asynchronous termination owner, not the disabled legacy sync registry as a new provider coordinator. Finish or explicitly cancel external-editor handoffs; quiesce new admission; force all admitted local note/action/parent barriers; persist required private state; settle or explicitly defer projections; optionally wait for this close's provider objects; fence/drain callbacks and release ownership last. applicationWillTerminate does no second save.

Local note failure keeps pending live work and offers Retry or a verified current-notes recovery export, distinctly labeled from repository Save As. A repository-only copy cannot clear unsaved live generations. Unsaved private settings and failed association/key cutover are reported distinctly. Derived materialization failure alone cannot block durable quit. Provider/file waiting can be left through Quit Without Waiting once local note safety is established; exact unpublished objects remain for restart. Cancel resumes admission only if local health permits.

No shared checkpoint-current retry, history cleanup, upload-qualified deletion or provider-global completeness inference exists. Hung provider work cannot block local durability or main-thread UI, and a deadline cannot transfer an accessor's still-live resources.

Optional [idle database compaction](../impl-proposal-5/plan/clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy) is not quit work. A quit request stops new maintenance and requests cancellation of an existing attempt; retain its connection and ownership until it settles. Qualify that settling latency before enabling automatic execution. Maintenance success is never a prerequisite to otherwise durable quit, and failure cannot erase already committed work.

Normative requirements: DUR-01, CKPT-01, ROOT-01, WAIT-01.
