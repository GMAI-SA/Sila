# Sila iOS (Social SA)

Phases 1 (Authentication), 3 (Feed), 4 (Composer & Search) and 7 (Profiles),
plus contract v4's feed preferences and v5's account management. Swift 5.9 /
SwiftUI, iOS 17+, MVVM + Clean Architecture, zero third-party dependencies.

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
`api-contract-v4-interests.md` (`/topics`, `/me/preferences`),
`api-contract-v5-account.md` (`/me/account`, credentials, export, deletion) and
`infra/DEPLOY.md`. The profile routes (`/users/{handle}`, `…/posts`,
`…/follow`) are part of the v2 feed/social contract.

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

## Account management, and the three rules it is built on

`AccountScreen` is the profile, credential, export and deletion surface. Three
rules shape it, and each is asserted in tests rather than left to a code review.

* **A session is not consent.** Every credential change — password, email,
  phone, deletion — carries the current password, because a bearer token proves
  somebody signed in once, not that whoever is holding the phone now is the
  account holder. Each one lives in its own sheet that asks for it first.
  Removing a phone number needs it too: the rule does not bend for the changes
  that happen to be subtractive.
* **`403 account_deactivated` is a state, not an error.** Any call can answer
  it, and every one of them routes to `AccountRecoveryScreen` — which offers
  **Cancel deletion** — rather than publishing an error string. A generic alert
  with a Retry button would loop somebody through the same 403 until the purge
  ran and the choice stopped existing. `GET /me/account` is one of only two
  endpoints a deactivated account may call, so it answers `200` with the
  deletion timestamps set and the recovery screen appears on the way in.
* **The phone number is never rendered as verified.** No tick, no green, no
  "confirmed". There is no SMS provider in this deployment, so `phone_verified`
  is always false — and `Account` does not decode it at all, which makes it
  structurally impossible for a view to bind a checkmark to it. A unit test
  fails the moment the property comes back.

Deletion is gated on two separate deliberate acts: the current password must be
non-empty and the typed word must equal `DELETE` byte for byte — case-sensitive,
with no trimming, so `"delete"` and `"DELETE "` do not pass. The field
deliberately does not auto-capitalise. All four consequences are stated before
the button can be pressed (deactivated immediately, every session signed out,
posts leave every feed, recoverable for 30 days), and `DeletionDisclosure` holds
that wording as constants so the copy is asserted rather than drifting.

Avatars go through `PhotosUI.PhotosPicker` — zero third-party dependencies is a
hard rule — and anything over 5 MB is refused client-side rather than uploaded
to earn a 413. The screen states what the server does to the file: it is
re-encoded to a 512×512 JPEG and **every EXIF tag, including GPS coordinates, is
dropped**. That is a privacy fact, not housekeeping; nobody reads "set a photo"
as a decision about their location history.

The email change is two steps and says out loud that the code goes to the **new**
address. If the address is claimed while the code sits in an inbox the server
refuses at confirm time with `email_taken`; the client sends the form back to the
start and says the address is unchanged, because the code is spent.

### What the v5 contract actually does, versus what it documents

* `PATCH /me/profile` answers a **`UserSummaryOut`**, not the account — no `bio`,
  no `email`, no `phone`. `AccountService` follows the write with a read rather
  than folding a partial response into the local copy.
* `avatar_url` is **root-relative** (`/api/v1/media/avatars/…`). Decoded straight
  into a `URL` it is unloadable, so `Account` keeps the string and resolves it
  through `AppConfig.mediaURL(_:)`. `AuthUser.avatarURL` still has this bug.
* A wrong current password is **`403 invalid_credentials`**, which shares its
  status with `403 account_deactivated`. Routing keys on the *code*, never the
  status.
* `POST /me/password` revokes **every** refresh token, this device's included —
  so "signs other sessions out" understates it. The success panel says the
  current session will need the new password too, and offers to sign out now.
* `POST /me/delete` validates `confirm` **before** the password, so a bad
  confirmation word is reported as `confirmation_required` even when the password
  is also wrong.
* `POST /me/email/request` can answer `409 email_taken` and `502
  email_delivery_failed`; the latter is undocumented and falls through to
  `APIErrorCode.unknown`, which shows the server's own message.

## Profiles, and the two things they must not overclaim

`Sila/Modules/Profile/` is one person's page: the header, their posts, and the
one button that changes the viewer's relationship to them. It reuses rather than
re-declares — `UserSummary` is the same value that sits beside a post,
`/users/{handle}/posts` decodes into the same `FeedPage` the four feeds use, and
editing your own profile stays in `Modules/Account/`, which the page links to
instead of growing a second editor.

