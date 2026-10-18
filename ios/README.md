# Tiro for iPhone

Tiro's dictation on iOS: talk in any app through the Tiro keyboard, and your
words are transcribed **on the iPhone** with whisper.cpp, the same engine and
models as the desktop app. Free, no account, no cloud, no analytics.

Same features as the desktop app (contract: [`../spec/FLOW_FEATURES.md`](../spec/FLOW_FEATURES.md)):

| | |
|---|---|
| **Dictate anywhere** | The Tiro keyboard has a mic bar on top of a normal QWERTY keyboard. |
| **Smart formatting** | Capitalization, punctuation, optional um/uh removal. |
| **Spoken commands** | "comma", "period", "question mark", "new line", "new paragraph", "scratch that". |
| **Styles** | Formal, casual (no final period), very casual (lowercase). |
| **Dictionary** | Hot words prime Whisper; corrections fix what it still mishears. |
| **Snippets** | Say "my email" and get your address. Multi-line snippets work too. |
| **Languages** | English, auto-detect, or any Whisper language (with a multilingual model). |
| **History** | Everything you said, searchable, by day. Verbatim is always kept. |
| **Stats** | Words, WPM, time saved vs typing, day streak. |
| **Fits the cursor** | Adds a space after a word, continues mid-sentence in lowercase. |

## How the keyboard works

iOS doesn't let keyboards use the microphone, so Tiro does what Wispr Flow
does: the keyboard asks the **Tiro app** to listen.

1. First tap on the keyboard's mic: the keyboard opens Tiro (`tiro://dictate`),
   which starts a *session* and begins recording right away.
2. Go back to your app (the ◀ breadcrumb, top left) and keep talking.
3. Tap the mic again: Tiro transcribes in the background, and the keyboard
   inserts the text at the cursor.
4. For the next few minutes (Settings → Keyboard → Stay listening), the mic
   works straight from the keyboard, with no app switch. iOS shows the orange
   mic dot while the session is ready.

Under the hood ([`Shared/Bridge.swift`](Shared/Bridge.swift)): the keyboard
sends start/stop/cancel as Darwin notifications, and the app writes its state,
the input level and the result to the App Group's shared defaults. The
keyboard needs **Allow Full Access** only to reach that shared App Group. It
has no network code.

Transcription runs on the CPU on purpose, because iOS refuses GPU work from
background apps. base.en takes about a second for a short sentence.

## Layout

```
ios/
  project.yml          XcodeGen spec (the .xcodeproj is generated)
  Signing.xcconfig     team + bundle id (override in Signing.local.xcconfig)
  App/                 the Tiro app: recording, whisper.cpp, models, screens
  Keyboard/            the keyboard extension
  Shared/              compiled into both: formatter, word lists, history, bridge
  Tests/               unit tests + real whisper.cpp transcription tests
  UITests/             drives the app with a fake mic (DEBUG only)
  scripts/bootstrap.sh fetch whisper.xcframework + generate the project
```

## Build

Needs Xcode 16 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
cd ios
./scripts/bootstrap.sh       # downloads whisper.xcframework (official ggml-org release), runs xcodegen
open Tiro.xcodeproj
```

### Run on your iPhone

1. Xcode → Settings → Accounts: add your Apple ID (a free one works for your
   own phone; free installs expire after 7 days).
2. Create `ios/Signing.local.xcconfig`:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   TIRO_BUNDLE_ID = com.yourname.tiro
   ```
   The team id is in Xcode's Accounts pane, or run `security find-identity -v -p codesigning`.
   Bundle ids are global, so pick one only you use. The keyboard id and App
   Group are derived from it.
3. Plug in the iPhone, unlock it, trust the Mac, and turn on
   Settings → Privacy & Security → Developer Mode.
4. Run the **Tiro** scheme on the phone (⌘R), or from the command line:
   ```sh
   xcodebuild -project Tiro.xcodeproj -scheme Tiro -configuration Release \
     -destination 'id=<phone udid>' -allowProvisioningUpdates build
   xcrun devicectl device install app --device <phone udid> \
     ~/Library/Developer/Xcode/DerivedData/Tiro-*/Build/Products/Release-iphoneos/Tiro.app
   ```
5. On the phone, open Tiro once: download a model, then Settings → General →
   Keyboard → Keyboards → Add New Keyboard → Tiro → Allow Full Access.

### Tests

```sh
# unit tests, plus real transcription if you point at a model file
TEST_RUNNER_TIRO_TEST_MODEL=/path/to/ggml-base.en-q8_0.bin \
  xcodebuild -project Tiro.xcodeproj -scheme Tiro \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:TiroTests test

# UI tests: onboarding with a real model download, in-app dictation, and a
# keyboard session recorded + transcribed while Tiro is in the background
xcodebuild -project Tiro.xcodeproj -scheme Tiro \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:TiroUITests test
```

The formatter runs the shared vectors in `spec/format_cases.json`, and so do
the desktop's Rust tests, so the two can't drift apart.

## App Store checklist

- **Apple Developer Program** ($99/year). It's required for the App Store and
  TestFlight even for a free app.
- **License.** Tiro is GPLv3. The App Store's terms add restrictions the GPL
  forbids, so publishing a GPL app there needs every copyright holder's
  permission. Here that means Beckett Harriman (and contributors) adding an
  App Store exception, or dual-licensing the iOS code. whisper.cpp itself is MIT.
- **App Privacy:** "Data Not Collected". Nothing is sent anywhere. The only
  network use is downloading a model from huggingface.co when you ask.
- **Review notes for the keyboard:** explain that Full Access is used only for
  the App Group shared with the Tiro app (to receive transcribed text), that the
  keyboard has no networking, and how the session works (the app records in the
  background with the `audio` background mode while a session is live, with the
  orange indicator visible). Wispr Flow ships the same design.
- **Privacy policy URL**: required. One paragraph saying no data is collected
  is enough (for example a page in this repo).
- Screenshots (6.9" and 6.5" iPhone, 13" iPad), app description, support URL,
  age rating, and an `ITSAppUsesNonExemptEncryption = false` declaration
  (already set).
- Archive: Product → Archive in Xcode, then Distribute → App Store Connect.
