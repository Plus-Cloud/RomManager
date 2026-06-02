---

# RomManager

RomManager is a standalone terminal engine, asset scraper, and direct network harvester built specifically for the Miyoo Mini and Miyoo Mini Plus running OnionOS. Operating directly from your applications directory, it drops a sleek menu wrapper over your handheld, giving you the power to crawl public internet archives, download game files directly over Wi-Fi, and manage your local collection on the fly without ever pulling your SD card or connecting to a PC.

Most scene tools out there are either bloated, depend on heavy runtime environments, or completely break when trying to match game titles with box art databases. RomManager fixes all of that. It runs on a lightweight, shell-driven graphics architecture to parse massive multi-thousand game lists with absolute zero menu lag, working natively with the screen display buffer.

<img width="640" height="480" align="center" alt="MainUI_001" src="https://github.com/user-attachments/assets/aca9bd1c-e3b0-4131-949b-d9c51f6cd6cd" />

---

## Core Features

* **PC-Free Game Harvesting:** Link up to your Miyoo's local Wi-Fi to browse, stream, and download game packages from public internet archives directly to your system ROM directories.
* **Universal Naming Translation Layer:** Built with a regex matching engine that cleans up titles for every single console database on the fly. It automatically strips out messy metadata distribution junk (like `[!]`, `[C]`, or bad bracket text) and converts single-letter region tags (like `(U)`, `(E)`, or `(J)`) into full standard words (`(USA)`, `(Europe)`, `(Japan)`). This ensures naming formats align perfectly with web artwork databases.
* **Dynamic Art Scraping:** Built-in automated asset fetching. When you pull a new game down, the scraper instantly runs the translated title through external Libretro thumbnail servers to track down, grab, and map the correct cover art in real-time.
* **Live Graphical Preview Canvas:** Features a localized display painter that grabs high-resolution box art from your console directories and pulls it right onto your screen. Whether you are checking local storage files or hovering over a remote download option, you get an instant visual preview of the actual game cover.
* **Smooth D-Pad Scrolling:** Heavy CPU menu throttling is completely eliminated. The app locks down all system pathways, local files, and directory counts into clean static cache maps on boot. Scrolling through lists reads straight from these pre-built cache logs, meaning absolutely zero input delay on lower-power ARM chips.
* **On-Screen Keyboard Search:** Tap `Select` inside any massive file menu to summon a responsive letter matrix screen, allowing you to instantly type out custom search query strings and filter down endless game sets to exactly what you want.
* **Local Handheld Cleaning:** A dedicated local directory deck lets you inspect exactly what is on your system storage, run a focused art scrape on a single game with a missing cover, or permanently delete unwanted files and matching artwork to reclaim space instantly.

## Secondary Mechanics

* **Background Soundtrack Loop & Menu FX:** Integrated audio tracking handling background loops and sharp physical button audio feedback.
* **Track Interruption Recovery:** The script saves live audio tracking coordinates to a state log (`/tmp/bgm_position`) when menu sound effects ring out. The background loop resumes from the exact second it left off instead of restarting the song from the beginning.
* **Clean Suffix Extension Slicing:** Keeps the display menus completely clean by stripping raw file extensions (`.zip`, `.gbc`, `.chd`, `.7z`) across all folders before writing text lines to the display canvas.
* **Cross-Platform Bookmarking:** A global cross-platform tracker file (`favorites.txt`) allows you to favorite your preferred game titles across completely different emulator paths for fast navigation.

---

## Screenshots

<img width="640" height="480" alt="RomManager_001" src="https://github.com/user-attachments/assets/9e896097-6467-4ab3-9656-23e792235b26" />\\

<img width="640" height="480" alt="RomManager_004" src="https://github.com/user-attachments/assets/17dd250f-a1c6-48ba-ac48-683eb14d1ac8" />


---

## Directory & Architecture Map

For deployment inside OnionOS, the application folder structure looks like this:

