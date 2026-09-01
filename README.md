# LayoutFix

Background macOS agent that notices when you have typed a word in the wrong
keyboard layout (English text on a Hebrew input source, or Hebrew text on an
English one), rewrites it in place, and switches the input source for you.

Typing `akuo kfo hksho uhksu,` with English active becomes
`שלום לכם ילדים וילדות`, with the input source flipped to Hebrew — so the rest
of the sentence is typed correctly without you touching anything.

Status: in development. See `Makefile` for the build targets.
