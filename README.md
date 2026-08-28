# Sila iOS (Social SA)

Phases 1 (Authentication), 3 (Feed) and 4 (Composer & Search), plus contract
v4's feed preferences. Swift 5.9 / SwiftUI, iOS 17+, MVVM + Clean Architecture,
zero third-party dependencies.

## Build

The project file is generated, so regenerate it after adding or moving files:

```bash
~/tools/xcodegen/bin/xcodegen generate --spec project.yml
open Sila.xcodeproj
```

Command line:

```bash
xcodebuild -project Sila.xcodeproj -scheme Sila \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Sila.xcodeproj -scheme Sila \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.2' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Backend

`AppConfig.apiBaseURLString` → `https://sila.gmai.sa/api/v1`
(one line to change; a unit test asserts it stays HTTPS, since no ATS exception
is declared). API contracts and ops notes live on the server at
`/home/ubuntu/social-sa/docs/api-contract-v1.md` (auth),
`api-contract-v2-feed.md` (feed/social), `api-contract-v3-search.md`
(compose clarifications, `/search/*`, `/explore/trending`),
`api-contract-v4-interests.md` (`/topics`, `/me/preferences`) and
`infra/DEPLOY.md`.

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

## Topic labelling, and the one screen that discloses it

The backend classifies every post into hidden topic tags and can filter the
**International feed** by them. The tags never appear on a post, so
`PreferencesScreen` is the only place a person learns the mechanism exists —
which is why the disclosure is the first card on the screen, in body type, and
is asserted verbatim in `TaggingDisclosureTests`.

The screen is built around not overstating what its controls do. Three rules
come straight from `interest_filter.py` and are reproduced in the copy:

* **The filter switch on with nothing selected narrows nothing.** The backend
  keeps the feed open rather than returning zero posts, so the live summary
  still reads "shows everything" and a warning says the switch is doing nothing
  and what to do about it.
* **Muted topics and muted countries apply whether or not that switch is on.**
  They are not gated by it, so the copy never implies they are.
* **`show_untagged_posts` only matters while the feed is narrowed to
  interests.** When nothing narrows it, the row says so instead of implying a
  change.

A live sentence (`PreferencesSummary.sentence(for:)`) states what the feed will
show, and is labelled `IN EFFECT NOW` only when the draft equals the last state
the *server* confirmed. Saving is explicit; a rejected save keeps every edit and
says "Not saved". A save the server accepts calls
`HomeViewModel.invalidateInternationalFeed()`, because `GET /feed/international`
applies the preferences server-side and anything already loaded was chosen under
the old rules.

Muted countries are validated with `CountryCode.normalised(_:)` before sending —
stricter than the server, which accepts any two letters and would happily store
`ZZ`.

The composer's scope picker is the same idea from the writing side, and it is
the composer's centrepiece rather than a toolbar setting. "My Country" may only
ever name the author's *own* verified country (the server rejects any other
`scope_country`), and a region is offered only when the author's country is
inside it — otherwise they would open a thread they could not reply in.
Unavailable rows are **shown and explained**, not hidden: an account with no
badge needs to learn that the flag comes from identity verification.

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
`ComposerServiceMock` ships 5: `success`, `threadFailsMidway` (two segments
post, the third does not — the case the UI must report as "posted 2 of 5"
rather than as a clean failure), `unverified`, `offline` and `rateLimited`.

`SearchServiceMock` ships 3: `populated` (searches the same fixture world the
mocked feed shows), `empty` and `offline`.

