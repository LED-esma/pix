# Pix's tools

Every AI Pix runs on gets the same tools, served by Pix's own tool server (`Pix --mcp`). Changes come back with Undo; anything that can't be taken back (running a script or Shortcut, moving files to the Trash, clicks that send, buy, delete or sign in) asks first. This list is generated from the app (`Pix --mcp`, `tools/list`).

## Reminders and Calendar

| Tool | What it does |
|---|---|
| `reminders_list` | The user's open reminders, soonest first. |
| `reminder_add` | Adds a reminder to Apple Reminders. With a due time it alerts them then. |
| `reminder_done` | Marks a reminder done. |
| `events_list` | Calendar events (all of the user's calendars). |
| `event_add` | Adds an event to the user's calendar. |

## Notes, Shortcuts and timers

| Tool | What it does |
|---|---|
| `shortcuts_list` | Names of the user's Apple Shortcuts. |
| `shortcut_run` | Runs one of the user's Shortcuts by name (anything a Shortcut can do, e.g. a Focus or Do Not Disturb shortcut). |
| `notes_search` | Searches Apple Notes by title and text. |
| `note_add` | Creates an Apple Note. |
| `timer_start` | A countdown on the blob that taps the user when it ends. For "in N minutes". |
| `schedule_add` | Makes Pix answer a question by itself at a time, once or on a repeat (e.g. every weekday at 8:00, "what's due today?"). The answer pops up then. |
| `schedules_list` | Timers and scheduled runs that are set. |
| `schedule_remove` | Cancels a timer or scheduled run. |

## Files

| Tool | What it does |
|---|---|
| `files_find` | Finds files in the user's home folder with Spotlight. |
| `file_read` | Reads a text or PDF file in the user's home folder. |
| `folder_list` | Lists a folder in the user's home (e.g. ~/Downloads): each file's name, size, date and a peek inside (a PDF's title and first words, a document's first lines), so files can be sorted by subject. Use before moving anything. |
| `files_move` | Moves and/or renames many files in one go: makes folders as needed, never overwrites, reports exactly what moved, one Undo for all. Use this for organizing, never shell commands. |
| `files_organize` | Organizes a whole folder in one go (Pix does the sorting: by subject reads each file's name and first words, keeps numbered sets together, re-sorts files already in its plain folders, leaves unsure ones in place and names them). One Undo. Use this first for 'organize my Downloads'. |
| `files_trash` | Moves files to the Trash (the user is asked first; Undo puts them back). |
| `files_zip` | Zips files or folders into one .zip next to them. |
| `files_unzip` | Unzips a .zip into a folder next to it. |
| `files_duplicates` | Finds duplicate files (same contents) in a folder. Removes nothing. |
| `files_reveal` | Shows a file or folder in Finder. |

## The web and Pix's browser

| Tool | What it does |
|---|---|
| `web_search` | Searches the web. Returns titles, links and snippets. |
| `web_read` | Reads a web page or online PDF as plain text (the first 12,000 characters). look_for returns only the parts that mention those words (cheapest; e.g. price, hours); from continues further down. |
| `browser_tab` | The page open in the user's browser right now (title, address, and its text). For "this page" or "this article". |
| `browser_go` | Opens a page in Pix's own browser window (the user can watch) and returns its numbered buttons, links and fields plus its text. For anything interactive on the web. |
| `browser_look` | What Pix's browser shows now: numbered things to use, and the page text. |
| `browser_click` | Clicks thing [n] in Pix's browser. Anything that submits, buys, sends, signs in or deletes asks the user first. |
| `browser_type` | Types into field [n] in Pix's browser (never passwords or payment details: the user types those). submit presses Enter. |
| `browser_scroll` | Scrolls Pix's browser. |
| `browser_back` | Goes back a page in Pix's browser. |

## Your apps on screen

| Tool | What it does |
|---|---|
| `screen_look` | Lists what can be clicked in the app in front (or a named app): buttons, fields, menus, each numbered. Text only, no screenshot. Use it before screen_click, screen_type or screen_show. |
| `screen_click` | Do It: clicks [n] from the last screen_look, then each number in then (in order, in one go: e.g. a calculator's 4, 5, +, 1, 7, =). Returns the text on screen now. Clicks that send, buy, delete or sign in ask the user first. |
| `screen_type` | Do It: types into field [n] (never passwords: the user types those). submit presses Return. |
| `screen_key` | Do It: presses keys in the app in front, e.g. cmd+s, cmd+shift+n, return, escape, down. |
| `screen_show` | Show Me: rings [n] on the screen with a short step on Pix's card, waits for the user to click it, then returns what's there now. One step per call. |
| `screen_see` | A screenshot of the window in front (or a named app), for when screen_look finds nothing useful: drawing and design apps, games, canvases, images, a web page's layout. Returns the picture; give positions as x, y in its pixels. |
| `screen_click_at` | Do It by position: clicks x, y in the last screen_see picture (presses the control there without moving the mouse when it can). what says what's there, e.g. Export button. Clicks that send, buy, delete or sign in ask the user first. |
| `screen_show_at` | Show Me by position: Pix flies to x, y in the last screen_see picture, points at it with the step, waits for the user to click there, then returns a new picture. One step per call. |
| `screen_drag` | Drags from x, y to to_x, to_y in the last screen_see picture (move a part, draw a wire, select an area). |
| `screen_scroll` | Scrolls at x, y in the last screen_see picture. |
| `clipboard_copy` | Puts text on the clipboard, to paste somewhere with screen_key cmd+v. Whatever the user had copied comes back when the task ends. |
| `clipboard_read` | The text on the clipboard (e.g. after screen_key cmd+c in an app). |
| `wait_for_user` | Pauses for something only the user can do: signing in, an 'are you human' check, picking a file. Shows what to do on Pix's card and waits until they tap Continue (up to 10 minutes). |

## Mac settings and windows

| Tool | What it does |
|---|---|
| `open` | Opens an app (by name), a web link, or a file. |
| `music` | Controls Music or Spotify. |
| `volume` | Sets the Mac's sound volume. |
| `mac_setting` | Changes a Mac setting, with Undo: dark_mode, wifi, mute (on/off), or wallpaper (value = picture path). Volume has its own tool. Bluetooth, Focus and brightness can only go through the user's Shortcuts. |
| `app_window` | Controls an open app: quit, hide, show, full_screen, exit_full_screen, minimize, other_display (move its window to the other screen). Undo puts it back. |
| `windows_side_by_side` | Puts two open apps side by side on the screen (left half, right half). Undo puts them back. |

## Tools Pix makes

| Tool | What it does |
|---|---|
| `use_tool` | Runs one of the saved tools (their names come with the question): returns its steps to do now. |
| `tool_save` | Saves a tool: a named recipe that you (or the user, by typing its name) can run later, e.g. Morning Brief = check the weather, what's due, today's calendar; Clean Downloads = an AppleScript that moves old files to the Trash. Steps say exactly which tools to call and include any AppleScript or shell command word for word, tested first. |
| `tools_list` | The tools the user and Pix have saved, with their steps. |
| `applescript_run` | Runs AppleScript to control a Mac app (Finder, Safari, Mail, System Events, System Settings…) when no other tool does the job. The user sees the script and approves it the first time. Returns the result or the error. |
| `shell_run` | Runs a zsh command in the user's home folder when no other tool does the job. The user approves each new command. Returns its output or error. 60-second limit. |

## Memory

| Tool | What it does |
|---|---|
| `remember` | Saves a short fact about the user for next time (a class, project, preference). Never passwords, numbers, health or money details. |
