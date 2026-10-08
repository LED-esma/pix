# Security policy

Pix acts on your Mac (files, apps, settings, scripts), so security reports matter a lot here.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe what an attacker could do, and how to reproduce it.

You'll get a reply within a week. Once it's fixed and released, you'll be credited in the release notes unless you'd rather not be.

## What counts

Especially welcome:

- a way for an AI, a web page, a file or another app to make Pix do something irreversible without asking (delete, send, buy, run a script);
- a way around the protected folders (your home folder's own folders, Library, hidden folders);
- prompt injection that leads to an action;
- anything reaching Pix's local bridge (127.0.0.1) without its per-launch token;
- leaks of keys or personal data.

## Supported versions

Only the latest release gets security fixes. Pix updates itself from GitHub Releases.
