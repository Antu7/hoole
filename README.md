<p align="center">
  <img src="assets/icon.png" width="128" alt="Hoole icon">
</p>

<h1 align="center">Hoole</h1>

<p align="center">
  <b>Hold a key, talk, and your words are typed wherever your cursor is.</b><br>
  Free, open-source dictation for the Mac. Runs completely offline: your voice never leaves your computer.
</p>

<p align="center">
  <img src="assets/popover.png" width="360" alt="Hoole menu bar window">
</p>

<p align="center">
  <img src="assets/pill.png" width="520" alt="Hoole listening indicator">
</p>

---

## Why Hoole

- **Types for you, anywhere:** Notes, Slack, Mail, your browser, the terminal. If there's a cursor, Hoole can type there.
- **Push to talk:** hold your shortcut while you speak, let go when you're done. Words appear as you talk.
- **Private by design:** speech recognition runs on your Mac. No account, no cloud, no internet needed after setup.
- **Fast:** words show up within about a second of saying them.
- **Your shortcut:** a single key like **fn** or **F5**, a combo like **⌥ Space**, or keys held together like **A + Space**.
- **7 languages:** English, German, French, Spanish, Italian, Dutch and Polish, or let Hoole detect the language.
- **No time limit:** talk for as long as you like.

## Requirements

- A Mac with **Apple Silicon** (M1, M2, M3, M4 or later)
- **macOS 14 Sonoma** or newer
- About 30 MB of disk space

## Install

Hoole is built from source. It takes a couple of minutes and you don't need any programming experience.

**1. Install Apple's command line tools** (skip if you already have them). Open **Terminal** (press ⌘ Space, type *Terminal*, press Return) and run:

```sh
xcode-select --install
```

Click **Install** in the window that appears and wait for it to finish.

**2. Download and build Hoole:**

```sh
git clone https://github.com/antu7/hoole.git
cd hoole
./scripts/build.sh
```

The first build downloads the speech model (about 17 MB) and takes a minute or two.

> **One-time password prompt:** on the first build, macOS asks for your password to trust a local signing certificate called "Hoole Local Signing". This lets macOS remember Hoole's permissions when you update or rebuild. If you skip it, Hoole still works, but macOS will ask for permissions again after every rebuild.

**3. Move it to your Applications folder and open it:**

```sh
cp -R build/Hoole.app /Applications/
open /Applications/Hoole.app
```

Hoole lives in your **menu bar** at the top of the screen, as a small waveform icon. It has no Dock icon.

## First launch: allow two permissions

Click the Hoole icon in the menu bar. If anything is missing, you'll see an **Allow** button for it:

| Permission | Why Hoole needs it |
|---|---|
| **Microphone** | To hear you. |
| **Accessibility** | To notice your shortcut and type the text at your cursor. |

For Accessibility, macOS opens **System Settings → Privacy & Security → Accessibility**. Switch **Hoole** on there. You only have to do this once.

## How to use

1. Click into any text field: a message, a document, a search box, a terminal.
2. **Hold your shortcut** (default: **⌥ Option + Space**).
3. Talk. A small bar at the bottom of the screen shows that Hoole is listening, along with your words.
4. **Let go.** Your words are typed where your cursor was.

Want to keep going? Hold the shortcut again; Hoole adds a space and continues your sentence.

### Settings (click the menu bar icon)

| Setting | What it does |
|---|---|
| **Shortcut** | Click it, then press the key or keys you want and let go. Esc cancels. |
| **Microphone** | Choose which mic to use: built-in, AirPods, a USB mic, and so on. |
| **Language** | Pick your language, or leave it on Auto-detect. |
| **Type where my cursor is** | Turn this off to have Hoole copy text to the clipboard instead of typing it. |
| **Recent** | Your last few dictations. Click one to copy it again. |

You can also click the big microphone button to start and stop recording without the shortcut.

## Tips and troubleshooting

**Nothing gets typed.** Open the menu bar window and check:
- No **Allow** buttons are showing (both permissions are on).
- The right **Microphone** is selected. AirPods in their case, or a muted headset, send silence. If Hoole hears nothing, the bottom bar says *"No sound from the mic"*.

**My shortcut stopped typing a letter.** If your shortcut includes a key that normally types something (like **A + Space** or **⇧** alone), that key can't type normally while Hoole is running. Hoole warns you when you pick one. Shortcuts with **fn**, **⌥**, **⌃** or **⌘** avoid this.

**Hoole typed words I didn't say.** In a very quiet room, background noise is sometimes heard as a short phrase. Hold the shortcut only while you're speaking.

**I want to start fresh.** Click **Clear** next to *Recent* to delete your history.

## Updating

```sh
cd hoole
git pull
./scripts/build.sh
cp -R build/Hoole.app /Applications/
```

Quit Hoole first (menu bar icon → **Quit**), then open it again after copying.

## Uninstalling

1. Quit Hoole from the menu bar.
2. Delete **Hoole** from your Applications folder.
3. Optionally, remove it from **System Settings → Privacy & Security → Accessibility** and **Microphone**.

## Privacy

Hoole records audio only while you hold the shortcut (or after you click the record button). The audio is turned into text on your Mac and then thrown away. Nothing is uploaded, and Hoole doesn't collect any analytics. Your recent dictations are stored only on your Mac.

## Making a release build

```sh
./scripts/build.sh --dmg   # creates build/Hoole.dmg
```

## License

MIT © [Tanvir Hossain Antu](https://github.com/antu7). Third-party components included in the app are listed in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
