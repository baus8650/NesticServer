# Tracker privacy audit — October 10, 2026

Scope: Nestic backend endpoints, realtime delivery, iOS/Android/web tracker rendering and forecast publishing, synced reminders, routines, photos, pins and cached snapshots.

## Findings addressed

- Embedded JSON could fall back to its original string when filtering removed a private root object. Filtering now drops it, including whitespace-prefixed JSON; request-reference parsing uses the same rule.
- Forecast maintenance could delete another member’s hidden private forecasts. Maintenance now skips unauthorized targets.
- Older builds could publish a forecast calculated using inputs outside its audience. Updated clients send input tracker IDs; the backend verifies every source is readable by every target reader. Missing/unsafe proofs use a target-history-only baseline, discarding contextual values and derived statistics. Target names come from the stored tracker.
- Sharing changes invalidate stored forecasts and local model feedback, update realtime audiences, and issue a content-free snapshot refresh. Revoked routine dependencies block the routine itself and direct logging.

## Selected-member access

Create a Restricted tracker, or edit an existing private tracker, and select eligible current nest members. No selections means Only me. Selected members may view and log; only the creator manages sharing or tracker metadata, including when a recipient is a nest administrator. Everyone trackers retain their existing visibility.

History, binary photos, pagination, pins, reminders and realtime enforce the same audience. Linked reminder audiences intersect. Private routines remain creator-only; referenced trackers must still be available. Restricted resources are excluded from caregiver access. Leaving a nest clears grants to that member and grants made by a departing creator.

## Validation

24 backend tests pass with Postgres, including actual grant/revoke API calls, selected-member logging, excluded-member reads, direct photo requests, stale routine logging, creator-only management, legacy/unsafe forecast fallback and valid contextual inputs. Web tests cover sharing creation, creator-only changes and forecast audience rules. Native tests cover permission caching, grant/revoke operations and audience-safe inputs.

## Limits

Revocation prevents further authorized reads and updates. Connected apps refresh their snapshots; offline devices cannot be updated until they reconnect. Data already viewed, copied or downloaded by an authorized person cannot be recalled. These tests are a targeted application access-control audit, not a guarantee against every possible vulnerability. Production deployment is pending approval.
