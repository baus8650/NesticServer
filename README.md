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

Create an account in the app. To share a nest, the other person first creates their own account on the same server; an owner or administrator then adds their email from the nest's members screen. This adds an existing account immediately. No invitation email or password reset email is sent.

Sample database data is opt-in: use `SEED_DEMO_DATA=true swift run NesticServer migrate --yes` in development. That creates the legacy `test@nestic.local` / `password` account. Do not enable it on a hosted service. The app's local demo is independent of this database.

## Railway preparation

The Dockerfile uses Swift 6.2 to match the locked dependencies. The Dockerfile and `railway.json` are included; no service or DNS has been deployed. The native server and PostgreSQL integration were tested locally; the production Docker image still needs its first container build on Railway. Railway uses the process's `PORT` variable, and the server listens on `0.0.0.0`. The supplied configuration sets `/health` as the deployment healthcheck. See [Railway configuration](https://docs.railway.com/config-as-code/reference) and [healthchecks](https://docs.railway.com/deployments/healthchecks).

1. Push the server to a private GitHub repository. If this is a combined repository, set the Railway service root to `/NesticServer`; if this server is the repository root, leave the root at `/`.
2. Add a PostgreSQL service in the same Railway project.
3. Add these variables to the API service:

   | Variable | Value |
   | --- | --- |
   | `DATABASE_URL` | Reference the PostgreSQL service's `DATABASE_URL` |
   | `JWT_SECRET` | A randomly generated secret of at least 32 bytes; generate one with `openssl rand -hex 32` |
   | `AUTO_MIGRATE` | `true` |
   | `LOG_LEVEL` | `info` |

4. Deploy with the supplied Dockerfile and leave the container start command unchanged. Migrations run before the server starts when `AUTO_MIGRATE=true`.
5. Generate a Railway HTTPS domain and enter it in the iOS app's server setting. For your domain, add `api.nestic-app.com` as a custom domain and copy Railway's exact DNS target into your domain provider. Reserve `www.nestic-app.com` for a website later.
6. Run **one API replica**. WebSocket fanout currently lives in memory within one process. Add Redis or another shared event bus before increasing replica count. Clients refresh when reconnecting to recover updates missed during restarts.

Production startup refuses a missing or short JWT secret. Changing the secret signs everyone out. Tokens expire after seven days; users then sign in again. Configure PostgreSQL backups through your hosting provider before storing important data. Push notifications, background delivery while iOS suspends the app, email verification, and password recovery are not implemented in this version.

## TestFlight beta deployment

The API must be public before a TestFlight build can support real accounts and shared nests. Railway is the intended first deployment target because the repository already includes a production Dockerfile and health check.

1. Create a Railway project with a PostgreSQL service and an API service sourced from this repository. If Railway is pointed at the combined repository, set the API service root directory to `/NesticServer`; `Dockerfile` and `railway.json` are relative to that directory.
2. Add these API variables using Railway references where applicable:

   | Variable | Value |
   | --- | --- |
   | `DATABASE_URL` | Reference the PostgreSQL service’s `DATABASE_URL` |
   | `JWT_SECRET` | A new random value from `openssl rand -hex 32` |
   | `AUTO_MIGRATE` | `true` |
   | `LOG_LEVEL` | `info` |

3. Deploy one API replica and generate its HTTPS domain. Check `https://your-domain/health`; it should return a successful JSON response. Keep one replica because WebSocket fanout is currently held in process memory.
4. Optionally point `api.nestic-app.com` at the Railway domain. The iOS Release configuration currently uses `https://api.nestic-app.com`; if you use the generated Railway URL instead, change the Release `NESTIC_SERVER_URL` setting before archiving the TestFlight build.
5. Create a real account from the app and create a nest. Do not enable `SEED_DEMO_DATA` on the hosted service. The sample nest in the iOS app is local-only and is not a hosted account.

The API does not currently send email invitations. For the first beta, share the TestFlight link separately, have each tester register inside Nestic, and add their registered email from the nest’s member controls. Email verification, password recovery, push notifications, and background delivery are follow-up production work.

## API contract

All protected endpoints require `Authorization: Bearer <token>`. JSON dates are ISO 8601. HTTP errors use Vapor's `{ "error": true, "reason": "..." }` response.

| Endpoint | Behavior |
| --- | --- |
| `POST /auth/register` | `{email,password,displayName,imageURL?}` → `{token}` |
| `POST /auth/login` | HTTP Basic email/password → `{token}` |
| `GET /auth/me` | Safe profile: `id,email,displayName,imageURL?,createdAt?,updatedAt?` |
| `GET /nests`, `POST /nests` | List your nests; create with `{name}` |
| `GET /nests/:id/members`, `POST /nests/:id/members` | List; add existing account with `{email,role}` |
| `PATCH /nests/:id/members/:userID`, `DELETE /nests/:id/members/:userID` | Owner changes role or removes member; the last owner is protected |
| `GET /nests/:id/entities`, `POST /nests/:id/entities` | List; create `{kind,name,tags?,metadata?,birthday?,imageURL?}` |
| `PATCH /entities/:id`, `DELETE /entities/:id` | Edit; remove subject and its activity |
| `GET /nests/:id/actions`, `POST /nests/:id/actions` | List; define tracker `{name,valueType,unit?,description?}` |
| `PATCH /actions/:id`, `DELETE /actions/:id` | Edit tracker metadata or remove a tracker, its quick-action pins, and its history |
| `GET /entities/:id/pinned-actions`, `PUT /entities/:id/pinned-actions` | Read; replace pins with `{actionIds:[UUID]}` |
| `GET /nests/:id/entities/summary` | Subjects, ordered pinned actions, and latest value for each |
| `POST /entities/:id/events` | Log `{actionID,occurredAt?,valueNumber?,valueText?,valueBool?,valueJSON?,note?}` |
| `GET /nests/:id/events?limit=200` | Shared feed, newest first; maximum 200 |
| `GET /entities/:id/events?limit=200` | Subject feed, newest first; maximum 200 |
| `DELETE /events/:id` | Logger or administrator deletes activity |

`kind` is `person`, `pet`, `thing`, or `custom`. `valueType` is `none`, `number`, `text`, `boolean`, or `json`. Only supply the matching value field, or none for a simple occurrence. `valueJSON` is a string-to-string dictionary. Activity cannot be dated more than five minutes ahead of the server. Names are trimmed and limited to 100 characters; notes/text to 2,000.

Owners/admins define trackers and add members. Only owners can grant administrator/owner roles. Members can add and edit subjects, pin actions, and log activity. Viewers can read but cannot mutate nest content.

### Realtime

Connect to `wss://<server>/ws` with the same Bearer header (legacy `?token=` also works). Authentication completes before the upgrade. The server sends `{"type":"ws.ready"}`; subscribe with:

```json
{"type":"subscribe","nestId":"YOUR-NEST-UUID"}
```

The server checks membership and acknowledges with `ws.subscribed`. A connection subscribes to one nest at a time. Updates use `{v:1,type,nestId,ts,data}` with events including `actionEvent.created`, `event.deleted`, `entity.created`, `entity.updated`, `entity.deleted`, `action.created`, `member.created`, `member.updated`, `member.deleted`, and `pinnedActions.updated`. Deleted activity includes `id,nestId,entityId`. Removing a member closes their nest connections; token expiry also closes connections. Reconnect and reload REST data after network interruptions.

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
