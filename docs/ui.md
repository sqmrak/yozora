# ui

native uikit, objective-c with manual reference counting, one codebase from ios 5 to latest. what a system lacks is looked up at run time and has a fallback.

## look

material you, as in exteria.

- a tonal purple palette: light, dark, and black with its own grounds (`YZTheme`)
- material symbols rounded for glyphs, the search engines keep their own marks
- the address field is a pill search bar, the bottom bar grows a pill of the accent under a pressed button
- the menu is a compact card that grows out of the menu button and closes on a tap outside it
- tab cards have rounded corners and a floating button for a new tab
- settings, bookmarks, history and downloads: a large title that scrolls away, no lines between rows, cards whose corners follow the place of the row in its group, a glyph in a tonal disc, a material 3 switch with a thumb that wobbles over

## accent

`Settings > Accent color` opens the editor of weeabu and exteria: a card in the chosen color with its hex digits (a tap types them), tracks for hue, saturation and brightness, ten ready colors. the palette turns to the color the way exteria does it (`core/yozora_accent.c`): every hue moves by the distance of the accent from the purple of the palette (286 degrees), saturation follows, greys stay grey, brightness dims grounds and keeps words. the light theme shows the color itself as the accent, dark and black keep a lighter one of its hue. nothing is stored until a color is chosen.

## motion

the curves of material 3 and exteria (`core/yozora_motion.c`): emphasized decelerate and accelerate for sheets and menus, and a spring that passes its target by a sixth and swings back twice for cards, tiles, glyphs, banners and the tab switch. the spring is sampled as keyframes, so ios 5 has it too. press feedback is a bounce. everything follows reduce motion where the system has it, and the settings have an own switch.

## bars

on a phone the bottom bar leaves when the page has been read down by a few finger lengths and comes back only at the top of the page, while the address is typed and whenever a part of the interface opens. a scroll up in the middle of a page does not bring it back.

## controls of pages

the core asks, the interface answers by id:

- a `select` opens as a material 3 bottom sheet: group labels, unavailable items, a check on the chosen one. with `multiple` it is a list with a check for each item and a done button, the core takes the tap before the page does
- date, time, datetime-local, month and week fields open the wheels of `UIDatePicker` in a sheet, the value goes back in the format of the field and the limits of the page apply
- `<input type=color>` opens a card with the color and its hex digits and tracks for hue, saturation and value (`YZColorPicker`, the math in `core/yozora_color.c`)
- a file field offers the photo library, the downloads folder and, on ios 8 and later, the files app. a photo is written as a jpeg to `tmp/YozoraUploads`, files older than a day are removed with the next photo. a file field takes one file from the downloads folder, several only from the photos and the files app. a file from the downloads folder, the storage or the system picker is copied to its own folder under `tmp/YozoraUploads` first: WebKit takes the same path chosen again for no change and fires cancel, so a repeat pick did nothing. the system picker of ios 8 to 10 is named iCloud Drive; when it closes without a file the list of sources comes back
- long press on a link or an image opens a sheet: new tab, private tab (not inside the private session), copy link, share link, and for an image open, copy address, share address
- share and copy: the menu hands the address to the share sheet, `Copy address` says so in a banner. the share sheet needs ios 6, an older system shows no share entries

## find in page

the menu replaces the address bar with a field, a count ("3/12", at most 500 are counted) and arrows. every match is marked by webcore, the current one is selected and scrolled into view, the search wraps and ignores case.

## zoom

two fingers enlarge the picture of the page the way safari does, the layout keeps its width (scale 1 to 3, one finger moves the view over the page and scrolls past its edge). when the pinch settles on a phone with 900 MB or more the tiles are painted again at up to twice the pixels, so text stays sharp. a phone with less enlarges the tiles it has. a new page starts at scale 1, a keyboard keeps the zoom, a rotation drops it. the math is `core/yozora_zoom.c`.

## desktop site

