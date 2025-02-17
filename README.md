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
  - [ ] srctree
    - [ ] internal database upgrade scripts
    - [ ] manual code sync
    - [x] view code
    - [x] public http clone
    - [x] view commits
    - [ ] diff/code review
    - [ ] CI API
    - [x] blame view for files
    - [ ] blame view for dirs
    - [ ] view history for file (navigable blame view)
    - [x] syntax highlighting (ish)
    - [ ] native syntax highlighting
    - [x] README markdown support/formatting
    - [ ] fold repo .files by default
    - [ ] comment on commits
    - [ ] email support
      - [ ] outgoing email
      - [ ] incoming email
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
    - [x] owner activity journal
      - [x] commits
      - [ ] anything other that
    - [ ] user accounts
    - [ ] new account setup
    - [ ] git via ssh support
    - [ ] Integration with other web VCS
    - [ ] Improve CSS theme

  - [ ] git 
    - [x] raw blob
    - [x] packed blob
    - [-] tree/blob
      - [x] read
      - [ ] write
    - [x] packed delta
    - [ ] tags
    - [ ] refs
    - [ ] remotes
    - [x] git web (partial)
    - [ ] PGP support
    - [ ] commitish (see git.zig)
    - [ ] .git repo init
    - [ ] push/pull
    - [ ] blame
    - [ ] diff/patch generation