```
/mnt/SDCARD/App/RomManager/
├── bin/                    # Helper binaries mapping controls and screen text painting
│   ├── getkey              # Hardware button tracker
│   ├── ui_renderer         # Core canvas display buffer compiler
│   └── show                # Canvas paint rendering utility
├── libs/                   # Shared execution libraries (.so dependencies)
├── sounds/                 # Wave assets for operational audio engines and tracking loops
├── ui/                     # Device font sheets and terminal wallpaper art assets
├── caches/                 # Pre-built system maps, search logs, and preview graphics
├── archives.txt            # System configuration database linking local paths to Repo IDs
└── launch.sh               # Main application launch execution script

```

---

## Operating the Repository Menu

RomManager does not host, share, or bundle any copyrighted digital files or game data. Every network pass is driven entirely by the database targets you link inside the app.

Selecting **Manage Repositories** from the main menu brings up your global backend deck. This screen lists every system folder on your SD card alongside its active internet repository target. If a system hasn't been set up yet, it will display a blank `ADD REPO` tag.

### Linking an Internet Archive ID:

1. Scroll to your target console (e.g., `GBC`) and press **Button A**. This fires up the On-Screen Keyboard.
2. Type out the exact, case-sensitive **Identifier** of the Internet Archive item you want to crawl. For example, if the archive URL is `[https://archive.org/details/gbc-no-intro-2026](https://archive.org/details/gbc-no-intro-2026)`, you will type: `gbc-no-intro-2026`.
3. Press **Start** to save. The engine will instantly run a background handshake check to ping the server and verify the ID has a valid file table.
4. If validated, the repository is linked permanently, and selecting that console in the main download menu will instantly populate its live directory list.

### Maintenance and Cache Management:

Internet Archive data can change or update. If you notice a repo has added new games or changed its layout, navigate back to **Manage Repositories**, highlight that system, and press **Button Y**.

This completely purges the local database list for that specific console without wiping any of your other systems. The next time you open that console's download section, the engine will fetch a completely fresh, updated file map from the server.

---

## Installation

1. Download the `RomManager` zip archive from the releases tab on GitHub.
2. Open the zip file, grab the inner `RomManager` folder, and drag it directly into the App directory on your Miyoo's SD card:
`/SDCARD/App/RomManager/`
3. Unmount your SD card safely, slide it into your Miyoo Mini / Plus, boot up the handheld, and launch it straight from your Apps selection page. OnionOS will automatically configure execution permissions on first launch.

---

## Handheld Control Layout Reference

| Hardware Key | Navigation Menu Context | On-Screen Keyboard Context |
| --- | --- | --- |
| **D-Pad Up / Down** | Scroll highlighted list option indices | Move cursor across 2D matrix selection cursor |
| **D-Pad Left / Right** | Page flip skip list blocks up or down | Move cursor across 2D matrix selection cursor |
| **Button A** | Confirm Selection / Trigger Download / Start Scrape | Write highlighted text token to string |
| **Button B** | Return to previous state layer view | Delete trailing string buffer character |
| **Start** | Toggle Selected Game into Favorites / Unfavorite | Commit active text search query to index |
| **Select** | Launch search matrix interface panel | Wipe active search query block and close layer |
| **Button Y** | Delete file permanently (Local directory view only) | N/A |
| **Button X** | Clear active search cache lists back to default | Close layer / Save active input variables |
| **R / R1** | N/A | Toggle global case formatting options |

---

## Operational Suffix Modifiers (`settings.ini`)

Internal app settings configure automatically through your system configurations screen or can be edited directly inside `settings.ini`:

* `BGM_ENABLED` / `SFX_ENABLED`: Set to `1` (Active) or `0` (Disabled) to rule operational sound cards.
* `UI_MAX_ITEMS`: Numeric rendering constraint setting the max listing lines loaded per frame canvas.
* `AUTO_SCRAPE`: Set to `1` to instantly drop into a Libretro box art download pass the second a ROM file finishes streaming down.
* `REPO_CACHE_DAYS`: Integer setting how many days a compiled network directory index stays valid before verifying with the server again.

---

## Acknowledgments

This entire project was designed, built, tested, and debugged solo as an adhd special intrest after realizing i something like this didnt exist.

Shout out to the open-source emulation developers whose documentation made things possible.

Developed by plusCloud
