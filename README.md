# srctree

Source code sharing (without breaking the back button)

Using a reverse proxy is the preferred method, there's a sample config in
`contrib/nginx.conf` where `zig build run` should just work. 

But if you're unable to stand up a reverse proxy (a local proxy development
should be supported) you can try `zig build run -- http` to use http mode. Full
HTTP support is planned for "eventually" but no guarantees are made yet :)

Good luck!
