# Round-2 security findings for the apps fix lane

## CA-1 [medium] Tapping a room link on iOS or Android joins the room straight away, with no confirm step, so the person shows up to the host by verified identity

Where: iOS: Sila/App/SilaApp.swift:26 (onOpenURL) -> AppContainer.swift:731 -> MainTabView.swift:1165/1473 (openRoomFromNotification pushes .room) -> LiveRoomScreen.swift:210 `.task { await viewModel.start() }` -> LiveRoomViewModel.swift:274 `service.join(roomId:)`. Android: MainActivity.kt:119-121 (ACTION_VIEW to PushDeepLink.parse) -> MainTabScaffold.kt:924-926 RoomOpenBus.request -> MainTabScaffold.kt:495-504 RoomOpenBus.deliver(open = roomsViewModel::open) -> RoomsViewModel.kt:226-256 join(room). The AASA file claims /rooms/* and the Android filter claims pathPrefix /rooms/.

Reproduction: Code trace only; I did not run the apps. A link https://sila.gmai.sa/rooms/<attacker room id>, placed in a DM, a web page or a disguised Markdown or HTML link, opens the app through the universal link and calls the join API with no further tap. The victim then appears in the attacker's participants and listener list, which shows their verified identity and confirms they clicked. On Android any foreground app can also send an explicit ACTION_VIEW intent to the exported MainActivity. The web client is different: RoomScreen.tsx:200/274 starts in the 'idle' state and only joins when the person taps Listen.

Fix: When a room is opened from a link, show the room preview with an explicit Listen/Join button, as the web does, instead of calling join automatically. On iOS, pass a `joinOnAppear: false` flag for link and push origins and start() only on tap. On Android, have RoomOpenBus open the room preview rather than RoomsViewModel.open. Keep auto-join only for taps inside the app.

## CA-2 [medium] Android has no tapjacking (overlay) protection anywhere, and no FLAG_SECURE on screens that show ID documents

Where: sila-android app/src/main: a grep for filterTouchesWhenObscured, FLAG_WINDOW_IS_OBSCURED, setHideOverlayWindows, HIDE_OVERLAY_WINDOWS and FLAG_SECURE finds nothing. Sensitive screens: modules/auth/presentation/SignInScreen.kt:47, modules/verification/presentation/DocumentVerificationScreen.kt:145, modules/vouching/presentation/VouchClaimScreen.kt:143 and VouchingScreen.kt:155 (vouch confirm), modules/account/presentation/AccountSheets.kt:585 (delete-account button).

Reproduction: Static grep across the whole main source set. A malicious app with SYSTEM_ALERT_WINDOW, or one using a partially transparent activity, can draw over the confirm buttons (vouch confirm, delete account, document submit) and the app will still accept the touches.

Fix: In MainActivity.onCreate call `window.setHideOverlayWindows(true)` on API 31+ (needs the HIDE_OVERLAY_WINDOWS permission), at least while sensitive screens are showing. Wrap their confirm buttons in a pointerInput modifier that drops MotionEvents with FLAG_WINDOW_IS_OBSCURED or FLAG_WINDOW_IS_PARTIALLY_OBSCURED, or set `filterTouchesWhenObscured = true` on the ComposeView or root View. Add WindowManager.LayoutParams.FLAG_SECURE while document capture and review and the vouch details screens are showing.

## CA-3 [low] assetlinks.json is not published, so Android App Links are never verified, and the path lists in the app and on the site don't match

Where: https://sila.gmai.sa/.well-known/assetlinks.json returns 200 text/html (the web app's index page instead of the file). sila-android app/src/main/AndroidManifest.xml has an intent-filter with autoVerify=true for sila.gmai.sa, claiming /posts/ /rooms/ /events/ /u/ /c/ /hashtags/ /vouch /vouch/ /vouching.

Reproduction: Passive GET (curl -s -w '%{http_code} %{content_type}') of /.well-known/assetlinks.json returned 200 text/html with the web app's HTML. For comparison, /.well-known/apple-app-site-association returned 200 application/json, see the held items. Android 12+ will not verify the domain, so sila.gmai.sa links open in the browser, and if the person turns links on manually there is no proof of ownership. The manifest claims /hashtags/ but the web route is /tags/. The AASA does not list /c/* even though Android claims it.

Fix: Publish /.well-known/assetlinks.json as application/json with `[{"relation":["delegate_permission/common.handle_all_urls"],"target":{"namespace":"android_app","package_name":"sa.gmai.sila","sha256_cert_fingerprints":["<release or Play app-signing cert SHA-256>"]}}]`. Make nginx return 404 for unknown /.well-known/* paths instead of the web app's index page. Change the Android /hashtags/ entry to /tags/, or add both, and add /c/* to the AASA if communities should open in the iOS app. Do this only after CA-1 is fixed, because verified links make the room auto-join easier to trigger.

## CA-7 [low] Android debug builds log the bearer token: OkHttp header logging without redaction

Where: sila-android app/src/main/java/sa/gmai/sila/core/network/NetworkModule.kt:88-93 (HttpLoggingInterceptor at Level.HEADERS; redactHeader appears nowhere in the codebase)

Reproduction: Static read. In debug builds, every request's Authorization: Bearer header is written to logcat. The comment at that spot says bodies are excluded because they carry tokens, but the header carries one too. Release builds are not affected.

Fix: Add `.apply { redactHeader("Authorization"); redactHeader("Cookie"); redactHeader("Set-Cookie") }` to the interceptor.

## CA-8 [low] Android release builds are quietly signed with the public debug keystore when keystore.properties is missing

Where: sila-android app/build.gradle.kts:69-91 (testRelease signing config falls back to ~/.android/debug.keystore, password 'android')

Reproduction: Static read. A release APK built on a machine without keystore.properties gets a key that anyone can obtain. Nothing in the build fails to warn about it, and an assetlinks fingerprint taken from such a build would be wrong.

Fix: Make the release build fail when keystore.properties is missing, unless an explicit -PallowTestSigning flag is passed, or rely on Play App Signing and use its certificate in assetlinks.json.
