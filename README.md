# Nestic API

A Swift/Vapor API with PostgreSQL persistence and authenticated WebSocket updates. It supports accounts, private nests, members and roles, people/pets/things, custom trackers, pinned quick actions, and a shared activity feed.

## Run locally

Install Xcode with Swift 6.2 or newer and Docker Desktop, and start Docker Desktop. From this directory:

```sh
docker compose up -d db
swift run NesticServer migrate --yes
swift run NesticServer serve
```

The API listens at `http://localhost:8080`; `GET /health` checks that the process is running. The database uses the development settings in `docker-compose.yml` automatically. Data survives server restarts in the Docker volume. This compose file uses a new `nestic_pg17_data` volume, leaving any old prototype `db_data` volume untouched. If your prototype database contains data, export it from its original Postgres version and restore it into this database before switching accounts over; do not delete the old volume.

For a complete container build (including migrations):

```sh
docker compose up --build
```

In the iOS simulator, select `http://localhost:8080` as the API server. On a physical iPhone, use your Mac's LAN IP, such as `http://192.168.1.50:8080`, while on the same Wi-Fi network. For remote family testing, use the HTTPS Railway URL.

Create an account in the app. Password accounts receive a verification email before they can sign in; Apple and Google accounts are verified by their identity provider. To share a nest, the other person first creates their own account on the same server; an owner or administrator then adds their email from the nest's members screen. Password reset links are delivered by Resend.

Sample database data is opt-in: use `SEED_DEMO_DATA=true swift run NesticServer migrate --yes` in development. That creates the legacy `test@nestic.local` / `password` account. Do not enable it on a hosted service. The app's local demo is independent of this database.

For App Review, the server includes a separate, neutral fixture that creates `test@test.com` with a verified email, an `App Review Nest`, multiple subjects and trackers, dated history, an open and resolved health event, a text update, a routine, prediction settings, quiet hours, and a reminder. It is deliberately one-shot and must be enabled explicitly for one deployment:

```sh
SEED_APP_REVIEW_DATA=true APP_REVIEW_SEED_PASSWORD='set-this-in-Railway' AUTO_MIGRATE=true swift run NesticServer serve
```

Set `APP_REVIEW_SEED_PASSWORD` to the password you will give App Review, but do not commit it. After the deployment has started successfully, remove `SEED_APP_REVIEW_DATA` and `APP_REVIEW_SEED_PASSWORD`; the migration record keeps the fixture from being recreated. Grant manual Pro from **Admin dashboard → User accounts → Account access** if the review account should exercise Pro-only screens. Remove it there when the account should use the free plan. The fixture does not overwrite an existing App Review nest that already contains data.

## Railway preparation

The Dockerfile uses Swift 6.2 to match the locked dependencies. The Dockerfile and `railway.json` are included; no service or DNS has been deployed. The native server and PostgreSQL integration were tested locally; the production Docker image still needs its first container build on Railway. Railway uses the process's `PORT` variable, and the server listens on `0.0.0.0`. The supplied configuration sets `/health` as the deployment healthcheck. See [Railway configuration](https://docs.railway.com/config-as-code/reference) and [healthchecks](https://docs.railway.com/deployments/healthchecks).

