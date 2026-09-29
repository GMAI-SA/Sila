# Sila iOS (Social SA)

Phases 1 (Authentication), 3 (Feed), 4 (Composer & Search), 6 (Voice Rooms) and
7 (Profiles), plus contract v4's feed preferences and v5's account management,
safety and notifications. Swift 5.9 / SwiftUI, iOS 17+, MVVM + Clean
Architecture.

**One third-party dependency, deliberately.** The
[LiveKit Swift SDK](https://github.com/livekit/client-sdk-swift) (pinned to
`2.4.0` in `project.yml`) is the media stack behind Voice Rooms. It is the only
one, it was in the original blueprint, and it lives behind
`VoiceEngineProtocol` — exactly one file in the app imports it
(`Modules/Rooms/Data/LiveKitVoiceEngine.swift`), so every rule the feature has
to hold is testable without a WebRTC stack, a microphone or a media server.

> The pin is `2.4.0` rather than the latest: `2.5.0` and above call
> `MainActor.assumeIsolated`, which needs an iOS 17 availability annotation the
> SDK does not carry, and the package therefore does not compile under
> Xcode 15.2.

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
hard rule — and anything over the server's 40 MB (contract v27; it was 5) is
refused client-side rather than uploaded to earn a 413. Nothing under it is: a
full-resolution phone photo goes up as it is and the server shrinks it. The
document route never refuses a picture on the phone at all; each side is made
a JPEG of at most 1600 px before it leaves. The screen states what the server
does to the file: it is re-encoded to a 512×512 JPEG and **every EXIF tag,
including GPS coordinates, is dropped**. That is a privacy fact, not
housekeeping; nobody reads "set a photo" as a decision about their location
history.

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

## Voice rooms, and the four rules they run on

Base `/rooms`; `POST /rooms/{id}/join` answers `{room, url, token, role}` where
`url` is `wss://sila.gmai.sa/rtc` and `token` is a LiveKit credential.

**1. Scope governs who may SPEAK, never who may listen.** Every room is open to
every account — there is no field for "may this person enter", because everyone
may. `can_speak` and `speak_refusal` are computed server-side per request and
the client renders the refusal **verbatim**; nothing in `Modules/Rooms/` derives
the rule from a country code, because two implementations of one rule is one of
them being wrong. The list is therefore never filtered by speaking rights:
hiding a room somebody cannot speak in would turn a speaking rule into a
visibility rule.

**2. The token is the enforcement.** A listener's LiveKit token carries
`canPublish: false` and the media server drops their audio whatever the UI does.
So the microphone affordance is gated on `RoomRole.canPublish` and nothing else,
and a promotion is followed by a **re-join** rather than a flipped boolean — the
grant travels with the role, in a new token. `LiveRoomViewModel.refresh()`
notices the roster role changed, tears the connection down and joins again.
Unknown roles decode as `.listener`, and a missing `can_speak` reads as `false`:
both fail closed, because a mic button that cannot work is worse than none.

**3. Rooms are never recorded.** Said on the list, on the create sheet and
inside the room itself — where somebody reads it before they speak, not in a
settings page. There is no recording affordance anywhere in the module.

**4. Removal is per-room and is not a block.** `is_removed` /
`removed_from_room` mean one host, one room. `RoomCopy.removedFromRoom` says so
in words ("it isn't a block, nothing about your account has changed"), and
`RoomModelsTests` asserts that sentence stays different from the block message.

Two more things the module holds to:

* **Microphone permission is requested only when somebody takes the
  microphone** — never on entering a room. A listener needs no microphone, and
  asking anyway teaches people to deny by reflex. `MicrophonePermissionRequesting`
  is a seam so the denied path is testable.
* **Leaving always does both halves**: `POST /rooms/{id}/leave` *and* a LiveKit
  disconnect, from the Leave button, from a room that ended under you, and from
  `UIApplication.willTerminateNotification`. Backgrounding deliberately does
  *not* leave — `Info.plist` declares `UIBackgroundModes: [audio]` so a room
  survives somebody checking a message — it only stops the roster poll.

The audience picker is the composer's `ScopePicker`, unchanged, and the topic
list is the same `GET /topics` the feed preferences screen reads. Both are reuse
for the same reason: a second copy of the country rule, or a hard-coded
taxonomy, is a second thing to go stale.

## Vouching, and the two rules it keeps

Contract v24 (with §11, the details both sides give, and §12, the two warnings).
A verified member can stand behind somebody who has not verified yet; that
person reaches the app for 30 days, with a tag instead of a seal, and verifies
to keep it. `Modules/Vouching/` holds all of it; the rest of the app only reads
`AuthUser.standing` and `UserSummary.vouchedBy`.

