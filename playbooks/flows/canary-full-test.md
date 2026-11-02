---
scope: flow
match: apprentice-canary
tags: canary, full test, test page, self-test, features
model: any
lang: en
verified: 2026-11-02, macOS 26.2, Chrome
status: partial
---
# Run the canary's full feature test

Run: `apprentice do canary-full-test --url "{url}" --message "{message}" --email "{email}"`

## Steps
1. `open {url}`
2. `type #textarea "Typing box" "{message}"`
3. `type #textbox "Email" "{email}"`
4. `click #link "Map"`
5. `drag --by -450,-280 --in #text "Drag the map from here"`
6. `drag --by -450,-280 --in #text "Drag the map from here"`
7. `drag --by -450,-280 --in #text "Drag the map from here"`
8. `scroll right 6 --in #text "Drag the map from here"`
9. `scroll down 3 --in #text "Drag the map from here"` — zooms out, at the pointer (off the centre)
10. `click #button "Zoom in"`
11. `click #link "Widgets"`
12. `click #checkbox "Subscribe to newsletter"` — counts as a follow in the budget
13. `click #radio "Medium"`
14. `click #tab "Details"`
15. `click #button "Load results"`
16. `wait-for "Results ready"`
17. `click #link "Open result 1"`
18. `key cmd+[`
19. `click #button "Save draft"`
20. `wait-for "Draft saved"`
21. `click #link "Popups"`
22. `click --on "Choose a colour"`
23. `click --on "Teal"`
24. `click --on "Right-click me" --right`
25. `click --on "Rename"`
26. `click --on "Double-click to rename" --double`
27. `type focused "Renamed item" --enter`
28. `click #button "Open dialog"`
29. `type #textbox "Display name" "Robin"`
30. `click #button "Save profile"`
31. `click #link "Drag"`
32. `drag #text "One" #text "Four"`
33. `drag --by 380,90 --in #image "Sketch pad"`
34. `click #link "Chat"`
35. `type #textarea "Write a message" "First line\nSecond line" --enter`
36. `click #link "Feed"`
37. `scroll down 40 --in #text "Post 1 · a short update about the weather and the garden."`
38. Like one post: `click <id>` on one of the "Gefällt mir" buttons (a like in German, counted against the like budget; the label repeats, so a flow cannot pick one). Click the Treasure pin on the Map where it shows (`click --at`), pick Banana in Fruit (`click` the select, `key down`, `key return`), hover "Hover me for help", attach a file in Files and download the report: by hand, as these need ids or paths. Then `click --on "Metrics"` for the measurements.
