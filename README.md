# TrustNet iOS (Social SA)

Phases 1 (Authentication) and 3 (Feed). Swift 5.9 / SwiftUI, iOS 17+,
MVVM + Clean Architecture, zero third-party dependencies.

## Build

The project file is generated, so regenerate it after adding or moving files:

```bash
~/tools/xcodegen/bin/xcodegen generate --spec project.yml
open TrustNet.xcodeproj
```

Command line:

```bash
xcodebuild -project TrustNet.xcodeproj -scheme TrustNet \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

xcodebuild -project TrustNet.xcodeproj -scheme TrustNet \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.2' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Backend

`AppConfig.apiBaseURLString` → `https://sila.gmai.sa/api/v1`
(one line to change; a unit test asserts it stays HTTPS, since no ATS exception
is declared). API contracts and ops notes live on the server at
`/home/ubuntu/social-sa/docs/api-contract-v1.md` (auth),
`api-contract-v2-feed.md` (feed/social) and `infra/DEPLOY.md`.

**Auth is email + password with a 6-digit email OTP.** Phone OTP and the Nafath
track land later behind the same endpoints.

## The country-verified flag

The flag beside a post author's checkmark comes from the *verified identity* —
Nafath nationality, or the issuing country of a verified ID document — and never
from an IP address, a phone prefix or a device locale. `country_code` is `null`
until verification completes, and the UI renders **nothing** in that case rather
than guessing. `CountryCode.normalised(_:)` also rejects CLDR placeholders such
as `ZZ`, `EU` and `UK`, which `Locale.Region.isISORegion` would happily accept.

A post's `scope` (`international` / `country` / `region`) restricts **who may
reply**, never who may read. The server computes `viewer.can_reply` and
`viewer.reply_block_reason` per request; the client shows the reason in plain
language instead of a dead reply button and never re-derives the rule itself.

## Running without a backend

```bash
# in the scheme's launch arguments, or via xcodebuild
-mockAuth -mockScenario pendingReview
-mockFeedScenario unverifiedNoCountry
```
`AuthServiceMock` ships 9 scenarios covering every verification-wall state plus
`emailUnverified`, `invalidCredentials`, `otpAlwaysInvalid` and `offline`.

`FeedServiceMock` ships 5: `populated`, `empty`, `unverifiedNoCountry` (the
409 `no_country` explainer on My Country), `offline` and `paginationExhausted`
(a first page that promises more and a second that delivers nothing).
`-mockAuth` implies `-mockFeed` unless `-mockFeedScenario` says otherwise,
because a mocked session carries no bearer token the live feed would accept.

To see the whole feed without a backend:

```bash
-mockScenario verified -mockFeedScenario populated
```

## Tests

218 total: 216 unit (7 opt-in, see below) and 2 XCUITests. The UI tests drive
sign-in → feed against the mocks — no network, no seeded account — and are the
only tests that would catch a broken route or an untappable button, since every
view model passes in isolation whether or not the screens are wired together.
They also attach screenshots, extractable from the result bundle:

```bash
xcodebuild ... test -only-testing:TrustNetUITests -resultBundlePath out.xcresult
xcrun xcresulttool export --path out.xcresult --id <payloadRef> --output-path shot.png --type file
```

### Opt-in live tests

212 tests. Three of them (`LiveAPITests`) hit the real deployed backend and skip
unless you opt in — they are the only guard against the *server's* wire format
drifting away from the app's decoders:

```bash
TEST_RUNNER_TRUSTNET_LIVE_API=1 \
TEST_RUNNER_TRUSTNET_LIVE_EMAIL=you@example.com \
TEST_RUNNER_TRUSTNET_LIVE_PASSWORD='...' \
xcodebuild ... test -only-testing:TrustNetTests/LiveAPITests
```
The `TEST_RUNNER_` prefix is required — plain environment variables do not reach
the test process on the simulator.

## Layout

```
TrustNet/
├── App/           TrustNetApp, AppContainer (DI root), AppRouter, FeatureFlags, AppConfig
├── Core/          Network, Storage, Security (Keychain + biometrics), Analytics, DesignSystem
├── Modules/Auth/  Domain (models, protocols) · Data (AuthService, mock) · Presentation (screens)
└── Modules/Feed/  Domain (Post/UserSummary/FeedPage, presentation mappings)
                   Data (FeedService, mock) · Presentation (MainTabView, HomeScreen,
                   PostCardView, PostDetailScreen, Explore/Notifications)
```

`FeatureFlags` declares all 14 phase flags; `auth` and `feed` are on. Later
phases add a folder under `Modules/` and flip their flag — they talk to Auth
only through `AuthSessionProtocol`, and get a bearer token only through
`AccessTokenProviding`.

`PostCardView` is exported: the profile phase renders timelines with it
unchanged. Compose (Phase 4) and Profile (Phase 7) are honest stubs — a toast
saying the feature arrives in a later release — and Explore and Notifications
say the same, because contract v2 has no search, trending or notification
endpoints and inventing them would undermine the whole proposition.