**1. The tag is never the seal.** `if is_verified { seal; flag } else if
vouched_by { tag }` — `UserSummary` drops a tag that arrives beside
`is_verified`, and `VouchTag` checks again. It reads "vouched by @x · Country" /
«بتزكية @x · الدولة», the country as its name in text (the nationality both
sides gave), never a flag and never `country_code`. `SLVouchTag` is a chip with
a hairline border and no fill, deliberately the opposite of the filled seal. A
tap by anybody opens the explainer with **See @x**; a tap on your own tag opens
"Make it your own" and the verification flow over the app. Guests get the
explainer too. Post cards, quote cards (icon only), profile headers, room tiles
and the room's participant sheet, notification rows and search results carry it.

**2. What the voucher wrote never reaches the person.** The link carries a full
name, nationality and date of birth; whoever claims it gives their own, sent as
typed (the server folds case, spacing, tashkeel and letter variants). A
mismatch names *which* fields — "These don't match what @x entered: name, date
of birth" — never a value, and says how many tries the link has left; the third
closes it. Analytics carry the refusal code only.

Around those two:

* **Standing routes before status.** `vouched` reaches the feed whatever
  `verification_status` says (a refused document included); `none` with a
  pending claim is the wall, with "Waiting for @x to confirm it's you" and a way
  to withdraw the claim; the person's own verification stays one tap away.
  While a claim waits, "Check status" and the pull re-read `/auth/me` as well
  as `/verification/status` (the answer is on the account), the wall re-reads
  it every 20 seconds for five minutes, and a `vouch_*` push arriving in the
  foreground re-reads it at once.
* **Back at the wall, the wall says why.** `/auth/me` does not say why a vouch
  ended, so the wall reads `GET /me/vouch`'s `last_ended` (§15) on arriving with
  no vouch and again whenever a waiting claim goes (declined, lapsed,
  withdrawn). While nothing waits and nothing is under review, a calm card says
  "The vouch from @x has ended" (or "Your vouch has ended"), one reason — declined,
  not confirmed in time, the 30 days, withdrawn, taken off, the voucher can no
  longer vouch, a moderator (never which finding), or simply ended — and what is
  left: another voucher, or only verification when `vouch_again` names a
  refusal. The web's words, in the app's language only; the handle is one
  left-to-right piece. "Your vouch" with no live vouch shows the same card and
  "Verify your identity".
