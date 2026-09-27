# Asteroid Run

A times-tables space game. Every mission is 25 questions, and each right answer steers the ship around an asteroid. The levels build up from gentle ×10 practice to the pace of the Year 4 **Multiplication Tables Check**: 6 seconds a question with a 3-second gap between questions.

**Play:** https://itaico82.github.io/asteroid-run/

## For grown-ups

- Kids sign in with a **username and a 4-digit PIN**. No email address or real name is needed.
- The public leaderboard only ever shows a **callsign** built from fixed word lists (for example "Swift Comet 27"), never a username.
- Each pilot's missions are saved so the flight log can show which facts need practice. A pilot can be deleted, with everything saved for it, from Settings.

## How it's built

- `index.html` is the whole game: a single page served by GitHub Pages.
- `supabase/` holds the backend: the database schema with row-level security, the leaderboard functions, and the `pilot-signup` edge function that creates username + PIN accounts. The key in `index.html` is Supabase's public (publishable) key, which is safe to publish; the database rules decide what it can do.