1. Push the server to a private GitHub repository. If this is a combined repository, set the Railway service root to `/NesticServer`; if this server is the repository root, leave the root at `/`.
2. Add a PostgreSQL service in the same Railway project.
3. Add these variables to the API service:

   | Variable | Value |
   | --- | --- |
   | `DATABASE_URL` | Reference the PostgreSQL service's `DATABASE_URL` |
   | `DATABASE_TLS_MODE` | `require-unverified` for Railway's private Postgres URL |
   | `JWT_SECRET` | A randomly generated secret of at least 32 bytes; generate one with `openssl rand -hex 32` |
   | `GOOGLE_CLIENT_IDS` | Comma-separated Google **web** OAuth client IDs used by Android Credential Manager (public IDs, not secrets) |
   | `APPLE_CLIENT_IDS` | Comma-separated Apple audiences, for example `com.bausch.Nestic-iOS,com.example.nestic.web` |
   | `NESTIC_MANUAL_PRO_EMAILS` | Optional comma-separated account emails to unlock Pro manually for testing/support |
   | `AUTO_MIGRATE` | `true` |
   | `LOG_LEVEL` | `info` |
   | `R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |
   | `R2_BUCKET` | `nestic-photos` |
   | `R2_ACCESS_KEY_ID` | Cloudflare R2 S3 Access Key ID for the bucket-scoped token |
   | `R2_SECRET_ACCESS_KEY` | Cloudflare R2 S3 Secret Access Key for the bucket-scoped token |
   | `R2_MAX_UPLOAD_BYTES` | Optional; default `524288` (512 KB per photo) |
   | `R2_DAILY_UPLOAD_BYTES_PER_USER` | Optional; default `5242880` (5 MB per user/day) |
   | `R2_DAILY_UPLOADS_PER_USER` | Optional; default `20` |
   | `R2_UPLOADS_PER_MINUTE_PER_USER` | Optional; default `6` |
   | `R2_DAILY_READS_PER_USER` | Optional; default `1000` |
   | `R2_READS_PER_MINUTE_PER_USER` | Optional; default `60` |
   | `R2_DAILY_UPLOAD_BYTES_TOTAL` | Optional; default `104857600` (100 MB/day for the service) |
   | `R2_DAILY_UPLOADS_TOTAL` | Optional; default `500` |
   | `R2_DAILY_READS_TOTAL` | Optional; default `10000` |
   | `AUTH_LOGIN_LIMIT` | Optional; default `12` attempts per client per minute |
   | `AUTH_REGISTER_LIMIT` | Optional; default `6` registrations per client per hour |
   | `AUTH_APPLE_LIMIT` | Optional; default `12` Apple auth requests per client per minute |

4. Deploy with the supplied Dockerfile and leave the container start command unchanged. Migrations run before the server starts when `AUTO_MIGRATE=true`.
5. Generate a Railway HTTPS domain and enter it in the iOS app's server setting. For your domain, add `api.nestic-app.com` as a custom domain and copy Railway's exact DNS target into your domain provider. Reserve `www.nestic-app.com` for a website later.
6. Run **one API replica**. WebSocket fanout currently lives in memory within one process. Add Redis or another shared event bus before increasing replica count. Clients refresh when reconnecting to recover updates missed during restarts.

Production startup refuses a missing or short JWT secret. Changing the secret signs everyone out. Tokens expire after seven days; users then sign in again. Configure PostgreSQL backups through your hosting provider before storing important data. The API rate-limits unauthenticated login, registration, and Apple authentication attempts in-process; keep Cloudflare/Railway edge limits enabled as well if the service is scaled beyond one replica. Users can permanently delete their account from **Your nest → Account data**; shared nests are transferred to another member when possible.

### Cloudflare R2 photos

Subject photos use the private `nestic-photos` Cloudflare R2 bucket. The server stores only an `r2://...` object reference in PostgreSQL and proxies photo reads after checking nest membership; the bucket does not need public access. The iOS app compresses camera-library photos to JPEG before uploading them, which keeps request sizes within the server's 2 MB limit.

Create a Cloudflare R2 API token with **Object Read & Write** access scoped only to `nestic-photos`, then add the four `R2_*` variables above to the Railway API service. Keep the access key and secret in Railway's encrypted variables only; never commit them to `.env`, source control, or chat. If the variables are missing, the API still starts, but the photo endpoints return `503` until storage is configured.

The API also applies a process-local R2 safety guard. By default, one photo is limited to 512 KB, each user can upload 5 MB or 20 photos per UTC day, uploads are burst-limited to 6 per minute, and photo reads are limited to 60 per minute and 1,000 per day per user. The service-wide defaults are 100 MB of uploads, 500 uploads, and 10,000 reads per UTC day. Requests that exceed a limit receive `413` or `429` with a `Retry-After` header. Override these defaults with the `R2_*` limit variables in Railway if your beta size requires it. Keep one API replica while using this guard; the counters are intentionally in-process because the current deployment does not use Redis.

## TestFlight beta deployment

The API must be public before a TestFlight build can support real accounts and shared nests. Railway is the intended first deployment target because the repository already includes a production Dockerfile and health check.