`PreferencesServiceMock` ships 4: `populated` (the filter on, two interests, one
muted topic, one muted country), `empty` (a new account's defaults), `offline`
and `saveFails` (loads fine, rejects every write — the state the screen must
report without losing the edits). It serves the real 20-topic taxonomy, because
twenty rows is the layout problem worth demoing, and it applies the same
full-replacement semantics the server does.

`-mockAuth` implies `-mockFeed`, `-mockComposer`, `-mockSearch` and
`-mockPreferences` unless the matching `-mock…Scenario` argument says otherwise,
because a mocked session carries no bearer token the live API would accept.

To see the whole app without a backend:

```bash
-mockScenario verified -mockFeedScenario populated -mockComposerScenario success
```

## Tests

441 total: 434 unit (23 opt-in, see below) and 7 XCUITests. The UI tests drive
sign-in → feed → composer → Explore → feed preferences against the mocks — no
network, no seeded account — and are the only tests that would catch a broken
route, an
unpresented sheet or an untappable button, since every view model passes in
isolation whether or not the screens are wired together.
They also attach screenshots, extractable from the result bundle:

```bash
xcodebuild ... test -only-testing:SilaUITests -resultBundlePath out.xcresult
xcrun xcresulttool export --path out.xcresult --id <payloadRef> --output-path shot.png --type file
```

### Opt-in live tests

Twenty-three tests (`LiveAPITests`, `LiveFeedTests`, `LiveComposerSearchTests`,
`LivePreferencesTests`) hit
the real deployed backend and skip unless you opt in — they are the only guard against the *server's* wire format
drifting away from the app's decoders:

```bash
TEST_RUNNER_SILA_LIVE_API=1 \
TEST_RUNNER_SILA_LIVE_EMAIL=you@example.com \
TEST_RUNNER_SILA_LIVE_PASSWORD='...' \
xcodebuild ... test -only-testing:SilaTests/LiveAPITests
```
The `TEST_RUNNER_` prefix is required — plain environment variables do not reach
the test process on the simulator.

## Layout

```
Sila/
├── App/           SilaApp, AppContainer (DI root), AppRouter, FeatureFlags, AppConfig
├── Core/          Network, Storage, Security (Keychain + biometrics), Analytics, DesignSystem
├── Modules/Auth/  Domain (models, protocols) · Data (AuthService, mock) · Presentation (screens)
├── Modules/Feed/  Domain (Post/UserSummary/FeedPage, presentation mappings)
│                  Data (FeedService, mock) · Presentation (MainTabView, HomeScreen,
│                  PostCardView, PostDetailScreen, Notifications)
├── Modules/Composer/  Domain (ComposeScope/ScopePicker, PostDraft, MentionDetector)
│                      Data (ComposerService, mock) · Presentation (ComposerSheetScreen,
│                      ScopePickerView, ReplyComposerBar)
├── Modules/Search/    Domain (TrendingTag, SearchServiceProtocol)
│                      Data (SearchService, mock) · Presentation (ExploreScreen)
└── Modules/Preferences/  Domain (TopicOption/TopicStance/FeedPreferences,
                          PreferencesSummary, MutedCountries)
                          Data (PreferencesService, mock)
                          Presentation (PreferencesScreen, view model)
```

`FeatureFlags` declares all 15 flags; `auth`, `feed`, `composer` and
`preferences` are on. Later phases add a folder under `Modules/` and flip their flag — they talk
to Auth only through `AuthSessionProtocol`, and get a bearer token only through
`AccessTokenProviding`. Turning `composer` off restores the Phase-3 stubs (the
`[+]` toast and the read-only reply bar) without touching the feed.

`PostCardView` is exported: the profile phase renders timelines with it
unchanged, and Explore's post results already do. Profile (Phase 7) and
Notifications remain honest stubs — a toast saying the feature arrives in a
later release — because no endpoint backs them yet and inventing one would
undermine the whole proposition.

Phase 4 deliberately ships **less** than its spec: the backend has no media
upload, poll or scheduling endpoint, so there is no `MediaPickerSheet`,
`PollComposerView` or `SchedulePickerView`, and no models for them. The spec's
Everyone/Verified/Following/Circle audience picker does not exist in this
product either; the scope picker replaces it. Threads are a client-side chain of
self-replies (`reply_to_post_id` → the previous segment), because there is no
thread object on the server — which is why a thread that fails partway reports
"posted 2 of 5" and keeps the rest of the draft.