* **The limited tier is said where it bites.** A countdown above Home, a
  Messages tab that explains itself, "Verify your identity to host" before the
  room or event sheet, no voice recorder, no Groups row, "Verify your identity
  to vote" on polls, no Message button on a vouched profile. In a room a
  vouched listener listens, likes and sets reminders only: no hand, no
  reactions, no share, and a chat and question queue they read with the reason
  where the composer would be — the private line to the host included, which
  rides the media server's data channel past the server, so the model refuses
  to send it too (the server's grant now refuses it as well). Anything the
  server still refuses with `403 self_verification_required` offers
  verification — never the wall — through `SelfVerificationPresenter`, which
  presents over the top-most controller so the offer rises over whatever sheet
  the refusal came from.
* **The entry points appear only while vouching is open to the account.** The
  Profile row "Vouch for someone you know" (between Groups and Account) is drawn
  from `GET /vouching`: hidden on `vouching_not_open`, dimmed with the reason
  otherwise when the account cannot vouch now. A vouched account's row is "Your
  vouch" instead.
* **A link waits through sign-up.** `VouchInviteInbox` keeps the token (never a
  name) through registration, the email code and a relaunch, for 72 hours; the
  landing shows over whatever screen the person is on, and signed out it asks
  them to join first.
* **Both sides are warned before they commit** (§12): a card drawn in place,
  every time, before the voucher's details form and before the person's.
* **Push words come from the bundle.** `push.vouch_*` names nobody (the payload
  carries no name); a tap lands on the voucher's list or the person's own vouch,
  by the push's link, or by its kind when the link is missing.

## Video posts, and the upload that outlives the composer

Contract v28 (`docs/api-contract-v28-video.md` in the backend). Everything
lives in `Modules/Video/`; the composer, the post card and the feed only call
into it.

**Offered only where the server says so.** The composer's "Add a video"
appears only while `/auth/me` says `features.video_upload` — video on, the
account verified, posting not paused — and never in the reply bar. A cached
account from before v28 carries no flags and is offered nothing until the
server answers. Players need no flag: a post that carries a video plays.

**Refused on the phone, with the way out beside it.** A picked video over
185 seconds (three minutes and the server's five seconds of grace) is said to
be too long before a byte leaves the phone, with "Trim video" (the system's
`UIVideoEditorController`, held to three minutes) and "Use the first 3
minutes" next to it. Everything else is compressed on the phone
(`AVVideoPreparer`): `AVAssetExportSession` at 1280×720 or below, H.264, HDR
mapped to ordinary colour, location and device metadata dropped; a small
H.264 file goes up as it is.

**The upload outlives the sheet.** `VideoUploadCenter` holds every video on
its way, app-wide, and keeps each job on disk with its plan
(`Application Support/VideoUploads`, not backed up, readable after first
unlock so pieces go while the phone is locked). Uploading starts the moment
a video is picked, so it is usually there by the time the words are. Post
pressed before it is there hands the post to the center and closes the
composer: a strip above the feed says "Uploading… 42%", and the post is
written — once — when the video is complete, after a relaunch too. A job with
no post waiting belonged to a composer that is gone, and a relaunch lets it
go, here and on the server. Picking a video puts the keyboard away and
scrolls the composer to the video's card, so its progress and any words about
it are on screen.

**Both plan types, resumed silently.** `VideoUploader` asks where the upload
stands first (`GET status_url`, which lists every gap) and sends only what is
missing, every piece at once through a **background** `URLSession`
(`BackgroundVideoUploadTransport`, two on the wire), each from its own file,
so pieces keep going while the app is suspended; the app delegate reconnects
the session when the system wakes it. `chunked` sends 5 MiB chunks to the API
with `Content-Range`; `parts` asks `parts_url` for signed URLs twenty at a
time and sends 8 MiB parts straight to storage with no Authorization, asking
again when storage answers 403. A dropped connection, a timeout, a 5xx or
`503 video_upload_unavailable` waits 1, 2, 4 … 60 seconds with jitter (the
line says "Waiting for a connection"); `409 upload_incomplete` sends what is
missing at once; `410 upload_expired` starts a new plan with the same file
without a word. Only a refusal stops an upload, and says why in the app's
words.

**Nothing done with the phone meanwhile ends it.** Compressing holds the time
iOS lends an app in the background (`VideoBackgroundTime`), so switching to
another app while a video is "getting ready" does not stop it; if that time
runs out first, the export is stopped cleanly and compressed again from the
kept file when the app is back (`VideoUploadCenter.sceneDidBecomeActive()`),
still "getting ready", never "couldn't read". Only an export that fails on
screen with no sign of an interruption says the file cannot be read. Writing
the waiting post holds that time too, and two refusals are settled with
`GET /videos/{id}` before anything is shown: `409 video_used` after a try
whose answer was lost means that try was written, so its `post_id` is read
and the post shown, once; `409 video_removed` that was not a moderator's (the
server's daily sweep of videos nobody posted) sends the kept file up again as
a new video. Pieces an ended process left in `VideoUploads/pieces` are
removed when the app starts on the account.

**Visible to its author until it is ready.** The author's own post shows
"Preparing your video. Only you can see this post until it's ready.", "being
reviewed" for a held video (never why), the failure's words, or the
moderator's removal; `VideoStatusBoard` polls `GET /videos/{id}` every 2.5 s
for two minutes, then every 10 s, every 30 s while held, once per video
however many cards show it, and stops when it settles. Nobody else is ever
sent such a post.

**Playing.** Poster first, tap to play with sound; the master playlist
through `AVPlayer`, never a rendition. Muted autoplay only for the card most
in view (60%), and only on Wi-Fi that is neither expensive nor in Low Data
Mode, with the system's "Auto-Play Video Previews" on and Low Power Mode off
(`VideoAutoplayPolicy`); a muted video never interrupts somebody's music
(`.ambient`), and one playing with sound takes the playback session through
`AudioSessionArbiter`, which a room or a voice post takes back. One video
plays at a time. Full screen is the same player with a scrubber. Captions are
drawn by the app from the WebVTT tracks — the stream's own subtitles are
switched off — so they are named "Arabic (automatic)" / «العربية (تلقائية)»
wherever they are named, and an Arabic caption runs right to left on an
English phone.

**Words.** Every refusal of §10 and every state of §11 in English and Arabic,
in the app's language only, with Western digits like every number in the app.
Camera recording is not offered: the composer has no capture, and the
camera's privacy string promises the camera is used only for verification.

## Real time, and the socket nothing depends on

Contract v30 (`docs/api-contract-v30-realtime.md` in the backend). One
WebSocket, `wss://sila.gmai.sa/api/v1/realtime`, held by `RealtimeClient`
(`Modules/Realtime/`) over `URLSessionWebSocketTask`. It makes things arrive
sooner; it is never the only way to learn anything.

**When it is up.** In the foreground, with somebody signed in — at the wall
too, where `account.status` matters most — and not suspended
(`AppContainer.updateRealtime()`). The app going to the background closes it
(the push covers the time between), and so does signing out, before the token
goes. `.inactive` (the notification centre, the app switcher) changes nothing.

**The door.** Nothing in the handshake: no token in the URL, no header, no
cookie (the session is ephemeral) and no `Origin`. The access token is the
first frame. `ping` is answered `pong`; a socket that hears nothing for 80 s
is presumed dead and replaced. `reauth_required` is answered on the same
socket with a token *other than the one it holds*
(`RealtimeTokenProviding.renewedAccessToken(replacing:)` — a rotation another
call already made is used as it is, otherwise the single-flight refresh runs).

**Every close has one answer** (`RealtimeCloseDecision`), read from the
`error` frame the server sends before it, then from the close code: `4401`
renews the token and reconnects at once (with backoff if it happens again);
`account_suspended` stops and routes to the suspension screen through the same
`SuspensionMonitor` an HTTP `403` reaches; `account_deactivated` stops;
`1013` (`realtime_unavailable`, `busy`, `too_slow`) waits 30 s, then longer, up
to five minutes; `4429` waits a minute; everything else backs off 1, 2, 5, 10,
30, then 60 s, with up to 30 % jitter, starting again once a socket has stayed
up a minute. Only a server refusing the refresh (`401`) signs anybody out; no
token on the phone is somebody signing out already, and anything else is the
network.

**Nothing is replayed**, so every `ready` refreshes what is on screen once:
the open thread, the inbox or its badge, the notification badge, the wall.
Then the events:

* `message.new` — into the open thread once (matched on its id, so the
  viewer's own copy from another device slots into place and this device's is
  dropped), read at once while the thread is on screen, and later when it
  comes back if not; the inbox row moves to the top with its words and count,
  and a thread the list has never seen, or one that changed folders, is read
  from the server instead of guessed. A request never raises the badge.
  `alert` is decoded and nothing in the app makes a sound of its own: the push
  already does, exactly where `alert` is true.
* `message.read` — the other person's: every message of the viewer's sent by
  then is read, and **Read** / «تمت القراءة» sits under the latest once it is.
  Never in a request: the requests folder promises that the sender cannot see
  whether it was read. The viewer's own, from any device: the row's count and
  the badge clear.
* `message.deleted` — shown as removed, with no text, as the thread does.
* `typing` — **typing…** / «يكتب…» under the thread and **Noura is typing…** /
  «نورة يكتب…» in place of the row's preview, from one `TypingBoard` so the two
  never disagree; it ends when `expires_in` runs out unrenewed, on
  `active: false`, on that person's message, and when the socket goes. A
  thread just opened asks `GET /conversations/{id}/typing`. The viewer's own
  typing goes out at most every two seconds while the field changes
  (`TypingThrottle`), `active: false` once when it is cleared or the thread is
  left, nothing after sending (the server ends it), never in a request, and
  never again in a thread the server refused it for.
* `notification.new` — the Alerts badge **is** `unread_count`, never counted
  up here. The list is left alone; pulling reads it.
* `account.status` — `AuthSession.adoptAccount(_:)` takes the account exactly
  as `/auth/me` would give it and routes on it: approved goes to the feed,
  refused to the rejected screen, a vouch claimed, confirmed, declined or ended
  moves the wall at once. The wall's own polls stay as they were, as the
  fallback.

**Without it** — Redis down, the socket refused, the phone offline — every
screen refreshes exactly as before (on opening, on pulling, on coming back).
`-noRealtime` turns the socket off entirely; `-mockRealtime replies|incoming|
unavailable` plays it in-process (`RealtimeServerMock`, see below).

## App Attest, and the submission it never holds up

Contract v32 (`docs/api-contract-v32-app-attest.md` in the backend). The
server's automatic approval only trusts a document submission when Apple's
App Attest proves it came from the genuine Sila app on a real Apple device,
over exactly the pictures uploaded. `AppAttestor`
(`Modules/Verification/Data/`) does the device's half, behind
`AppAttestProviding` so every rule is tested without a Secure Enclave:

* **One key per account per install.** `generateKey`, then `POST
  /device/attest/challenge`, `attestKey` over the SHA-256 of the challenge's
  UTF-8 bytes, `POST /device/attest`. The key's id is kept in the keychain
  under the account's id (`appattest.key.<id>`, this device only), so a
  second account on the phone gets a key of its own. The flow screen readies
  the key while the person is still at the camera.
* **Each submission is signed.** `POST /device/assert/challenge {"key_id"}`
  right before the upload, then `generateAssertion` over the SHA-256 of
  `AppAttestClientData`: the challenge, the form's strings exactly as sent and
  the SHA-256 of every picture as uploaded, in the server's part order, as
  JSON with sorted keys and no escaped slashes. The form and the client data
  are built from one list of fields and parts (`DocumentSubmission.textFields`
  and `.imageParts`), and a test reads the multipart body back and rebuilds
  the bytes the server's way. The form carries `app_attest_key_id` and
  `app_attest_assertion`.
* **A key the server let go is replaced.** The assertion challenge carries
  the key's id, and `404 key_unknown` says the server no longer holds it: the
  key is dropped and a new one attested, once, before anything is signed.
  Opening the document flow asks the same once a launch, so the new key is
  ready before the person reaches the submit. Still one key per account.
* **Only a refusal pauses.** A `400 challenge_stale` (the challenge expired
  while the phone was locked, another device replaced it, or it was spent) is
  asked again at once with a fresh challenge — the same key where Apple
  attests it again, else one new key. A lost answer to `POST /device/attest`
  asks the server whether it kept the key before attesting it again (and
  after a relaunch, if it comes to that). Both stop after
  `AppAttestor.attestationRounds` (3) challenges and try again next time.
  Only `400 attestation_invalid` discards the key and makes no new one on
  this install for a day; a `429` or any other answer keeps the key.
* **Never in the way.** Unsupported (the simulator, older devices), signed
  out, Apple out of reach, the server refusing, a slow network past fifteen
  seconds: the submission goes without, and a person reviews it. Apple's
  `serverUnavailable` keeps the key for later; any other App Attest error
  discards it; a key the Secure Enclave no longer has is replaced once, on
  the spot. Every key made counts toward Apple's count of keys on the phone,
  so none is made that is not needed. `device_attestation` events say what
  happened (`step`: `attest`, `status` or `assert`; `result`; `reason`) and
  nothing else.

The entitlement `com.apple.developer.devicecheck.appattest-environment` is
`$(APP_ATTEST_ENVIRONMENT)`: `development` in Debug, `production` in Release
(`project.yml`). TestFlight and the App Store use production whatever it
says. The App ID needs the **App Attest** capability for a provisioning
profile to carry it.

## The session, and what it leaves on the phone

The token pair and the cached account live in the Keychain
(`WhenUnlockedThisDeviceOnly`). Ten rules keep the session from ending when it
should not, and from outliving itself when it should, each asserted in tests:

* **One refresh at a time** (`TokenRefreshTests`). The server revokes a refresh
  token on first use, and after half an hour in the background the feed, the
  badges, push and telemetry all find the access token expiring together.
  `AuthService.refreshToken` is single-flight (`TokenRefresher`): callers that
  arrive while a refresh runs share it, a caller holding an already-rotated
  token gets the stored pair, a refusal only wipes the store if the refused
  token is still the stored one, and a refresh that lands after sign-out does
  not bring the session back.
* **Only a refusal signs out** (`OfflineRestoreTests`). A cold launch that
  cannot reach the server — offline, a lift, a deploy answering `502`, a
  captive portal, a proxy's or firewall's error page — keeps the session,
  opens on the cached account with an offline strip, and keeps retrying
  `/auth/me` (with a backoff, and at once when the app returns to the
  foreground) until it answers. A `401` is the only answer that ends the
  session; a `403` in the API's own words (suspended, deletion pending) keeps
  it and lets the screens route.
* **A launch waits seconds, not forty-five** (`LaunchDeadlineTests`,
  `OfflineLaunchJourneyUITests`). Offline, the client waits for the network
  to come back (`AppConfig.connectivityWait`, 45 s) before a request fails,
  and the splash used to wait with it. With an account cached, the server now
  has `AppConfig.launchDeadline` (3 s) to answer; then the app opens on the
  cached account with the offline strip, and the check already asked goes on
  in the background. Its answer is acted on when it comes — the session
  catches up, re-routes, or ends on a `401` — and only if it cannot reach the
  server either do the retries begin. An answer inside the deadline routes at
  once, as before; a late answer for a session replaced meanwhile is ignored,
  and one that lands after sign-out cannot write the account back.
* **Sign-out ends the server's session too** (`SignOutTests`,
  `LiveSessionsTests`). `/auth/logout` carries the refresh token in its body
  beside the access token in the header (contract v26 §1), so an access token
  the server can no longer read still ends its session, rather than leaving a
  thirty-day refresh token good on the server after the phone forgot it.
* **Sign-out waits seconds, not forty-five** (`SignOutTests`,
  `PushWithdrawalDeadlineTests`, `OfflineSignOutJourneyUITests`). Offline,
  withdrawing the push registration and `/auth/logout` would each wait for a
  connection (`AppConfig.connectivityWait`) before failing, and sign-out
  waited with them. Each now has `AppConfig.signOutDeadline` (3 s) to be
  answered; then the request is cancelled and the phone is wiped regardless.
  The server's session is then left to expire on its own, as it was when the
  forty-five seconds ran out.
* **The password travels with the code** (`CodeScreenPasswordTests`,
  `LiveSessionsTests`). The code screen after registering sends the
  registration's password with the code, and the one after a sign-in that
  answered `email_unverified` sends the password just typed (contract v26
  §7.1): the code that confirms an address decides its password, not a
  stranger's registration of the same address. `AppRouter` holds it in memory
  for that one screen — never in the route, never on disk — and a password the
  server would refuse beside a code (over 72 bytes, from before that rule) is
  not sent. A relaunch onto an unconfirmed session sends the code alone.
* **Nothing the API answers is cached** (`SessionLeftoversTests`). The API
  client's session has no `URLCache`, so `/auth/me` (email, verified name),
  messages and notifications never reach `Cache.db`.
* **Sign-out sweeps** — the shared URL cache (images, GIFs) and the account
  export go with the Keychain items, whether the person signed out or the
  server ended the session (`SessionLeftovers`, called from
  `AuthTokenStore.clear()`).
* **The export does not linger.** It is written with complete file protection
  and removed once the share sheet reports it went somewhere, when Account
  closes, when deletion is requested, and at sign-out.
* **A reinstall starts signed out** (`ReinstallTests`). iOS keeps Keychain
  items when the app is deleted; the store keeps an install marker in
  UserDefaults and, on the first read of an install without one, wipes the
  Keychain first. An update from a build before the marker is recognised by
  the last-email entry every sign-in writes, and a locked phone decides
  nothing.

The Terms and Privacy sheets (`LegalDocumentSheet`) load only their own page,
with page scripts off and nothing stored, and show it only once it is
confirmed to be a document; the web app (what the host answers for a path it
does not know), an error, or nothing at all is shown as "Document unavailable"
(`LegalDocumentTests`, `LegalSheetJourneyUITests`).

## Running without a backend

```bash
# in the scheme's launch arguments, or via xcodebuild
-mockAuth -mockScenario pendingReview
-mockFeedScenario unverifiedNoCountry
```
`AuthServiceMock` ships 10 scenarios covering every verification-wall state plus
`screenedOut` (a rejection by the document pre-screen), `emailUnverified`,
`invalidCredentials`, `otpAlwaysInvalid`, `offline` and `stalled` (every call
waits the client's forty-five seconds for a connection, then fails). The mocks
never write the keychain, so `-mockStoredSession` (debug builds) opens the app
on a verified account's stored session, in memory — with `-mockScenario
stalled`, the offline cold launch.

`FeedServiceMock` ships 5: `populated`, `empty`, `unverifiedNoCountry` (the
409 `no_country` explainer on My Country), `offline` and `paginationExhausted`
(a first page that promises more and a second that delivers nothing).
`ComposerServiceMock` ships 5: `success`, `threadFailsMidway` (two segments
post, the third does not — the case the UI must report as "posted 2 of 5"
rather than as a clean failure), `unverified`, `offline` and `rateLimited`.

`SearchServiceMock` ships 3: `populated` (searches the same fixture world the
mocked feed shows), `empty` and `offline`.

`GifServiceMock` ships 4, picked with `-mockGifScenario`: `populated` (the
provider answers), `libraryOnly` (no provider, a few GIFs already shared),
`empty` (no provider and nothing in the library — production today, where the
GIF button and the floating button's GIF choice are hidden; see
`GifAvailability`) and `offline`.

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

`RoomsServiceMock` ships 8: `populated` (three live rooms and two scheduled),
`empty`, `listenerOnly` (every room refuses the mic with a scope reason — the
state the whole feature turns on), `hosting` (the viewer hosts the first room,
so the host controls are reachable), `removed` (a join refused with
`removed_from_room`), `offline`, `writesFail` and `vouched` (a vouched
listener everywhere, beside another vouched listener whose tile carries the
tag — what `-mockScenario vouched` serves unless `-mockRoomsScenario` says
otherwise). `-mockRooms` implies
`-mockVoiceEngine`, because a mocked join hands back a token no real media
server would accept. `VoiceEngineMock` **enforces** the rule rather than
recording it: a connection made with `canPublish: false` refuses to open the
microphone, exactly as the media server would.

`VouchingServiceMock` ships 4: `voucher` (a claim to confirm, a live vouch with a
moderator's question, one ended, one open link), `notOpen` (the flag is off: no
entry points), `struck` (one strike: the right to vouch is gone) and `empty`. Its
link `mock-khalid-2026-link` was written by @noura for Khalid Al-Harbi, Saudi,
born 12 April 1995: the claim plays the server's matching, mismatches and the
third that closes it. `AuthServiceMock` adds `vouched`, `vouchPending` and
`vouchEnded` (back at the wall: @noura declined the claim, said by `last_ended`);
`NotificationsServiceMock` adds `vouching` (each vouching notice, with and
without `vouch_role` — what `-mockScenario vouched` serves unless
`-mockNotificationsScenario` says otherwise); `FeedServiceMock.vouched` (@khalid, vouched for by
@noor · Saudi Arabia) is in the mocked People search.
`-openLink URL` opens a sila.gmai.sa link on launch, as a tap would:

```bash
-mockScenario unstarted -openLink https://sila.gmai.sa/vouch/mock-khalid-2026-link
```

`VideoServiceMock` ships 9, picked with `-mockVideoScenario` (`-mockAuth` and
`-mockComposer` imply `-mockVideo`): `success`, `parts` (signed targets, then
parts), `dropsOnce` (the connection drops half way through the second piece),
`expiresOnce` (the first complete answers `410`), `held`, `failed`,
`notAllowed`, `offline` and `slow` (small pieces three seconds apart, to switch away
or quit mid-upload). It assembles the pieces it is sent into one file, which
is what plays once "ready", and keeps its state on disk so a relaunched app
finds it. In debug builds `-mockVideoPick short|portrait|long|big` makes "Add a video"
pick a sample made on the simulator instead of opening Photos,
`-resetVideoUploads` starts with no upload kept, and `-videoAutoplay on|off`
decides autoplay instead of the Mac's network.

`RealtimeServerMock` speaks contract v30 over an in-memory socket and plays
@noura in the mocked thread (`-mockRealtime <scenario>`; `-mockAuth` and
`-mockMessages` imply it): `replies` (the default — she reads what the viewer
sends, types, and answers), `incoming` (the first time the inbox is read she
types, then writes, and a notification lands) and `unavailable` (every socket
is refused `1013`: the app carries on over HTTP alone). Every frame goes
through the same client, decoder and view models a real socket's would.

`-mockAuth` implies `-mockFeed`, `-mockComposer`, `-mockSearch`,
`-mockPreferences`, `-mockAccount`, `-mockProfile`, `-mockNotifications`,
`-mockSafety`, `-mockRooms`, `-mockVouching` and `-mockMessages` unless the matching
`-mock…Scenario` argument says otherwise, because a mocked session carries no bearer token the
live API would accept — and in the account module's case because the live
version of the deletion demo costs a real account.

To see the whole app without a backend:

```bash
-mockScenario verified -mockFeedScenario populated -mockComposerScenario success
```

## Tests

1,819 total: 1,743 unit (88 opt-in, see below) and 76 XCUITests (59 journeys, 16
reference screenshots and one live sign-in). The UI tests drive
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
`LivePreferencesTests`, `LiveAccountTests`, `LiveProfileTests`,
`LiveNotificationsTests`, `LiveSafetyTests`, `LiveRoomsTests` and
`LiveRealtimeTests` hit a real
backend and skip unless you opt in — they are the only guard against the
*server's* wire format drifting away from the app's decoders.

**They run against the staging API, never production.** Production runs with
dev mode off, so `/api/v1/dev/*` does not exist there, and nothing a test does
belongs on it. Staging answers on `127.0.0.1:8101` on the server and is reached
through an SSH tunnel; `Tests/LiveTarget.swift` reads its origin from
`SILA_API_ORIGIN` (the same name the web repo's live specs read), points every
service at it, and fails the run — loudly, not as a skip — when live tests are
opted into without it or with a `gmai.sa` origin:

```bash
ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
TEST_RUNNER_SILA_LIVE_API=1 \
TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
TEST_RUNNER_SILA_LIVE_EMAIL=you@example.com \
TEST_RUNNER_SILA_LIVE_PASSWORD='...' \
xcodebuild ... test -only-testing:SilaTests/LiveAPITests
```
The `TEST_RUNNER_` prefix is required — plain environment variables do not reach
the test process on the simulator. The account must exist **on staging**.
Plain HTTP to `127.0.0.1` needs no ATS exception.

`LiveSignInUITests` does the same through the real UI: it launches the app with
`-apiOrigin <origin>`, which only a **debug** build reads
(`AppConfig.apiBaseURL(arguments:)`); release builds always talk to
`apiBaseURLString`, and an origin that is not HTTPS or loopback HTTP makes every
request fail rather than fall back to production.

They are all **non-destructive**. `LiveAccountTests` never changes a password
(which revokes every session, this one included), never sends real mail and
never completes a deletion; `LiveProfileTests` never touches the live account's
own profile fields at all — the only state it changes is whether that account
follows one seeded demo person (`yuki`), and `tearDown` restores it whichever
way round it started. Both provoke the *refusals* instead, which are safe
precisely because they fail.

`LiveRoomsTests` is the one exception, and a bounded one: it **does** create
rooms, because a room is the only way to observe a real join token and rooms are
cheap and end-able. Every room it opens is registered for cleanup *before* the
assertion that might fail, `tearDown` leaves every room it joined and ends every
room it created, and it then re-reads each one to assert it is no longer live —
so a silent failure to clean up is a failed test rather than a live room on a
list with nobody in it. It does not remove anybody from a room: a removal needs
a second real account and leaves a per-room ban this contract has no endpoint
to lift.

`LiveVerificationPolishTests` (contract v25) needs no account: each run
registers a disposable `itest-ios-…@example.com` account through staging's dev
routes (`LiveTarget.dev`, which refuses to call the shared test-user purge). It
submits flat colour swatches — nothing of a person — withdraws them (so nothing
waits in the moderators' queue), and opts one account into the pre-screen to
watch it turn a swatch away:

```bash
TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
xcodebuild ... test -only-testing:SilaTests/LiveVerificationPolishTests
```

`LiveSessionsTests` (contract v26) needs no account either: it registers a
disposable address twice — a stranger's registration, then the owner's — has
the owner resend and type the code through the app's own view models, and
checks the owner's password is the account's and the stranger's is refused;
does the same through a sign-in that answers `email_unverified`; and signs out
with an access token the server cannot read, then checks the refresh token no
longer works.

`LiveVideoTests` (contract v28) needs no account either: a verified disposable
account uploads a three-second test pattern made on the simulator, compressed
by the app's preparer and sent through a background session of its own name;
the screen's verdict is set to "ok" through staging's dev route; the post is
written before the video is ready, watched to ready, and its stream, poster
and captions checked, then deleted (which deletes every file of the video).
A twelve-megabyte sample is resumed after its first chunk, and the refusals
are read in the app's words.

`LiveRealtimeTests` (contract v30) needs no account either: three disposable
accounts on staging, the app's own `RealtimeClient` on the real transport to
`ws://127.0.0.1:8101/api/v1/realtime`. Two people who follow each other talk:
the message arrives as the thread returns it, the sender's other device hears
it without an alert, typing reaches the other's open `ChatViewModel` and ends
with the message, the read receipt comes back and a deletion leaves the other
screen. The third waits at the wall, hears its own verification through
`account.status` and routes to the feed on it, then follows, and the other's
badge is the server's count. A bad token is refused `unauthorized` and the
adapter reads the server's own close code, `4401`:

```bash
TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
xcodebuild ... test -only-testing:SilaTests/LiveRealtimeTests
```

`LiveVouchingTests` (contract v24) works the same way, with disposable accounts
only: two made vouchers through the dev hook (verified forty days ago — the
thirty-day rule), two people. It mints a link, reads it through the app's own
link parser (staging's link is mapped onto the app's web origin first, since
staging mints on its own), claims it after a mismatch, confirms, checks the
tag, the thirty days and the limited tier, and takes the tag off again; the
second link is closed by three mismatches. Nothing is left live.

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
├── Modules/Rooms/        Domain (VoiceRoom/RoomRole/RoomJoin/RoomParticipant,
│                         VoiceEngineProtocol + MicrophonePermissionRequesting,
│                         RoomCopy)
│                         Data (RoomsService, mock, LiveKitVoiceEngine — the one
│                         file that imports a third-party library — VoiceEngineMock)
│                         Presentation (RoomsScreen, CreateRoomSheet,
│                         LiveRoomScreen, three view models)
├── Modules/Vouching/     Domain (Standing, VouchedBy, VouchState, Vouch, VouchInvite,
│                         VouchingOverview, VouchDetails, VouchCopy)
│                         Data (VouchingService, mock, VouchInviteInbox)
│                         Presentation (the voucher's list, the link sheet, the
│                         claim, the person's own vouch, the tag, the tier)
├── Modules/Video/        Domain (PostVideo, the upload plan and its arithmetic,
│                         VideoCopy, WebVTT, VideoAutoplayPolicy)
│                         Data (VideoService, BackgroundVideoUploadTransport,
│                         VideoUploader, AVVideoPreparer, VideoUploadStore, mock,
│                         SampleVideoFactory in debug builds)
│                         Presentation (VideoUploadCenter, VideoStatusBoard, the
│                         player and full screen, the composer's card, the strip
│                         of posts waiting above the feed)
├── Modules/Realtime/     Domain (RealtimeEvent and the frames, RealtimeSocket,
│                         RealtimeCloseDecision, RealtimeBackoff)
│                         Data (RealtimeClient, URLSessionRealtimeSocket,
│                         RealtimeServerMock + InMemoryRealtimeSocket)
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