1. Create a Railway project with a PostgreSQL service and an API service sourced from this repository. If Railway is pointed at the combined repository, set the API service root directory to `/NesticServer`; `Dockerfile` and `railway.json` are relative to that directory.
2. Add these API variables using Railway references where applicable:

   | Variable | Value |
   | --- | --- |
   | `DATABASE_URL` | Reference the PostgreSQL service’s `DATABASE_URL` |
   | `DATABASE_TLS_MODE` | `require-unverified` for Railway's private Postgres URL |
   | `JWT_SECRET` | A new random value from `openssl rand -hex 32` |
   | `GOOGLE_CLIENT_IDS` | Comma-separated Google **web** OAuth client IDs used by Android Credential Manager (public IDs, not secrets) |
   | `APPLE_CLIENT_IDS` | Comma-separated Apple audiences, for example `com.bausch.Nestic-iOS,com.example.nestic.web` |
   | `AUTO_MIGRATE` | `true` |
   | `LOG_LEVEL` | `info` |

3. Deploy one API replica and generate its HTTPS domain. Check `https://your-domain/health`; it should return a successful JSON response. Keep one replica because WebSocket fanout is currently held in process memory.
4. Optionally point `api.nestic-app.com` at the Railway domain. The iOS Release configuration currently uses `https://api.nestic-app.com`; if you use the generated Railway URL instead, change the Release `NESTIC_SERVER_URL` setting before archiving the TestFlight build.
5. In Apple Developer, enable the **Sign in with Apple** capability for the `com.bausch.Nestic-iOS` App ID, then refresh the app's signing profiles in Xcode. The iOS project includes the entitlement and the API verifies Apple's identity token server-side. Existing email/password users can sign in normally and link Apple from **Settings → Account security**; new users can use Apple directly. Do not enable `SEED_DEMO_DATA` on the hosted service. The sample nest in the iOS app is local-only and is not a hosted account.

The API does not send email invitations. For the first beta, share the TestFlight link separately, have each tester register inside Nestic, and add their registered email from the nest’s member controls. Email verification and password recovery use Resend. Configure and verify `nestic-app.com` in Resend, then add `RESEND_API_KEY`, `RESEND_FROM`, `API_PUBLIC_URL`, and `WEB_APP_URL` to the Railway API service. The API applies process-local limits to registration and recovery endpoints; add an edge CAPTCHA/rate limit such as Cloudflare Turnstile and Cloudflare rate limiting before a public launch if you need stronger bot resistance.

## API contract

All protected endpoints require `Authorization: Bearer <token>`. JSON dates are ISO 8601. HTTP errors use Vapor's `{ "error": true, "reason": "..." }` response.

| Endpoint | Behavior |
| --- | --- |
| `POST /auth/register` | `{email,password,displayName,imageURL?}` → `{requiresEmailVerification:true}` and sends a verification email |
| `POST /auth/login` | HTTP Basic email/password → `{token}` |
| `GET /auth/verify?token=...` | Verify a one-time email token and show a confirmation page |
| `POST /auth/resend-verification` | `{email}` → generic response; sends a fresh verification email when appropriate |
| `POST /auth/forgot-password` | `{email}` → generic response; sends a one-hour reset link when appropriate |
| `POST /auth/reset-password` | `{token,password}` → confirms the new password |
| `GET /auth/me` | Safe profile: `id,email,displayName,imageURL?,createdAt?,updatedAt?` |
| `DELETE /auth/me` | Permanently delete the authenticated account and its private data; shared nests are transferred when possible |
| `GET /nests`, `POST /nests` | List your nests; create with `{name}` |
| `GET /nests/:id/members`, `POST /nests/:id/members` | List; add existing account with `{email,role}`; nests may have multiple equal owners |
| `PATCH /nests/:id/members/:userID`, `DELETE /nests/:id/members/:userID` | Owner changes role or removes member; the last owner is protected |
| `GET /nests/:id/entities`, `POST /nests/:id/entities` | List; create `{kind,name,tags?,metadata?,birthday?,imageURL?}` |
| `PATCH /entities/:id`, `DELETE /entities/:id` | Edit; remove subject and its activity |
| `PUT /entities/:id/photo`, `GET /entities/:id/photo`, `DELETE /entities/:id/photo` | Upload, read, or remove a private JPEG subject photo |
| `GET /nests/:id/actions`, `POST /nests/:id/actions` | List; define tracker `{name,valueType,unit?,description?}` |
| `PATCH /actions/:id`, `DELETE /actions/:id` | Edit tracker metadata or remove a tracker, its quick-action pins, and its history |
| `GET /entities/:id/pinned-actions`, `PUT /entities/:id/pinned-actions` | Read; replace pins with `{actionIds:[UUID]}` |
| `GET /nests/:id/entities/summary` | Subjects, ordered pinned actions, and latest value for each |
| `GET /nests/:id/forecasts`, `PUT /nests/:id/forecasts` | Read or publish the latest shared forecast payloads for the nest; each item is keyed by `{subjectId,trackerId}` and includes its predicted time, confidence, and source event time |
| `POST /nests/:id/actions` | Create a tracker with optional `{name,valueType,unit,symbol,color,groupName,description}` |
| `POST /entities/:id/events` | Log `{actionID,occurredAt?,valueNumber?,valueText?,valueBool?,valueJSON?,note?,wasAccident?,includeInPredictions?}` |
| `GET /nests/:id/events?limit=200&before=<ISO date>` | Shared feed page, newest first; use `before` for older updates |
| `GET /entities/:id/events?limit=200&before=<ISO date>` | Subject feed page, newest first; use `before` for older updates |
| `DELETE /events/:id` | Logger or administrator deletes activity |

