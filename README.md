# srctree

Source code sharing (without breaking the back button)

Using a reverse proxy is the preferred method, there's a sample config in
`contrib/nginx.conf` where `zig build run` should just work. 

But if you're unable to stand up a reverse proxy (a local proxy development
should be supported) you can try `zig build run -- http` to use http mode. Full
HTTP support is planned for "eventually" but no guarantees are made yet :)

Good luck!


## TODO
  - [ ] srctree
    - [x] view code
    - [x] view commits
    - [x] create repos
    - [x] create issues
    - [x] clone repo from remote
    - [-] diff/code review
    - [-] CI API
      - [x] `build.zig` support
      - [ ] every other build system.
    - [x] blame view for files
    - [ ] blame view for dirs
    - [x] view history for file (navigable blame view)
    - [x] syntax highlighting (ish)
    - [x] native syntax highlighting
      - [x] zig
      - [ ] every other language
    - [x] README markdown support/formatting
    - [x] fold repo .files by default
    - [ ] email support
      - [-] outgoing email (partial)
      - [ ] incoming email
    - [x] submit diffs (via git)
    - [x] auto pull from upstream
    - [x] auto push to downstream
    - [ ] smart push/pull (between networks/peers)
    - [x] support for viewing branches
    - [ ] network collection & browsing
    - [x] owner heat map
    - [x] owner activity journal
      - [x] commits
      - [ ] anything other that
    - [ ] users
      - [ ] account creation UI
    - [-] Integration with other web VCS
      - [x] clone issues
      - [ ] everything else
  - [ ] git 
    - [x] raw blob
    - [x] packed blob
    - [-] tree/blob
      - [x] read
      - [ ] write
    - [x] packed delta
    - [ ] tags
    - [x] refs
    - [x] remotes
    - [x] git web
    - [ ] PGP support
    - [ ] repo init
    - [ ] push
    - [ ] pull
    - [ ] blame
    - [ ] diff/patch generation
