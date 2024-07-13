# Original Design Intent Of Delta

Everything in code should change, comment threads should follow those changes,
from idea (e.g. an issue), through suggestions (e.g. a diff), and eventually the
commit. A single delta should track the meta information so that the information
and history can follow the changes from beginning to the end.

Deltas only contain meta data about the origin, comments exist within a thread.

Commits exist outside of a specific Delta, so they attach to a Delta, threads
may move so should have a delta container.