`kind` is `person`, `pet`, `thing`, or `custom`. `valueType` is `none`, `number`, `text`, `boolean`, or `json`. Only supply the matching value field, or none for a simple occurrence. `valueJSON` is a string-to-string dictionary. Activity cannot be dated more than five minutes ahead of the server. Names are trimmed and limited to 100 characters; notes/text to 2,000.

Every event also carries `wasAccident` and `includeInPredictions` metadata. Both are optional when creating an event; they default to `false` and `true`, respectively. Updates may omit either field to preserve its existing value.

Owners/admins define trackers and add members. Only owners can grant administrator/owner roles. Members can add and edit subjects, pin actions, and log activity. Viewers can read but cannot mutate nest content.

### Realtime

Connect to `wss://<server>/ws` with the same Bearer header (legacy `?token=` also works). Authentication completes before the upgrade. The server sends `{"type":"ws.ready"}`; subscribe with:

```json
{"type":"subscribe","nestId":"YOUR-NEST-UUID"}
```

The server checks membership and acknowledges with `ws.subscribed`. A connection subscribes to one nest at a time. Updates use `{v:1,type,nestId,ts,data}` with events including `actionEvent.created`, `event.deleted`, `entity.created`, `entity.updated`, `entity.deleted`, `action.created`, `member.created`, `member.updated`, `member.deleted`, `pinnedActions.updated`, and `forecast.updated`. Deleted activity includes `id,nestId,entityId`. Removing a member closes their nest connections; token expiry also closes connections. Reconnect and reload REST data after network interruptions.

## Tests

```sh
swift test
```

The default suite needs no database and checks authentication boundaries, invalid registration, typed event validation, identity normalization, and password-hash exclusion. To run the full shared-nest integration test with the local database running:

```sh
RUN_DATABASE_TESTS=true swift test
```

The integration test creates uniquely named test accounts and a nest, tests viewer restrictions, promotion to member, shared logging, isolation from another user, and deletion, then removes its records. It applies migrations but never reverts your database.

If the active command-line developer directory points to an old Xcode, prefix commands with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (or your installed Xcode path).

## Manual Pro access

Nestic administrators can search accounts and grant or remove manual Pro from the iOS admin dashboard or web dashboard’s **View users** screen. Only verified, globally authorized Nestic administrators can call `PATCH /admin/users/:id/pro` with `{"enabled": true}` or `{"enabled": false}`; a nest owner/admin role does not confer this permission. The response contains the updated account and its `manualPro` status.

The `AddManualProAccess` migration stores a nullable per-account decision and the last administrator/time responsible for changing it. An explicit grant or removal overrides `NESTIC_MANUAL_PRO_EMAILS`; accounts without an admin decision continue to use that legacy allowlist. Auth/session refresh returns the effective value to existing app and web clients. Removing manual access does not cancel or override an Apple subscription.