the core keeps it (`yozora_core_set_desktop`): the user agent of safari on a mac, `navigator.platform` MacIntel for the page and its frames (workers keep the one of the port) and a layout 980 points wide. the menu has no entry for it, the interface cannot switch it on. the mode belongs to the tab and a page in it neither reads nor writes the disk cache.

## notch

on a phone with a notch, rounded corners or a home indicator the bars take `safeAreaInsets` and run the whole width, and the page, the home screen, the error page, the suggestions and the cards stand between the left and right insets (`layoutChrome`), so a landscape page does not run under the notch. the strips beside the page show the surface color, not the background of the page. `viewport-fit=cover` is not honored and `env(safe-area-inset-*)` is 0 for a page: a page always gets the safe area as a margin. the video screen reads the insets on its own. not seen on a device yet.

## ipad

all four orientations. a window of 700 points or more shows the tabs as a strip above one toolbar (back, forward, address, bookmark, tabs, menu), the bottom bar is gone and the menu hangs from the toolbar. a narrower window (slide over, half of a split view) keeps the phone layout. split view and slide over need ios 9 and a launch storyboard.

the settings, the lists and the downloads are presented as a form sheet of 540 points, not full width. the tab tray shows three to five columns by its width, the sheets of page controls are a column of 560 points.

## start

the system shows a violet launch screen, then `YZSplashController` (the same violet, the sticker that wobbles in and the name) while the browser, the core and the tabs are made on the next turn of the run loop, and the splash fades into the browser. a link that starts the app waits for the browser.

the start page shows the sticker and the name above the tiles. in the private session it shows a note about the session.

## site icons

tiles, rows of bookmarks and history, and tab cards show the `favicon.ico` of the site over https with the system trust store, kept in `Library/Caches/YozoraIcons` and asked again after three days when a site has none. nothing is fetched in the private session. a site without a usable icon keeps its colored letter tile.

## default browser

`Info.plist` declares `http` and `https` and the entitlement `com.apple.developer.web-browser` is signed in, so ios 14 and later list yozora under the default browser setting and links from other apps open in it. the scheme `yozora-auth` is declared too, it is the entry for the sign in of another app, see [signin](signin.md).


## links to other apps

a link the person followed, or a button that sets `location` in its click handler, is offered to the other apps before the page navigates. scripts without a gesture, history steps and reloads are never offered.

- a scheme of another app (`tg:`, `mailto:`, `tel:`, `itms-apps:`) is dropped by the page and opened with `openURL`. when nothing can open it a banner says so
- an http or https address of another site is a universal link candidate. the page waits while the app asks the system to open it with `UIApplicationOpenURLOptionUniversalLinksOnly`, which succeeds only for an app that claims the address. on success the page stays, on failure the page loads the address as before
- universal links exist on ios 10 and later. ios 5 to 9 answer no at once, because `openURL:` on an https address would give the page to Safari
- an address on the host of the page (ignoring `www.`), a frame inside the page for universal links, addresses with a user name or password, and the schemes `javascript`, `data`, `file`, `blob`, `about`, `view-source`, `ws`, `wss`, `ftp`, `filesystem` and `itms-services` are never offered
- a held universal link is answered with an ignore when the page stops, loads something else, is destroyed or leaves the screen, so no navigation waits for ever
- the rule is `yozora_address_external` in `core/yozora_address.c`, tested on the host in `tests/test_address.c`. the hand over is `core_offer_external` in `core/core/yozora_core.cpp`, the option `external_links` turns it on and the headless runner leaves it off

## translation

the menu offers to translate the page (`core/yozora_translate.c`, the library `yozora_translate.js` runs in an isolated world). the target language is the language of the device until the person picks one, languages can be never offered or always translated. the text of a private tab goes to the service only when the person asks.

## languages

the interface is available in russian, english and japanese. choose a language in settings under general, each one has a flag in a material shape (the sun for japanese, with the disc at three fifths of the height). the texts are tables keyed by the russian source string in `app/YZStrings.m`, a string a table lacks is shown in russian. until a language is chosen, the app uses the first language of the device if supported, or english otherwise.

