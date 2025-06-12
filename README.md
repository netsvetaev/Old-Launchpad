![small-hand](https://github.com/user-attachments/assets/5a715349-5ae4-4f0e-8f05-ee0287241da9)

# Old MacOS Launchpad
Old Launchpad is a vibe-coded standalone, SwiftUI-based replacement for macOS Launchpad.
It mimics the grid layout and folder behaviour of the original:

•	optional live refresh when apps are added/removed from /Applications or ~/Applications

•	inline search, drag-to-reorder, drag-to-folder, and drag-back-out

•	dynamic page indicator & smooth horizontal swiping

Compiled App is here: https://github.com/netsvetaev/Old-Launchpad/releases

# Features
Grid & Pages
7 × 5 icons per page.  Empty placeholders keep every screen independent.

Drag & Drop
– swap icons– 3 s hover to create / append folders– drag an icon out of a folder and drop directly to the neighbour slot.

Search
Type in the top-bar – grid filters instantly.

Live refresh
startWatchingFolders() watches /Applications and ~/Applications via DispatchSource. refreshApps() adds any new bundles and removes deleted ones.

Dismiss
• Esc key ( .onExitCommand)  • mouse-down on an empty space.

Persistence
Layout stored in ~/Library/Application Support/Dock/launchpad_layout.json (separate from Apple’s DB).

# Screenshot
![Screenshot 2025-06-11 at 2 43 29 AM](https://github.com/user-attachments/assets/cb871d10-252a-44a6-87f7-6a96d0b60190)

# Build & Run

Requires Xcode 15+, macOS 13 Ventura or newer.

```bash
git clone https://github.com/your-name/old-launchpad.git
open "old-launchpad/Old Launchpad.xcodeproj"
⌘-R          # Run in Xcode
```

# Hot Corners
macOS does not expose Hot-Corner APIs to third-party apps.
If you want a corner to open Old Launchpad, use BetterTouchTool / Raycast to map “Top-Left Corner → open Old Launchpad.app”.

# Roadmap
I don't know. Maybe iCloud sync & various settings?

# License
BSD-3-Clause.

# Author
My name is Art Netsvetaev. I'm designer, product manager & entrepreneur.
I did this app as an example of vibe-coding with ChatGPT and absolutely no idea what SwiftUI is (I prefer python).
The icon is based on my own logotype.

https://netsvetaev.com
