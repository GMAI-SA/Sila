# TrustNet iOS (Social SA)

Phase 1 — Authentication. Swift 5.9 / SwiftUI, iOS 17+, MVVM + Clean Architecture,
zero third-party dependencies.

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

`AppConfig.apiBaseURLString` → `https://portal.gmai.sa/socialsa/api/v1`
(one line to change; a unit test asserts it stays HTTPS, since no ATS exception
is declared). API contract and ops notes live on the server at
`/home/ubuntu/social-sa/docs/api-contract-v1.md` and `infra/DEPLOY.md`.

**Auth is email + password with a 6-digit email OTP.** Phone OTP and the Nafath
track land later behind the same endpoints.

## Running without a backend

```bash
# in the scheme's launch arguments, or via xcodebuild
-mockAuth -mockScenario pendingReview
```
`AuthServiceMock` ships 9 scenarios covering every verification-wall state plus
`emailUnverified`, `invalidCredentials`, `otpAlwaysInvalid` and `offline`.

## Tests

110 tests. Three of them (`LiveAPITests`) hit the real deployed backend and skip
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
└── Modules/Auth/  Domain (models, protocols) · Data (AuthService, mock) · Presentation (screens)
```

`FeatureFlags` declares all 14 phase flags; only `auth` is on. Later phases add a
folder under `Modules/` and flip their flag — they talk to Auth only through
`AuthSessionProtocol`.