## error pages

a failed load shows the address, the cause and a retry button in the page area. dns, connection, timeout, tls and interrupted transfers have their own messages, and the technical error stays visible below them.

## classic design

settings > Design picks between the modern Material look and the classic one. the classic one works on ios 5 to 7, where the system draws lit surfaces itself, and is never the default. the row is on every system: on ios 8 and later the classic option lies under a dark veil with a lock, and a tap says that the design is supported on ios 5 to 7. a stored classic choice is ignored there, unless the developer switch All designs unlocks it (see [debug](debug.md)). the classic design draws lit surfaces with system calls only (`app/YZClassic.m`): `CAGradientLayer` for the gradient of a bar and its hard edged gloss over the upper half, Core Graphics for keys, wells and glyph stamps, no pictures. bars take the accent (a deeper copy of it on the dark themes) with white stamped ink, the address field is a white well set into the bar, lists are grouped with a thin outline, glyph tiles in the settings are lit rounded squares, dialogs and menus stand on a pale or charcoal plate, buttons are glossy keys. grounds and fields keep the greys of the old system. the tokens live in `YZTheme` (`isClassic`, `barInkColor`, `barIcon:`, `pressedColor`, radii), the drawing in `YZClassic` (`YZGlossBarView`, `YZPlateView`, `keyImageWithColor:`). the modern design never calls into the classic file and keeps its own colors and radii. nothing was seen on a device yet: the gradients, gloss edges and contrast of white ink on the dark accent bars are worked out from the code.

## flat design

the third design, on ios 5 to 15 (a later system shows its option locked, the developer switch All designs opens it). it is the look of Safari on ios 7 in the colors of the app: white bars (the tonal grays of the theme in the dark ones) ending in a hairline, a gray field of 8 points radius and at most 30 high that shows the host of the page centered, bars of 44 points (36 on a phone on its side), the glyphs of the bars in the accent, thin radii (`YZTheme isFlat`). the glyphs of the bars and the field are thin outlines drawn in code (`YZTheme chromeIcon:`: back, forward, share, menu dots, close, plus, search, lock, star, bookmarks, find arrows), not the filled masks of the bundle. the bottom bar is the row of Safari on ios 7: back, forward, share, tabs, menu (`barButtons` in `YZBrowserController`), the star is not on the bar, the menu has an add to bookmarks row instead (`YZMenuBookmarkPage`, it reads add or remove by the state of the page). the share key (`sharePressed`, the same sheet as the menu row) is disabled on a blank tab, in a popup and where the system has no share sheet. a wide screen keeps back and forward on the left and the other three keys in the same order on the right. the reload and stop keys of the field are the filled masks of the bundle, only the glyphs listed above are drawn. a pressed key has no plate: its glyph or title goes to 30 percent alpha while held (`YZStateButton`). the grays and radii are tokens of `YZTheme`, the hairline is `YZSystemBarView`. the settings are the grouped table of ios 7 to 12: rows run the whole width with hairlines (from the text, the whole width at the end of a group), glyphs stand on rounded squares of 29 points in the accent, group names are small gray capitals, the switch is the white one of 51 by 31 with a gray rim, the title of a screen is centered in 17 points and a dialog is the alert of ios 7 (270 points, text over hairlines). other lists and sheets keep the modern shapes in these colors, the glossy and lit parts of the classic design are not used. the keys, dialog buttons, the find field, the selection pill and the chips of the tab strip of an ipad lose the full round of the modern design and take radii of 8 to 10 points (`YZClassic styleKey:`, `YZDialog`, `YZFindBar`, `YZTabStrip`), the selected chip is the gray of the field, as the white card of the modern one would vanish on a white bar. the stack and its bar follow the reduce motion switch: with it on nothing animates.

