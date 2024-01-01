# srctree

Source code sharing (without breaking the back button)

Using a reverse proxy is the preferred method, there's a sample config in
`contrib/nginx.conf` where `zig build run` should just work. 

But if you're unable to stand up a reverse proxy (a local proxy development
should be supported) you can try `zig build run -- http` to use http mode. Full
HTTP support is planned for "eventually" but no guarantees are made yet :)

Good luck!


## TODO
In an unsorted order
  - [x] view code
  - [x] public http clone
  - [x] view commits
  - [ ] blame view for files/dirs
  - [ ] view history for file
  - [ ] syntax highlighting
  - [ ] README markdown support/formatting
  - [ ] fold repo .files by default
  - [ ] comment on commits
  - [ ] email support
  - [-] submit diffs (works with special build step)
  - [x] open issues
  - [x] clone repo from remote
  - [ ] set HEAD for newly clone repos
  - [x] auto pull from upstream
  - [x] auto push to downstream
  - [ ] smart push/pull system
  - [ ] auto create git branch for issues/diffs
  - [ ] support for viewing branches
  - [ ] network collection & browsing
  - [x] owner heat map
  - [ ] owner activity journal
  - [ ] user accounts
  - [ ] new account setup
  - [ ] git via ssh support
  - [ ] basic logic for template system
  - [ ] 
  - [ ] docs for everything
  - [ ] docs for template engine
  - [ ] API for dynamic updates
  - [ ] Integration with other web VCS
  - [ ] Improve CSS theme
  - [ ] git PGP support