**The follower count is never counted locally.** A tap predicts `±1` so the
button moves under the finger, and then the number is *replaced* by the one the
response carries. `POST` and `DELETE /users/{handle}/follow` are both
idempotent — following twice succeeds and changes nothing — so a local `+1` is
simply wrong whenever another device has already acted. `Profile.reconciled(with:)`
is the only thing allowed to set the count after a tap.

**The timeline is not everything the person has written.** The server filters
`reply_to_post_id IS NULL`, so replies appear in neither the list nor
`post_count`. The screen says so under the heading (`ProfileCopy.timelineScope`)
whether or not the list happens to have rows, because the exclusion is a fact
about the endpoint rather than about today's contents.

Two smaller rules follow from the product:

* **No follow button on your own page** — not a disabled one. The server answers
  `400 self_follow`, so a greyed-out control would be an affordance for
  something that cannot happen. It is replaced by a route into `AccountScreen`.
* **A 404 gets no Retry.** An unknown *or deactivated* handle answers
  `404 user_not_found`, and the two are indistinguishable on purpose — an error
  that admitted the second would leak the existence of an account that asked to
  be gone. The screen states it plainly and offers nothing to press, because
  pressing it could only fail again.

Tapping an author — in the feed, on a post's detail screen, in Explore's People
results, or as an `@mention` in any post's text — opens that person. Each tab
keeps its own `NavigationStack` path, so following the chain from a search result
never rearranges the home feed's history.

### What the profile routes actually do, versus what is documented

* `post_count` is computed with **the same `reply_to_post_id IS NULL` filter** as
  the timeline, so on this deployment the count and the pageable rows agree. It
  is still not "how much this person has written", and neither number is labelled
  that way.
* `404` carries the code **`user_not_found`**, which appears in no contract file.
  Without it the raw "No account with that handle" would have been shown to the
  user; `APIErrorCode.userNotFound` now maps it.
* `limit` is validated `ge=1, le=50` and answers **422** outside that range
  rather than clamping. FastAPI's validation body is a shape this client does not
  model, so `ProfileService` clamps before sending.
* Both follow verbs return the authoritative `follower_count`, and neither is an
  error when it changes nothing — the client depends on both facts.

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

`AccountServiceMock` ships 5: `populated`, `fresh` (a new account with nothing
filled in), `offline`, `pendingDeletion` (the grace period — the state the
recovery screen exists for, and otherwise only reachable by deleting a real
account) and `wrongPassword`. It reproduces the server's refusals rather than
saying yes to everything, including the 403 that `get_current_user` raises for
every endpoint except `/me/account` and `/me/delete/cancel`.

`ProfileServiceMock` ships 7: `populated`, `unverified` (no checkmark and
therefore no country — the badge must render nothing), `empty`, `notFound` (the
dead end), `offline`, `followFails` and `followedElsewhere` — where the server's
follower count comes back **two** higher than the local `+1` predicted, because
a second device followed too. That last one is the entire reason the client
reconciles instead of counting. Its people and posts are `FeedServiceMock`'s,
so an author tapped in the mocked feed opens the same person.

`-mockAuth` implies `-mockFeed`, `-mockComposer`, `-mockSearch`,
`-mockPreferences`, `-mockAccount` and `-mockProfile` unless the matching
`-mock…Scenario` argument says otherwise, because a mocked session carries no bearer token the
live API would accept — and in the account module's case because the live
version of the deletion demo costs a real account.

To see the whole app without a backend:

```bash
-mockScenario verified -mockFeedScenario populated -mockComposerScenario success
```

## Tests

639 total: 623 unit (46 opt-in, see below) and 16 XCUITests. The UI tests drive
sign-in → feed → composer → Explore → feed preferences → account → profile
against the mocks — no network, no seeded account — and are the only tests that would catch a
broken route, an unpresented sheet or an untappable button, since every view
model passes in isolation whether or not the screens are wired together.
`AccountJourneyUITests` is the one that drives the deletion gate through the real
UI: it asserts the confirm button stays inert with a password alone, with a
lower-case word, and with a partial one. `ProfileJourneyUITests` is the one that
would notice a tapped author going nowhere, a follow button appearing on the
viewer's own page, or a Retry being offered for a handle that cannot exist.
They also attach screenshots, extractable from the result bundle:

```bash
xcodebuild ... test -only-testing:SilaUITests -resultBundlePath out.xcresult
xcrun xcresulttool export --path out.xcresult --id <payloadRef> --output-path shot.png --type file
```

### Opt-in live tests

`LiveAPITests`, `LiveFeedTests`, `LiveComposerSearchTests`,
`LivePreferencesTests`, `LiveAccountTests` and `LiveProfileTests` hit
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

They are all **non-destructive**. `LiveAccountTests` never changes a password
(which revokes every session, this one included), never sends real mail and
never completes a deletion; `LiveProfileTests` never touches the live account's
own profile fields at all — the only state it changes is whether that account
follows one seeded demo person (`yuki`), and `tearDown` restores it whichever
way round it started. Both provoke the *refusals* instead, which are safe
precisely because they fail.

## Layout

```
Sila/
├── App/           SilaApp, AppContainer (DI root), AppRouter, FeatureFlags, AppConfig
├── Core/          Network, Storage, Security (Keychain + biometrics), Analytics, DesignSystem
├── Modules/Auth/  Domain (models, protocols) · Data (AuthService, mock) · Presentation (screens)
├── Modules/Feed/  Domain (Post/UserSummary/FeedPage, presentation mappings)
│                  Data (FeedService, mock) · Presentation (MainTabView, HomeScreen,
│                  PostCardView, PostDetailScreen)
├── Modules/Composer/  Domain (ComposeScope/ScopePicker, PostDraft, MentionDetector)
│                      Data (ComposerService, mock) · Presentation (ComposerSheetScreen,
│                      ScopePickerView, ReplyComposerBar)
├── Modules/Search/    Domain (TrendingTag, SearchServiceProtocol)
│                      Data (SearchService, mock) · Presentation (ExploreScreen)
├── Modules/Preferences/  Domain (TopicOption/TopicStance/FeedPreferences,
│                         PreferencesSummary, MutedCountries)
│                         Data (PreferencesService, mock)
│                         Presentation (PreferencesScreen, view model)
├── Modules/Account/      Domain (Account, ProfileDraft, PhoneNumber,
│                         AvatarUpload, DeletionConfirmation/Disclosure,
│                         AccountRouting)
│                         Data (AccountService, mock)
│                         Presentation (AccountScreen, sheets, recovery screen)
├── Modules/Profile/      Domain (Profile, FollowResult, ProfileCopy,
│                         Handle normalisation)
│                         Data (ProfileService, mock)
│                         Presentation (ProfileScreen + host, view model)
└── Modules/Notifications/ Domain (UserNotification/NotificationKind/Page,
                           NotificationPreferences, NotificationCopy)
                           Data (NotificationsService, mock)
                           Presentation (NotificationsScreen, settings sheet)
```

`FeatureFlags` declares all 16 flags; `auth`, `feed`, `composer`, `preferences`,
`account` and `profile` are on. Later phases add a folder under `Modules/` and flip their flag — they talk
to Auth only through `AuthSessionProtocol`, and get a bearer token only through
`AccessTokenProviding`. Turning `composer` off restores the Phase-3 stubs (the
`[+]` toast and the read-only reply bar) without touching the feed.

`PostCardView` is exported, and Phase 7 took it up as promised: profile
timelines and Explore's post results render it unchanged. Turning `profile` off
removes every route into a profile and restores `ProfileStubScreen` as the
tab — the flag has a real off state, and that screen still carries account
settings and sign-out.

Notifications is real now that `/notifications` is deployed: five kinds, each
with its own sentence, paged by the server's cursor and badged with the server's
own `unread_count` rather than a number counted from the rows on screen. Nothing
is marked read by arriving — only the explicit "Mark all read" and opening a
single row — because `POST /notifications/read` has no inverse. A notification
whose post has since been deleted keeps its row and loses only its excerpt: the
event still happened. The five on/off switches live in `/me/preferences` beside
the feed settings and are edited from the list they govern.

Phase 4 deliberately ships **less** than its spec: the backend has no media
upload, poll or scheduling endpoint, so there is no `MediaPickerSheet`,
`PollComposerView` or `SchedulePickerView`, and no models for them. The spec's
Everyone/Verified/Following/Circle audience picker does not exist in this
product either; the scope picker replaces it. Threads are a client-side chain of
self-replies (`reply_to_post_id` → the previous segment), because there is no
thread object on the server — which is why a thread that fails partway reports
"posted 2 of 5" and keeps the rest of the draft.