the pages view of the tab tray (settings > tab view > pages, which is also what an unset choice means in this design) is the stack of ios 7 (`app/YZTabStack.m`): the pages stand flat, they do not lean: a page that leaned back squeezed its picture by the cosine of the angle. depth is shown by size, a page at the first place is 0.9 of the width and one at the foot of the screen is full size, scaled about its top edge. a page has the proportions of the page of the browser (`tabStackPageFrame:`): its title bar over a window on the picture, which is fitted to the width from the top and cut at the foot, and a picture of another shape is never stretched to fill it (a page kept in landscape, a short one). the pages view of the classic design fills its pages the same way, a picture that is too short is scaled up and cut at the sides, so no bare plate shows (it used to leave a white strip). the tops of two pages are 0.29 of the height apart (at least 118 points), so each page shows its title bar and a piece of its picture (fewer pages are spread so that the last one still stands at the foot). while the stack moves the pages draw apart from the middle of the screen by up to 10 points for each step they are away from it, and settle when it rests: a light title bar of 44 points (the close cross on the left, the title centered, a line under it) over the top of the picture of the page, with a shadow thrown up over the strip behind it. the first page stands at 7 percent of the height. the stack scrolls at the pace of the finger until the strip of the last page is just above the bar, and a page that has gone past the first place fades out over the next step. the preview of a page is drawn at the density of the screen and kept as wide as the screen in pixels (at most 800, a jpeg of quality 0.82): 280 pixels was enough for the cards of the grid and was stretched to twice its size in the stack. a preview stored before is as small as it was until its page is left again. the tray opens with every page coming in on its own ease, the open one first and the others after it by their distance from it; a tap grows the page to the place of the page of the browser, with its title bar gone and the bar of the stack and the ground taking the color of the bars of the browser while it grows, so the bars that show when the tray leaves are the ones already there. Done does the same with the open page (`openSelected`). a new tab (`presentNewPage`) comes in at the foot and opens the same way. a swipe on a page to the side closes it, going off to the side it was pushed, and the cross sends it to the left; a page under the finger moves by a translation and the layout does not touch it until it is back. a swipe to the side on the bar or off every page switches between the normal and the private tabs. under the stack a bar of three glyphs: the mask of the private tabs (the switch between the normal and the private ones, in the accent while the private ones are shown), a plus for a new tab and a check for done. the pages overlap and each is as tall as the screen, so each takes touches only on the strip that shows (`pointInside:` of the page, the height up to the next page) and the subviews keep the order of the pages: opening a page used to leave it last, and it took the swipes meant for the pages above it. the grid and the pages of the other designs are unchanged.

not seen on a device: the tilt, the overlap and the timing of the stack are worked out from the code and the picture of ios 7, and so are the colors of the bars on the dark themes.

## app icon and mascot

the icon row in settings offers the icon of the app and the alternate icons the Info.plist lists (`Fox`). `app/YZAppIcon.m` picks the way: ios 10.3 and later take `setAlternateIconName:`, older systems and a refused call fall back to a rewrite of the app's own Info.plist (the primary icon files are swapped for the alternate files, the packaged entries are saved under `YozoraOriginalIcons`), `uicache` and a restart of SpringBoard, which closes the app. the choice is also kept in the user defaults and put back at launch, since a new install brings the packaged plist. an install under `/var/mobile/Applications` has its Icon files overwritten from `yozora-original-icons` and the alternate ones. the rewrite needs a bundle the app can write: the deb gives it to mobile in `postinst`, and where it is not so the row is dimmed and says why. the files are replaced with `open`, `write`, `rename` of a new file beside the old one (`YZReplaceFile`), not with `NSDataWritingAtomic`: on ios 6.1.4 an iPhone 5 answered Cocoa error 513 although the folder took a probe file, and the likely cause is that atomic writing gives the new file the owner of the old one, which a plist owned by root cannot be given by mobile. this is read from the code, not seen on the device. a failed write names the step, the errno, the owner and mode of the file and of its folder, and the uid of the process, in the error and in the log (`yozora: icon: … was not written`), so a refusal that remains says which call it was.

