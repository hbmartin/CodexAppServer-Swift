# ``CodexAppServerObservation``

Main-actor observable state for Codex applications.

## Overview

The product provides connection, conversation collection/detail, streamed-item, and pending-interaction models. Each model has an Observation surface and a Combine publisher. ``CodexCombinePublishers`` exposes equivalent connection, task, event, and interaction subjects.

The product contains no UI, navigation, host selection, persistence, or message drafts. Call `stopObserving()` when the owning feature ends.

The conversation detail model subscribes before fetching history, initializes its ordered turns and items before `observe` returns, and reconciles those collections when authoritative history arrives after reconnect. Pending interactions are removed by their original numeric or string protocol request IDs.
