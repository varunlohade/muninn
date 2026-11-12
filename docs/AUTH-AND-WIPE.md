# Sign-in, log out, and the wipe list

Muninn iOS. Pip mirrors this list.

## Ways in

| Way | Route | Notes |
| --- | --- | --- |
| Continue with Apple | `GET /v1/auth/apple/nonce`, then `POST /v1/auth/apple` `{identity_token, nonce}` | The app fetches a one-time nonce from the server and sends its SHA-256 to Apple. If the server has no nonce route, the phone makes a random nonce. |
| Continue with email (sign up) | `POST /v1/auth/email/signup` `{email, password}` | 400: weak password (the server's words). 409: the email has an account, so "Log in instead". |
| Continue with email (log in) | `POST /v1/auth/email/login` `{email, password}` | 401: "Wrong email or password." 429: "Too many tries. Wait a few minutes, then try again." |
| Try without an account | `POST /v1/auth/device` | The old "Get started". The account lives on this phone until the owner links Apple or an email. |

PayPal is not a way in. "Connect PayPal" links a PayPal account to the signed-in user.

Settings, "Account": `GET /v1/account` lists the ways in (Apple, Email). "Add an email" calls `POST /v1/auth/email/link`. An Apple account adds an email this way. "Continue with Apple" in Settings (`SaveDetailsCard`) calls `POST /v1/auth/apple/link`.

## Log out

1. `POST /v1/auth/logout`. The server deletes this token's row, so the token fails with 401 at once. This is the token revoke route. `?all=1` ends every session of the user. The app sends no `all`.
2. The phone wipes every store below, even when step 1 fails (no network). The phone never keeps the last user's data.
3. The app opens the sign-in step, not the intro. The navigation stack starts new, so no screen of the last user stays pushed.

Delete account: `DELETE /v1/account` with `X-User-Action: tap`, after a confirm step on the Settings page. On success, the same wipe runs. On failure, nothing is wiped and the page shows one plain line.

Code: `ios/App/AccountSession.swift` (`logout`, `deleteAccount`, `wipeAndSignOut`), `ios/Shared/LocalWipe.swift`.

## Wipe list

| Store | Where | What is wiped |
| --- | --- | --- |
| Keychain | shared group `<prefix>com.orseliyas.muninn.shared` and the app's own | Every item of every class: the device token, the install id (`device_id`), and anything else. |
| App Group defaults | suite `group.com.orseliyas.muninn` | Every key: `server_url`, `apple_linked`, `unpaid_count`, `key_haptics`, `touch_offsets`, `pasteboard_change_count`, `keyboard_last_seen`. Then `wipe_generation` is written back, one higher. |
| App Group files | group container | Every file and folder except `Library/Preferences` (the defaults file) and iOS's `.com.apple.mobile_container_manager.metadata.plist`: `appointments.json` (day data), `notes.json`, `shortcuts.json`, `pending-action.json`, `learned.json` (learned words), `drawings.json` and `drawings/` (PNG and scene JSON), `Library/Caches`. |
| App defaults | `UserDefaults.standard` | The whole domain: `brief_cache`, `brief_cache.at`, `known_paid_ids`, `intro_seen`. |
| App files | app sandbox | Everything in Documents, Application Support, Caches and tmp. |
| URL cache | `URLCache.shared` | All responses. |
| Cookies | `HTTPCookieStorage.shared` and the App Group cookie storage | All cookies. |
| Credentials | `URLCredentialStorage.shared` | All saved credentials. |
| Web data | `WKWebsiteDataStore.default()` | All data types. The drawing page uses a non-persistent store, so it keeps nothing on disk. |
| Decoded photos | `CatalogThumbs.shared` (memory) | Emptied. |
| PayPal state | `PayPalConnector.shared` (memory) | Status, note, the account waiting for "Use this account", and any open PayPal web sheet. |
| Calendar matches | `CalendarModel.shared` (memory) | Today's list and the clients and payments it matched against. |
| Session | `Session` (memory) | `paired`, `appleLinked`, `notice`, `error`, `serverURL`. `onboarding` goes back on, at the sign-in step. |
| Screens | SwiftUI state | Home, Settings and every pushed screen go away with the new navigation stack. |

Not wiped, on purpose: the calendar and reminders permission (iOS owns it), the keyboard being on in Settings, and the system's list of keyboards. None of them holds user data.

## The keyboard

The keyboard is a separate process, so the app cannot clear its memory. Instead:

- The wipe raises `wipe_generation` in the App Group defaults.
- The keyboard notes the count when it starts. On each `viewWillAppear` it reads the count again.
- If the count moved, the keyboard throws away its `KeyboardModel` (clients, who-owes list, chips, lookup, explain cache, pending suggest tasks) and builds a new one. It also runs `LocalWipe.process()` for its own URL cache, cookies, credentials, and web data.
- Every server call reads the token from the Keychain at the time of the call, so after log out the keyboard has no token and says "Open Muninn to pair".

## Tests

- `ios/Tests/AuthWipeTests.swift`, `testLogoutEmptiesEveryStore`: seeds every store above with a client's name, calls `Session.logout()` with the server unreachable, and checks that each store is empty.
- `ios/UITests/AuthWipeUITests.swift`: user A logs in by email and sees A's client on Home and in the keyboard's who-owes list. A logs out from Settings. User B signs up. A's client and A's email appear nowhere in the app or the keyboard. Needs `npm run fake` and the keyboard on (`ExplainShots/test1Setup`). Its tear-down resets the fake, because log out really revokes the fake's shared `pkd_fake` token.