the alternate icon files are rounded and prerendered (`tools/make_icons.py SOURCE OUTPUT NAME`), because the home screen of ios 5 and 6 does not mask the icon of an app in /Applications. the same tool writes the icon of the app with the name `Icon`.

the mascot is the picture of the start page and the splash (hero), the about screen (sticker) and the error screens (error): `Yozora`, the default, `Yozora (Fox)` or `Senko`. the Senko pictures are cut-out stickers and are only resized (`tools/art/senko-*-source.png`). the fox art is cut from the pictures in `tools/art` by `tools/make_mascot_art.py`, which finds the black ground from the border and fades the edge by brightness so no dark halo is left.

## reuse

cards, tiles and rows are reused across layout, resize and data updates and not rebuilt: tab cards keep their objects, closing a tab moves the others into the gap, home tiles keep their buttons and get new targets. entrances are limited to eight visible items and 0.36 s. see [performance](performance.md).

## orientation

with the rotation lock on, ios 10 opens an app in the first orientation its root screen prefers, which was portrait. the browser and the splash screen answer `preferredInterfaceOrientationForPresentation` with the way the device is held (`YZRootOrientation`, `app/YZCompat.h`), falling back to the window orientation when the device lies flat or reports nothing. the lists, the downloads, the settings and the video screen answer with the orientation of the window (`YZPresentedOrientation`), so opening them does not turn a landscape app back to portrait. the panels stand in `YZPanelNavigationController` for that, a pushed screen cannot answer for its stack. the launch writes `launch orientation device N interface M` to the log. not tried on a device yet.

ios 5 launched in landscape: the browser replaces the splash as the root screen, its view turns to the way the device is held and the application keeps the orientation of the launch, so the status bar, the keyboard and the settings sheet stand in portrait under a landscape page (seen on an ipad 1 with ios 5.1.1). `viewDidAppear:` of the browser tells the application the orientation of the screen (`setStatusBarOrientation:`) when they differ, on systems before ios 6 only, and logs `the application is in orientation N and the screen in M`. not tried on a device, the cause is read from the screenshots.

the screens of the panels (settings and its sub screens, lists, downloads, log, sites, ad block rules) never answered `shouldAutorotateToInterfaceOrientation:`, and before ios 6 the default is portrait only, so on ios 5 they opened sideways over a landscape page, on an iphone too. `YZPanelNavigationController` answers yes for the whole stack, a navigation controller takes the answer of its top screen otherwise. the video screen and the popup window answer for themselves, sheets drawn inside the page rotate with it, and the system pickers and the share sheet own their rotation.

## flat design motion

the flat design does not use the springs of the modern one. every curve of `YZMotion` is played there as one ease out (cubic, 0.34 s in, 0.22 s out, no overshoot), menus open from 95 percent of their size and leave to 96, the glyphs in them do not pop, buttons do not shrink when pressed, a change of look fades the old one away instead of opening a circle, and the glyphs of the bars do not pop after a change of theme.

## tab view and the modern design

the pages view of the tab tray is the Safari look of the classic and the flat design. the modern design has the grid only: `YZSettings tabsLayout` returns the grid there whatever was chosen (the choice stays stored for the other designs) and the row in settings shows the pages option with a lock and a note.

## dns

settings > privacy and security > DNS opens a card (`app/YZDnsPopup.m`). there is no list of servers and no example in the field: a person types an address or a name, an empty field is the system resolver. the modern design has a card of its own with the field as tall as its box and its text in the middle of that height, the line under it shows the address that will be asked (accent), that an empty field is the system, or why the text is refused (red, with a red rim on the field); the card comes in on the wobble curve. the flat and the classic design ask with the card of the app (the alert of the system on ios 5 to 7): one field that starts with the server in use, and an address the core refuses is explained and asked again with what was typed. the libcurl of this build has no c-ares, so a server is asked over HTTPS (DNS over HTTPS) and not on port 53, see [network](network.md). a tap on the card or beside it puts the keyboard away and leaves the card open (a tap recognizer on the card with `cancelsTouchesInView` off, which skips the field and the keys); the card of the flat design (`YZDialog`) does the same for every dialog with a field. the alert of the system that the classic design uses on ios 5 to 7 is the system's.