Deploy the server with migrations before releasing the updated clients. The iOS controls remain unavailable when an older server does not return manual access status. No account is granted or revoked by this migration alone.

## Android Google sign-in

Set `GOOGLE_CLIENT_IDS` to the web OAuth client ID configured as Android's `GOOGLE_WEB_CLIENT_ID`. No client secret or redirect URI is used. Google Cloud also needs an Android OAuth client for `com.nestic.app` and each installed app signing certificate (debug locally; Play app signing certificate for Play releases). Existing Apple and password sign-in continue to work.

`POST /auth/google/challenge` creates a random five-minute nonce. Pass it into Credential Manager and submit `{identityToken,nonce,acceptedTermsVersion?}` to `POST /auth/google`. New accounts require explicit acceptance of the current Nestic terms; existing Google accounts use the stable Google subject. `POST /auth/google/link` requires a current Nestic bearer session plus a fresh Google proof. Accounts are never merged merely because emails match. `GET /auth/me` adds `googleLinked`.

Google JWT signature, issuer, expiration, audience, verified email, issue time, and nonce are verified on the server. Challenges are stored as SHA-256 hashes and consumed atomically in PostgreSQL, preventing replay across replicas. `AddGoogleIdentity` adds a nullable identity column, unique index, and expiring challenge table; run migrations before serving the new routes (`AUTO_MIGRATE=true` on Railway). Only Google's fixed HTTPS JWKS endpoint is trusted.

`swift test --filter Google` checks identity boundaries without a database. `RUN_DATABASE_TESTS=true swift test --filter Google` additionally checks signup, terms acceptance, repeat login, replay rejection, email collision, and authenticated linking against the configured local test database. Never run integration fixtures against production.

### Private trackers

Authenticated `GET /capabilities` advertises `privateTrackers: true`. Clients must check this before submitting `isPrivate: true` to `POST /nests/:nestID/actions`; this prevents an older server from silently creating a shared tracker. The server assigns `privateOwnerId` from the session, never from client input. Ordinary members can create private trackers; shared tracker management still requires owner/admin permissions. Visibility cannot change after creation.

Private trackers, pins, events, photos and dependent reminders are visible only to their account owner, including on another signed-in device. Nest administrators have no override. Collection filtering happens before event pagination, and realtime messages use the same owner boundary. Routines containing a private tracker receive immutable account ownership and remain hidden from other members; private-tracker forecasts are synchronized to the owner only. Private trackers cannot be added to caregiver links. Per-user settings may reference the user's own private trackers. Changing a reminder between shared and private requires creating a new reminder. The database migration refuses rollback while private trackers exist, so a rollback cannot publish private data.

Medication reminders support `afterDose`, `intervalHours` (0.25–720), and optional `totalPills` (1–100000). The course start (`anchorDate`) limits which dose logs count. Each positive dose resets the reminder; simple updates count one pill and number trackers record pill quantities. No dose means no reminder; completing the total cancels it. Server reads compute progress from full history, including corrected/deleted logs. Private medication reminders stay owner-only. Mobile apps deliver notifications; the website configures schedules and displays course progress.

Restricted trackers can additionally grant selected current nest members view and logging access. Only the tracker creator can manage sharing (`PUT /actions/:id/sharing`, `allowedMemberIDs`). Other members, including nest admins, cannot change that tracker. Direct events/photos, list pagination, pins, reminders and realtime follow the audience; reminders intersect the audiences of their linked trackers. Private routines remain creator-only and become inaccessible if a referenced tracker is revoked. Forecast learning inputs must be visible to every target reader. Sharing changes invalidate forecasts and send a content-free refresh signal. Removal from a nest clears grants, including grants made by the departing creator. Previously seen or offline-cached data cannot be remotely recalled until sync.

Forecast publishing includes `inputTrackerIDs`. The backend checks source audiences and names. For forecasts visible to multiple accounts, legacy or unsafe input lists fall back to a baseline computed solely from that target’s database history; contextual values, confidence/error statistics and input labels from the unverified calculation are discarded. Private-only forecasts remain account-scoped.