## start page background

a held finger on the start page opens a menu (`YZPopupMenu`, grows from the finger) whose first row, Background, puts a card over the foot of the page itself (`YZHomeBackgroundEditor`): the button of the photo library (a popover on an ipad), the button that takes the photo away, the accent gradient while there is no photo and a done button. the page takes no touches while the card is up. the photo is decoded off the main thread, cut down to the long side of the screen in pixels and stored as a jpeg in `Library/Yozora/home-background.jpg` (`app/YZBackground.m`), the stamp in `YZHomeBackgroundStamp` (written on the main thread, it posts the settings notification) tells the page it changed. the photo is shown as it is, there is no blur (the setting `YZHomeBackgroundBlur` of earlier versions is not read). the start page applies the stored photo or gradient when it is made, so both are there after a new launch, and holds the photo to the visible rectangle while it scrolls. the lettering follows the photo: its lightness (`YZBackground lightnessOfImage:`, the mean luma of a copy of 16 by 16 pixels, `yozora_luma_average` in `core/yozora_blur.c`) over 0.55 gives dark lettering (headings and the name 0.08 white, the names under the tiles 0.2), anything darker gives light lettering (0.98 and 0.9), and a page without a photo keeps the colors of the theme. the private session does not show the photo.

## about screen

settings > About Yozora shows the sticker card, the name and version of the app, a line about it and the rows: GitHub, the Telegram channel, WebKit and the official testers. the WebKit row has no address, its second line is the version of the engine this build was made from (`YozoraWebKitVersion` of `Info.plist`, set from `core/source.json` and kept equal to it by `tests/test_core_source.py`; a missing key shows `?` and is logged). a row with an address opens it, the other two only show their text.
the rows of the menu wrap to a second line: the blocker row ("Включить блокировщик на сайте") was cut to "Включить б...ик" on one line.

without a photo, in the modern design, the card has a third button that turns on the accent gradient (`YZHomeGradient`): a CAGradientLayer behind the page from the surface mixed with 42 percent of the accent (34 in a dark theme) at the top left, through a weaker tint, to the plain surface. the lettering keeps the colors of the theme over it. the classic and the flat design and the private session do not show it. the strips of the bars continue the start page as they continue the edges of a site: `YZHomeView topEdgeColor` and `bottomEdgeColor` are the surface, the gradient at the middle of the top and the bottom edge, or the mean of the top and the bottom rows of the part of the photo the page shows (a copy of 8 by 24 pixels), taken again when the ground or the size changes, and the browser hands them to `setEdgeColor:bottom:` while the start page is shown.

## passwords

a page that starts to load runs `[YZPasswords captureScript]` in the isolated world of the page it leaves: the fields of a sent form stay until the answer of the next page commits. a password field with text and the last name, email or phone field before it in its form make a capture of the site (`yozora_password_site`: https only, lower case, no www., the port when it is not 443, no login inside the address). `yozora_password_decide` asks to save, to update a changed password or nothing (same password, a site said never for, a password over 1024 bytes). the question is a sheet of actions as in Safari: save, never for this site, not now. an answer that commits before the script runs leaves nothing to read, and a login done without a navigation (a page that signs in by fetch and stays) is not offered.

the passwords are internet passwords in the keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, the site as the server, the group `com.sqmrak.yozora` of `keychain-access-groups` in the entitlements), the sites said never for are in `YZPasswordNever`. a loaded https page with exactly one empty password field gets the login saved last for its site, filled with input and change events. Settings, Privacy and security, Passwords lists them as cards (the mark of the site, the site, the login, the hidden password) with a search line, a sheet of actions (copy the login or the password, show it until the screen is left, delete) and a list of the never sites under it, a swipe deletes. on ios 9 and newer with a passcode the screen asks for the owner first (LAContext, loaded at run time so the armv7 slice keeps ios 5).

## start page menu

the start page is, top to bottom by default: the logo with the name and under it a search line (the mark of the search engine small at the left, a tap opens the address field), the tiles of the visited sites with a plus tile first, and the favorites, which are shown only when there are some. every row of tiles and the heading of the favorites stand in the middle. the plus tile asks for the address of a site in a card (`YZDialog`, title Add a website): only an address is kept (`yozora_address_resolve` must say URL, text that would be searched for is refused) and it is stored as a bookmark, so the star of the bars and the plus fill the same list (up to 20 tiles).

a held finger opens the menu of the page (`YZPopupMenu`): background, add a website, remove from the home screen (only over a tile), reset of the order of the blocks once it differs from the default, and the parts of the page. the order is kept as `1,0,2` in `YZHomeOrder` (`core/yozora_home.c`, a damaged value is the default order logo, sites, favorites); the rows that raised a block one place are gone, so only an order stored by an earlier version can differ. the menu is not offered in the private session.

a finger held on a tile lifts it (scale 1.12 with a shadow) and drags it: the nearest place of its own section takes it and the tiles between slide over, the plus tile stays first. let go where it was, the tile goes back and the menu of the page opens with remove from the home screen for that tile. a favorite removed there leaves the favorites, a visited site is only hidden from the page (`YZHomeHiddenSites`) and stays in the history. a drag stores the section in its new order (`YZHomeSiteOrder`, `YZHomeFavoriteOrder`, at most `YOZORA_HOME_LIST_MAX` addresses). `yozora_home_arrange` puts the placed addresses first in their order and the rest after them in their natural order (most visited, or as the store lists the favorites), without the hidden ones.

popular sites show a colored mark from the bundle in place of the favicon, as Google, DuckDuckGo and Yandex did before (`YZBundledSiteIcon` in `app/YZFavicons.m`, the longest listed domain wins, so mail.google.com is Gmail). the marks are simple-icons svgs (CC0) in `tools/site-logos`, drawn by `tools/make_site_logos.py` as 128 pixel `yz-logo-<name>.png` in the color of the brand, with the cut out parts (the triangle of YouTube, the plane of Telegram) filled white so they read on a dark tile.


## floating bars

the modern design always has the floating bars: the color of the page ground, no lines, the address in a white pill (`addressFieldColor`) 10 points shorter than the bar with a soft shadow (a shadow path is set, so it is not rendered offscreen), the title of the page after the host in a lighter color when the field is not edited (`YZSetAddressText`, plain text on ios 5), the mark of the search engine small in the pill on a blank page. `Settings > General > Bars` puts them in one of two places on a phone (`YZBarLayout`, locked outside the modern design, a wide screen keeps its toolbar):

- bottom (default): one bar at the foot with the pill over the keys back, forward, share, menu and tabs, and nothing at the top but the strip under the status line. while the address is typed the bar is the pill alone over the keyboard and the suggestions end above it. the page ends over the bar and grows when the bar leaves on a scroll
- top: no bar at the foot, one row at the top as Firefox has it: the pill and two keys, tabs and menu. back and forward are the first rows of the menu, which hangs from the top right. the star is in the menu in both places (`barKeepsStarInMenu`)

the classic and the flat design keep their own bars. the setting `Hide bars on scroll` has no top bar to take in the bottom layout.

## voice

a microphone in the address pill (`YZVoiceInput`) shows on a blank page and while the address is typed when the system has a speech recognizer (ios 10 and later: `SFSpeechRecognizer`, looked up at run time, the Speech framework is loaded by path, the armv7 slice has no header for it). a press asks for the permissions the first time (`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` are in `Info.plist`), listens up to 20 seconds, puts the words in the field while they come and searches the last version. a second press ends the listening. the recognizer takes the language of the app (Russian, English, Japanese). nothing of it ran on a phone yet.
